import AppKit
import ApplicationServices
import WebKit

/// `ClaudeDict --selftest-ax`: exercises the Accessibility selection reader against real views in
/// offscreen windows of this process: an NSTextView, a password field and WebKit pages (the engine
/// behind Mail and Safari). Needs Accessibility trust (when started from a terminal, the terminal's
/// permission applies). Never takes keyboard focus.
@MainActor
enum AXSelfTest {
    private static var windows: [NSWindow] = []
    private static var pages: [WebFixture] = []

    static func run() {
        guard AXIsProcessTrusted() else {
            print("SKIP not trusted for Accessibility")
            exit(2)
        }
        // While the screen is locked, Accessibility lists placeholder windows (role AXApplication)
        // and every check below would fail for reasons that have nothing to do with the code.
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            print("SKIP screen is locked; Accessibility does not report windows then")
            exit(2)
        }
        let panel = FloatingPanel(allowsKey: false, resizable: false, level: .normal)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        textView.string = "Hello brave new world"
        textView.setSelectedRange(NSRange(location: 6, length: 9))
        panel.contentView = textView
        panel.setAccessibilityIdentifier("selftest-text")
        panel.setFrame(NSRect(x: -8000, y: -8000, width: 320, height: 80), display: true)
        panel.orderFrontRegardless()

        let secure = FloatingPanel(allowsKey: false, resizable: false, level: .normal)
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        password.stringValue = "hunter2"
        secure.contentView = password
        secure.setAccessibilityIdentifier("selftest-secure")
        secure.setFrame(NSRect(x: -8000, y: -7800, width: 200, height: 24), display: true)
        secure.orderFrontRegardless()
        windows = [panel, secure]

        // WebKit has no AXSelectedText on a page; Mail's message view and compose window are such
        // pages. "editable" is set up like Mail's compose window: the whole page is editable and
        // the web area itself holds the selection.
        pages = [
            WebFixture(id: "selftest-web-static", select: true, editable: false, y: -7600),
            WebFixture(id: "selftest-web-editable", select: true, editable: true, y: -7400),
            WebFixture(id: "selftest-web-none", select: false, editable: false, y: -7200),
        ]

        // 替换原文 borrows the clipboard; it must come back with every type it had. Uses a private
        // pasteboard so the user's clipboard is never touched.
        let board = NSPasteboard(name: NSPasteboard.Name("local.claudedict.selftest"))
        board.clearContents()
        let rtf = Data("{\\rtf1\\ansi rich}".utf8)
        let item = NSPasteboardItem()
        item.setString("user's own clipboard", forType: .string)
        item.setData(rtf, forType: .rtf)
        board.writeObjects([item])
        let saved = SelectionReader.snapshot(board)
        board.clearContents()
        board.setString("Hello, I never give up.", forType: .string)
        SelectionReader.restore(board, saved)
        let restored = board.string(forType: .string) == "user's own clipboard" && board.data(forType: .rtf) == rtf
        print("\(restored ? "ok  " : "FAIL") clipboard restored with all its types after a paste")
        board.releaseGlobally()
        if !restored {
            print("AX self-test: 1 failed")
            exit(1)
        }

        // AX requests to our own process are served by the main run loop, so query off-main.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            var failures = 0
            func check(_ ok: Bool, _ label: String) {
                print("\(ok ? "ok  " : "FAIL") \(label)")
                if !ok { failures += 1 }
            }
            let app = AXUIElementCreateApplication(getpid())
            // Our windows can take a moment to show up in Accessibility while the WebKit pages
            // start, so wait for them instead of trusting a fixed delay.
            var textArea: AXUIElement?
            let windowDeadline = Date().addingTimeInterval(10)
            repeat {
                textArea = window(app, id: "selftest-text").flatMap { find($0, role: "AXTextArea", depth: 0) }
                if textArea == nil { Thread.sleep(forTimeInterval: 0.2) }
            } while textArea == nil && Date() < windowDeadline
            guard let area = textArea else {
                print("FAIL no AXTextArea in our own window; windows: \(windowIDs(app))")
                exit(1)
            }
            let (outcome, editable) = SelectionReader.inspect(area, mouseDownAt: nil)
            if case .text(let text) = outcome {
                check(text == "brave new", "selected text via AX = «\(text)»")
            } else {
                check(false, "selected text via AX: \(outcome)")
            }
            check(editable, "text view reported editable")

            if let frame = SelectionReader.frame(of: area) {
                let inside = CGPoint(x: frame.midX, y: frame.midY)
                if case .text = SelectionReader.inspect(area, mouseDownAt: inside).0 {
                    check(true, "drag starting inside the element is accepted")
                } else {
                    check(false, "drag starting inside the element is accepted")
                }
            } else {
                check(false, "element frame readable")
            }
            if case .outsideElement = SelectionReader.inspect(area, mouseDownAt: CGPoint(x: 9000, y: 9000)).0 {
                check(true, "drag starting outside the element is ignored")
            } else {
                check(false, "drag starting outside the element is ignored")
            }

            if let secureWindow = window(app, id: "selftest-secure"),
               let field = find(secureWindow, role: "AXTextField", depth: 0)
                ?? find(secureWindow, role: "AXSecureTextField", depth: 0) {
                if case .secure = SelectionReader.inspect(field, mouseDownAt: nil).0 {
                    check(true, "password field is never read")
                } else {
                    check(false, "password field is never read")
                }
            } else {
                check(false, "secure field found")
            }

            // WebKit pages: wait until each has loaded and made its selection, then read it the
            // way the toolbar does. The page's own report comes first, so a broken fixture shows
            // up as such and not as a reader failure.
            var states: [WebFixture.State] = []
            let deadline = Date().addingTimeInterval(20)
            repeat {
                states = DispatchQueue.main.sync { MainActor.assumeIsolated { pages.map(\.state) } }
                if states.allSatisfy({ $0.pageSelection != nil || $0.failure != nil }) { break }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
            for state in states {
                if let failure = state.failure {
                    check(false, "\(state.id): \(failure)")
                    continue
                }
                guard let pageSelection = state.pageSelection else {
                    check(false, "\(state.id): page not ready within 20 s")
                    continue
                }
                check(pageSelection == state.expected, "\(state.id): page reports selection «\(pageSelection)»")
                guard let pageWindow = window(app, id: state.id) else {
                    check(false, "\(state.id): window found")
                    continue
                }
                // WebKit builds its accessibility tree on the first request, so give it a moment.
                var found: AXUIElement?
                let treeDeadline = Date().addingTimeInterval(5)
                repeat {
                    found = find(pageWindow, role: "AXWebArea", depth: 0)
                    if found == nil { Thread.sleep(forTimeInterval: 0.1) }
                } while found == nil && Date() < treeDeadline
                guard let web = found else {
                    check(false, "\(state.id): AXWebArea found; window tree: \(roles(pageWindow, depth: 0))")
                    continue
                }
                let outcome = SelectionReader.inspect(web, mouseDownAt: nil).0
                switch outcome {
                case .text(let text):
                    check(text == state.expected, "\(state.id): read via AX = «\(text)»")
                case .noSelection:
                    check(state.expected.isEmpty, "\(state.id): read via AX: no selection")
                default:
                    check(false, "\(state.id): read via AX: \(outcome)")
                }
                // A drag that starts on the page counts; one far away does not.
                if !state.expected.isEmpty {
                    if let windowFrame = SelectionReader.frame(of: pageWindow),
                       case .text = SelectionReader.inspect(web, mouseDownAt: CGPoint(x: windowFrame.midX, y: windowFrame.midY)).0 {
                        check(true, "\(state.id): drag starting on the page is accepted")
                    } else {
                        check(false, "\(state.id): drag starting on the page is accepted")
                    }
                    if case .outsideElement = SelectionReader.inspect(web, mouseDownAt: CGPoint(x: 9000, y: 9000)).0 {
                        check(true, "\(state.id): drag starting far from the page is ignored")
                    } else {
                        check(false, "\(state.id): drag starting far from the page is ignored")
                    }
                }
            }
            print(failures == 0 ? "AX self-test passed" : "AX self-test: \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// One of this process's windows, by the accessibility identifier set on it.
    nonisolated private static func window(_ app: AXUIElement, id: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let list = ref as? [AXUIElement] else { return nil }
        return list.first { window in
            var idRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXIdentifierAttribute as CFString, &idRef)
            return idRef as? String == id
        }
    }

    /// The app's windows as Accessibility lists them, for failure messages.
    nonisolated private static func windowIDs(_ app: AXUIElement) -> String {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref)
        guard error == .success, let list = ref as? [AXUIElement] else { return "error \(error.rawValue)" }
        return list.map { window -> String in
            var idRef: CFTypeRef?
            let idError = AXUIElementCopyAttributeValue(window, kAXIdentifierAttribute as CFString, &idRef)
            var roleRef: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
            return "\(roleRef as? String ?? "role error \(roleError.rawValue)"):"
                + "\(idRef as? String ?? "id error \(idError.rawValue)")"
        }.joined(separator: ", ")
    }

    /// Roles under an element, nested in brackets, for failure messages.
    nonisolated private static func roles(_ element: AXUIElement, depth: Int) -> String {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "?"
        var children: CFTypeRef?
        guard depth < 6, AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement], !list.isEmpty else { return role }
        return role + "[" + list.prefix(6).map { roles($0, depth: depth + 1) }.joined(separator: ",") + "]"
    }

    nonisolated private static func find(_ element: AXUIElement, role: String, depth: Int) -> AXUIElement? {
        guard depth < 12 else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if roleRef as? String == role { return element }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let found = find(child, role: role, depth: depth + 1) { return found }
        }
        return nil
    }
}

/// An offscreen WebKit page showing "Hello brave new world", optionally editable as a whole
/// (like Mail's compose window), with "brave new" selected by script or nothing selected.
@MainActor
private final class WebFixture: NSObject, WKNavigationDelegate {
    struct State: Sendable {
        let id: String
        let expected: String
        /// What the page itself reports as selected, once it has loaded and run its script.
        let pageSelection: String?
        let failure: String?
    }

    let id: String
    private let select: Bool
    private let editable: Bool
    private let panel = FloatingPanel(allowsKey: false, resizable: false, level: .normal)
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    private var pageSelection: String?
    private var failure: String?

    var state: State {
        State(id: id, expected: select ? "brave new" : "", pageSelection: pageSelection, failure: failure)
    }

    init(id: String, select: Bool, editable: Bool, y: CGFloat) {
        self.id = id
        self.select = select
        self.editable = editable
        super.init()
        webView.navigationDelegate = self
        panel.contentView = webView
        panel.setAccessibilityIdentifier(id)
        panel.setFrame(NSRect(x: -8000, y: y, width: 320, height: 120), display: true)
        panel.orderFrontRegardless()
        webView.loadHTMLString("<p id=\"t\">Hello brave new world</p>", baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let makeEditable = editable ? "document.designMode = 'on';" : ""
        let selectWords = select
            ? "const node = document.getElementById('t').firstChild; const range = document.createRange(); "
                + "range.setStart(node, 6); range.setEnd(node, 15); selection.addRange(range);"
            : ""
        let script = """
        (() => {
          \(makeEditable)
          const selection = window.getSelection();
          selection.removeAllRanges();
          \(selectWords)
          return selection.toString();
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            MainActor.assumeIsolated {
                if let error {
                    self.failure = "page script failed: \(error.localizedDescription)"
                } else {
                    self.pageSelection = result as? String ?? ""
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = "page failed to load: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = "page failed to load: \(error.localizedDescription)"
    }
}

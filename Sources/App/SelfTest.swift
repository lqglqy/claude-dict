import AppKit
import ApplicationServices

/// `ClaudeDict --selftest-ax`: exercises the Accessibility selection reader against a real
/// NSTextView in an offscreen window of this process. Needs Accessibility trust (when started
/// from a terminal, the terminal's permission applies). Never takes keyboard focus.
@MainActor
enum AXSelfTest {
    private static var windows: [NSWindow] = []

    static func run() {
        guard AXIsProcessTrusted() else {
            print("SKIP not trusted for Accessibility")
            exit(2)
        }
        let panel = FloatingPanel(allowsKey: false, resizable: false, level: .normal)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        textView.string = "Hello brave new world"
        textView.setSelectedRange(NSRange(location: 6, length: 9))
        panel.contentView = textView
        panel.setFrame(NSRect(x: -8000, y: -8000, width: 320, height: 80), display: true)
        panel.orderFrontRegardless()

        let secure = FloatingPanel(allowsKey: false, resizable: false, level: .normal)
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        password.stringValue = "hunter2"
        secure.contentView = password
        secure.setFrame(NSRect(x: -8000, y: -7800, width: 200, height: 24), display: true)
        secure.orderFrontRegardless()
        windows = [panel, secure]

        // AX requests to our own process are served by the main run loop, so query off-main.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            var failures = 0
            func check(_ ok: Bool, _ label: String) {
                print("\(ok ? "ok  " : "FAIL") \(label)")
                if !ok { failures += 1 }
            }
            let app = AXUIElementCreateApplication(getpid())
            guard let area = find(app, role: "AXTextArea", depth: 0) else {
                print("FAIL no AXTextArea in our own window")
                exit(1)
            }
            let (outcome, editable) = SelectionReader.inspect(area, mouseDownAt: nil)
            if case .text(let text) = outcome {
                check(text == "brave new", "selected text via AX = «\(text)»")
            } else {
                check(false, "selected text via AX: \(outcome)")
            }
            check(editable, "text view reported editable (enables 替换原文)")

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

            if let field = find(app, role: "AXTextField", depth: 0) ?? find(app, role: "AXSecureTextField", depth: 0) {
                if case .secure = SelectionReader.inspect(field, mouseDownAt: nil).0 {
                    check(true, "password field is never read")
                } else {
                    check(false, "password field is never read")
                }
            } else {
                check(false, "secure field found")
            }
            print(failures == 0 ? "AX self-test passed" : "AX self-test: \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
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

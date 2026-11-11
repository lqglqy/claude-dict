import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct CapturedSelection {
    var text: String
    var context: SelectionContext
}

/// Clipboard changes we make ourselves (copy fallback, paste, copy button) must not look like a
/// user's double ⌘C.
enum ClipboardGuard {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var until = Date.distantPast

    static func suppress(for seconds: TimeInterval) {
        lock.lock()
        until = max(until, Date().addingTimeInterval(seconds))
        lock.unlock()
    }

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date() < until
    }
}

/// Reads the frontmost app's selected text: Accessibility first, simulated ⌘C as a fallback.
enum SelectionReader {
    enum Mode { case mouse, hotkey }

    enum AXOutcome {
        case text(String)
        case noSelection
        case secure
        case outsideElement
        case failed(role: String?)
    }

    /// Roles where a drag or double-click is not a text selection, so ⌘C must not be sent.
    private static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXImage", "AXButton", "AXMenuItem",
        "AXMenuBar", "AXDockItem", "AXScrollBar", "AXSlider", "AXToolbar", "AXSplitter",
    ]
    nonisolated(unsafe) private static var manualAccessibilityPIDs = Set<pid_t>()

    /// Blocking; call off the main thread. `mouseDownAt` is in Accessibility coordinates
    /// (top-left origin) and only given for drags.
    static func read(mode: Mode, allowCopyFallback: Bool, mouseDownAt: CGPoint? = nil) -> CapturedSelection? {
        guard AXIsProcessTrusted() else { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.processIdentifier
        if let pid { enableManualAccessibility(pid) }
        let (outcome, editable) = axSelection(mouseDownAt: mouseDownAt)
        let context = SelectionContext(pid: pid, bundleID: front?.bundleIdentifier, isEditable: editable)
        switch outcome {
        case .text(let text):
            return CapturedSelection(text: text, context: context)
        case .noSelection, .secure, .outsideElement:
            return nil
        case .failed(let role):
            guard allowCopyFallback, front?.bundleIdentifier != "com.apple.finder",
                  !nonTextRoles.contains(role ?? "") else { return nil }
            if mode == .hotkey { waitForModifierRelease() }
            guard let text = copySelection(),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CapturedSelection(text: text, context: context)
        }
    }

    private static func axSelection(mouseDownAt: CGPoint?) -> (AXOutcome, Bool) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.6)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return (.failed(role: nil), false)
        }
        return inspect(focusedRef as! AXUIElement, mouseDownAt: mouseDownAt)
    }

    /// Selection state of one element: its selected text, unless it is a password field or the
    /// drag started outside it. Returns whether the element is editable (for "替换原文").
    static func inspect(_ element: AXUIElement, mouseDownAt: CGPoint?) -> (AXOutcome, Bool) {
        AXUIElementSetMessagingTimeout(element, 0.6)
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole { return (.secure, false) }
        let editable = isEditable(element, role: role)
        // A drag that started outside the focused element (a window drag, a slider) leaves an
        // old selection in place; do not pop up for it.
        if let point = mouseDownAt, let frame = frame(of: element), !frame.insetBy(dx: -24, dy: -24).contains(point) {
            return (.outsideElement, editable)
        }
        var valueRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &valueRef)
        if error == .success, let text = valueRef as? String {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noSelection : .text(text), editable)
        }
        if error == .noValue { return (.noSelection, editable) }
        return (.failed(role: role), editable)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func isEditable(_ element: AXUIElement, role: String?) -> Bool {
        if let role, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success {
            return settable.boolValue
        }
        return false
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Electron and Chromium apps only build their accessibility tree when asked to.
    private static func enableManualAccessibility(_ pid: pid_t) {
        guard !manualAccessibilityPIDs.contains(pid) else { return }
        manualAccessibilityPIDs.insert(pid)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
    }

    // MARK: Clipboard

    /// Sends ⌘C to the frontmost app, reads the text and puts the previous clipboard back.
    static func copySelection(timeout: TimeInterval = 0.4) -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount
        ClipboardGuard.suppress(for: 1.5)
        postKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        let deadline = Date().addingTimeInterval(timeout)
        while pasteboard.changeCount == before && Date() < deadline { Thread.sleep(forTimeInterval: 0.015) }
        guard pasteboard.changeCount != before else { return nil }
        Thread.sleep(forTimeInterval: 0.04)
        let isFiles = pasteboard.types?.contains(.fileURL) ?? false
        let text = isFiles ? nil : pasteboard.string(forType: .string)
        restore(pasteboard, saved)
        return text
    }

    /// Puts `text` into the app the selection came from, then restores the clipboard.
    @MainActor
    static func paste(_ text: String, into pid: pid_t?) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        ClipboardGuard.suppress(for: 2)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let pid, let app = NSRunningApplication(processIdentifier: pid) { app.activate(options: []) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { restore(pasteboard, saved) }
        }
    }

    static func copyToClipboard(_ text: String) {
        ClipboardGuard.suppress(for: 1)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    static func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    static func restore(_ pasteboard: NSPasteboard, _ items: PasteboardSnapshot) {
        ClipboardGuard.suppress(for: 1)
        pasteboard.clearContents()
        let objects = items.filter { !$0.isEmpty }.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
    }

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// After a ⌃⌥ hotkey, wait until the keys are up so the app sees a clean ⌘C.
    private static func waitForModifierRelease(timeout: TimeInterval = 0.6) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

/// Watches the clipboard for a double ⌘C (GoldenDict's macOS gesture). Needs no permission.
@MainActor
final class ClipboardWatcher {
    var onDoubleCopy: ((String) -> Void)?
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    private var lastChangeAt = Date.distantPast

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        lastCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let count = NSPasteboard.general.changeCount
        guard count != lastCount else { return }
        let delta = count - lastCount
        lastCount = count
        if ClipboardGuard.isActive {
            lastChangeAt = .distantPast
            return
        }
        let now = Date()
        // A jump of 2 inside one 100ms poll is one app writing twice, not two presses.
        if delta == 1, now.timeIntervalSince(lastChangeAt) < 0.6,
           let text = NSPasteboard.general.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastChangeAt = .distantPast
            onDoubleCopy?(text)
        } else {
            lastChangeAt = now
        }
    }
}

/// Global mouse watching for the Doubao-style toolbar.
@MainActor
final class SelectionMonitor {
    var onSelection: ((CapturedSelection, NSPoint) -> Void)?
    /// Mouse down elsewhere (with its location), scroll or a key press.
    var onDismiss: ((NSPoint?) -> Void)?
    var copyFallback = true

    private var monitors: [Any] = []
    private var downPoint = NSPoint.zero
    private var generation = 0
    private var lastDelivered: (text: String, time: Date)?
    private let queue = DispatchQueue(label: "claudedict.selection", qos: .userInitiated)

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        add(.leftMouseDown) { [weak self] event in self?.mouseDown(event) }
        add(.leftMouseUp) { [weak self] event in self?.mouseUp(event) }
        add([.scrollWheel, .keyDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.onDismiss?(nil) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handler(event) }
        }) {
            monitors.append(monitor)
        }
    }

    private func mouseDown(_ event: NSEvent) {
        downPoint = NSEvent.mouseLocation
        generation += 1
        onDismiss?(downPoint)
    }

    private func mouseUp(_ event: NSEvent) {
        let up = NSEvent.mouseLocation
        let dragged = hypot(up.x - downPoint.x, up.y - downPoint.y) > 5
        let multiClick = event.clickCount >= 2
        let shiftClick = event.modifierFlags.contains(.shift)
        guard dragged || multiClick || shiftClick, AXIsProcessTrusted() else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let downAX = dragged ? CGPoint(x: downPoint.x, y: primaryHeight - downPoint.y) : nil
        let allowCopy = copyFallback
        generation += 1
        let gen = generation
        // Give the app a moment to finish updating its selection.
        queue.asyncAfter(deadline: .now() + 0.06) {
            let selection = SelectionReader.read(mode: .mouse, allowCopyFallback: allowCopy, mouseDownAt: downAX)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.generation, let selection else { return }
                    self.deliver(selection, at: up)
                }
            }
        }
    }

    private func deliver(_ selection: CapturedSelection, at point: NSPoint) {
        if let last = lastDelivered, last.text == selection.text, Date().timeIntervalSince(last.time) < 1 { return }
        lastDelivered = (selection.text, Date())
        onSelection?(selection, point)
    }
}

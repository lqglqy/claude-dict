import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts through Carbon's RegisterEventHotKey, which needs no permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    struct Shortcut {
        let id: UInt32
        let keyCode: Int
        let display: String
        let title: String
    }

    /// ⌃⌥ combinations, so they do not collide with Bob's or Easydict's ⌥D / ⌥A / ⌥S defaults.
    static let modifiers = controlKey | optionKey
    static let translate = Shortcut(id: 1, keyCode: kVK_ANSI_D, display: "⌃⌥D", title: "翻译选中文字")
    static let polish = Shortcut(id: 2, keyCode: kVK_ANSI_E, display: "⌃⌥E", title: "润色选中文字")
    static let analyze = Shortcut(id: 3, keyCode: kVK_ANSI_A, display: "⌃⌥A", title: "解析选中文字")
    static let speak = Shortcut(id: 4, keyCode: kVK_ANSI_S, display: "⌃⌥S", title: "朗读选中文字")
    static let input = Shortcut(id: 5, keyCode: kVK_ANSI_I, display: "⌃⌥I", title: "打开输入框")
    static let all = [translate, polish, analyze, speak, input]

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private(set) var failed: [Shortcut] = []

    private func installHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// Registers the shortcuts; returns the ones another app already owns.
    @discardableResult
    func register(_ entries: [(Shortcut, () -> Void)]) -> [Shortcut] {
        installHandler()
        unregisterAll()
        failed = []
        for (shortcut, handler) in entries {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4344_4354), id: shortcut.id) // 'CDCT'
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(Self.modifiers), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[shortcut.id] = ref
                handlers[shortcut.id] = handler
            } else {
                failed.append(shortcut)
            }
        }
        return failed
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }
}

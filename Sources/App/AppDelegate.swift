import AppKit
import SwiftUI

/// Debug/verification modes: render the result window or toolbar to a PNG and quit.
struct LaunchOptions {
    var snapshot: (action: Action, output: String, text: String)?
    var snapshotToolbar: String?
    /// Snapshot only: let the spare warm up this many seconds before the lookup.
    var warmWait: TimeInterval = 0
    /// Skip the welcome window (for scripted smoke tests).
    var noWelcome = false

    init(arguments: [String]) {
        var rest = arguments
        if let i = rest.firstIndex(of: "--warm-wait"), rest.count > i + 1 {
            warmWait = TimeInterval(rest[i + 1]) ?? 0
            rest.removeSubrange(i...(i + 1))
        }
        if let i = rest.firstIndex(of: "--no-welcome") {
            noWelcome = true
            rest.remove(at: i)
        }
        if let i = rest.firstIndex(of: "--snapshot"), rest.count > i + 3,
           let action = Action(rawValue: rest[i + 1]) {
            snapshot = (action, rest[i + 2], rest[(i + 3)...].joined(separator: " "))
        }
        if let i = rest.firstIndex(of: "--snapshot-toolbar"), rest.count > i + 1 {
            snapshotToolbar = rest[i + 1]
        }
    }
}

/// Menu items with closures (NSMenuItem.target is weak, so the item keeps this alive).
final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let app = AppModel.shared
    private let options: LaunchOptions
    private var statusItem: NSStatusItem?
    private var toolbar: ToolbarController!
    private var result: ResultController!
    private let monitor = SelectionMonitor()
    private let clipboard = ClipboardWatcher()
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var timers: [Timer] = []
    private var pendingURLs: [URL] = []
    private var launched = false
    private var hotkeysRegistered = false
    private let hotkeyQueue = DispatchQueue(label: "claudedict.hotkey", qos: .userInitiated)

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        toolbar = ToolbarController(speech: app.speech)
        result = ResultController(app: app)
        result.onOpenSettings = { [weak self] in self?.showSettings() }
        toolbar.onAction = { [weak self] action, selection, point in
            self?.perform(action, text: selection.text, context: selection.context, near: point)
        }
        monitor.onSelection = { [weak self] selection, point in self?.toolbar.show(selection, at: point) }
        monitor.onDismiss = { [weak self] _ in self?.toolbar.hide() }
        clipboard.onDoubleCopy = { [weak self] text in
            self?.result.show(text: text, action: .translate, near: NSEvent.mouseLocation, context: nil)
        }

        if let snapshot = options.snapshot {
            runSnapshot(snapshot)
            return
        }
        if let path = options.snapshotToolbar {
            runToolbarSnapshot(path)
            return
        }

        setupStatusItem()
        app.onSettingsChanged = { [weak self] in self?.applySettings() }
        app.locateClaude()
        applySettings()
        observeSystem()
        handleTerminationSignal()
        launched = true
        pendingURLs.forEach(handle)
        pendingURLs.removeAll()
        logStartup()
        if !options.noWelcome, !UserDefaults.standard.bool(forKey: "welcomeShown") || !app.accessibilityTrusted {
            showWelcome()
        }
    }

    /// `pkill ClaudeDict` (used by build.sh --install) should quit cleanly and stop the spares.
    private var termSource: DispatchSourceSignal?
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source
    }

    /// One line on stdout describing the running state; visible when started from a terminal.
    private func logStartup() {
        app.whenClaudeReady { [weak self] in
            guard let self else { return }
            let failed = HotKeyCenter.shared.failed.map(\.display).joined(separator: " ")
            let warm = self.app.settings.modelsInUse.map { "\($0)=\(self.app.pool.spareCount(model: $0))" }
                .joined(separator: " ")
            print("ClaudeDict ready: claude=\(self.app.claudePath ?? "missing") spares[\(warm)] "
                + "accessibility=\(self.app.accessibilityTrusted) selectionMonitor=\(self.monitor.isRunning) "
                + "hotkeys=\(self.app.settings.hotkeysEnabled ? (failed.isEmpty ? "ok" : "taken: \(failed)") : "off")")
            fflush(stdout)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        result?.close()
        app.pool.shutdown(wait: 1)
        app.speech.stop()
    }

    // MARK: Actions

    private func perform(_ action: ToolbarAction, text: String, context: SelectionContext?, near point: NSPoint) {
        if let lookup = action.lookup {
            result.show(text: text, action: lookup, near: point, context: context, focusInput: text.isEmpty)
            return
        }
        switch action {
        case .speak: app.speech.toggle(text)
        case .copy: SelectionReader.copyToClipboard(text)
        default: break
        }
    }

    /// Hotkey path: read the selection; with nothing selected open the input box. Without
    /// Accessibility permission the selection cannot be read, so use the clipboard instead.
    private func runOnSelection(_ action: ToolbarAction) {
        toolbar.hide()
        let point = NSEvent.mouseLocation
        let allowCopy = app.settings.copyFallbackEnabled
        let trusted = AXIsProcessTrusted()
        hotkeyQueue.async {
            let selection = trusted ? SelectionReader.read(mode: .hotkey, allowCopyFallback: allowCopy) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var text = selection?.text ?? ""
                    if text.isEmpty, !trusted { text = NSPasteboard.general.string(forType: .string) ?? "" }
                    if text.isEmpty, action == .speak || action == .copy { return }
                    self.perform(action, text: text, context: selection?.context, near: point)
                }
            }
        }
    }

    func showInput() {
        toolbar.hide()
        result.show(text: "", action: .translate, near: NSEvent.mouseLocation, context: nil, focusInput: true)
    }

    private func translateClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        result.show(text: text, action: .translate, near: NSEvent.mouseLocation, context: nil, focusInput: text.isEmpty)
    }

    // MARK: Settings

    private func applySettings() {
        let settings = app.settings
        monitor.copyFallback = settings.copyFallbackEnabled
        toolbar.autoHideSeconds = settings.toolbarAutoHideSeconds
        if settings.toolbarEnabled && app.accessibilityTrusted {
            monitor.start()
        } else {
            monitor.stop()
            toolbar.hide()
        }
        if settings.doubleCopyEnabled { clipboard.start() } else { clipboard.stop() }
        // Re-register only when the switch changes, not on every settings tweak (e.g. a slider).
        guard settings.hotkeysEnabled != hotkeysRegistered else { return }
        hotkeysRegistered = settings.hotkeysEnabled
        if settings.hotkeysEnabled {
            HotKeyCenter.shared.register([
                (HotKeyCenter.translate, { [weak self] in self?.runOnSelection(.translate) }),
                (HotKeyCenter.polish, { [weak self] in self?.runOnSelection(.polish) }),
                (HotKeyCenter.analyze, { [weak self] in self?.runOnSelection(.analyze) }),
                (HotKeyCenter.speak, { [weak self] in self?.runOnSelection(.speak) }),
                (HotKeyCenter.input, { [weak self] in self?.showInput() }),
            ])
        } else {
            HotKeyCenter.shared.unregisterAll()
        }
    }

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.app.pool.recycleAll() }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toolbar.hide() }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.app.pool.refreshStale() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.app.accessibilityTrusted
                self.app.refreshAccessibility()
                if before != self.app.accessibilityTrusted { self.applySettings() }
            }
        })
    }

    // MARK: Windows

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(app: app)))
            window.title = "ClaudeDict 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showWelcome() {
        if welcomeWindow == nil {
            let view = WelcomeView(app: app) { [weak self] in
                UserDefaults.standard.set(true, forKey: "welcomeShown")
                self?.welcomeWindow?.close()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "欢迎使用 ClaudeDict"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            welcomeWindow = window
        }
        NSApp.activate()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "ClaudeDict")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "ClaudeDict"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild(menu) }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        if !app.accessibilityTrusted {
            add(menu, "⚠️ 划词需要辅助功能权限…") { [weak self] in self?.app.requestAccessibility() }
        }
        if app.claudeStatus == .missing {
            add(menu, "⚠️ 没有找到 claude 命令行…") { [weak self] in self?.showSettings() }
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        add(menu, "打开输入框", key: "i", modifiers: [.control, .option]) { [weak self] in self?.showInput() }
        add(menu, "翻译剪贴板") { [weak self] in self?.translateClipboard() }
        if app.speech.isSpeaking {
            add(menu, "停止朗读") { [weak self] in self?.app.speech.stop() }
        }
        menu.addItem(.separator())
        add(menu, "选中文字后显示工具条", state: app.settings.toolbarEnabled) { [weak self] in
            self?.app.settings.toolbarEnabled.toggle()
        }
        add(menu, "连按两次 ⌘C 弹出翻译", state: app.settings.doubleCopyEnabled) { [weak self] in
            self?.app.settings.doubleCopyEnabled.toggle()
        }
        menu.addItem(.separator())
        add(menu, "使用说明…") { [weak self] in self?.showWelcome() }
        add(menu, "设置…", key: ",") { [weak self] in self?.showSettings() }
        menu.addItem(.separator())
        add(menu, "退出 ClaudeDict", key: "q") { NSApp.terminate(nil) }
    }

    private func add(_ menu: NSMenu, _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
                     state: Bool? = nil, handler: @escaping () -> Void) {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = action
        item.representedObject = action
        if let state { item.state = state ? .on : .off }
        menu.addItem(item)
    }

    // MARK: URL scheme: claudedict://translate?text=…

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        if launched { handle(url) } else { pendingURLs.append(url) }
    }

    private func handle(_ url: URL) {
        let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "text" }?.value ?? ""
        let point = NSEvent.mouseLocation
        switch url.host ?? "" {
        case "translate": perform(.translate, text: text, context: nil, near: point)
        case "polish": perform(.polish, text: text, context: nil, near: point)
        case "analyze": perform(.analyze, text: text, context: nil, near: point)
        case "speak": app.speech.speak(text)
        case "input": showInput()
        case "settings": showSettings()
        default: break
        }
    }

    // MARK: Verification snapshots

    private func runSnapshot(_ snapshot: (action: Action, output: String, text: String)) {
        app.locateClaude(models: [app.settings.model(for: snapshot.action)])
        DispatchQueue.main.asyncAfter(deadline: .now() + options.warmWait) {
            MainActor.assumeIsolated { self.snapshotLookup(snapshot) }
        }
    }

    private func snapshotLookup(_ snapshot: (action: Action, output: String, text: String)) {
        // Pinned, so a click elsewhere on the screen does not close the panel mid-lookup.
        result.model.pinned = true
        result.show(text: snapshot.text, action: snapshot.action, near: NSPoint(x: 600, y: 700), context: nil)
        result.moveOffscreen()
        let started = Date()
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                let phase = self.result.model.phase
                let finished: Bool
                switch phase {
                case .done, .failed: finished = true
                default: finished = Date().timeIntervalSince(started) > 90
                }
                guard finished else { return }
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    MainActor.assumeIsolated {
                        do {
                            try self.result.capture(to: URL(fileURLWithPath: snapshot.output))
                            print("snapshot: \(snapshot.output) phase=\(self.result.model.phase) status=\(self.result.model.statusLine)")
                            print(self.result.model.output)
                        } catch {
                            print("snapshot failed: \(error)")
                        }
                        NSApp.terminate(nil)
                    }
                }
            }
        })
    }

    private func runToolbarSnapshot(_ path: String) {
        let selection = CapturedSelection(text: "serendipity", context: SelectionContext(pid: nil, bundleID: nil, isEditable: false))
        toolbar.autoHideSeconds = 30
        toolbar.show(selection, at: NSPoint(x: 600, y: 600))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                do {
                    try self.toolbar.capture(to: URL(fileURLWithPath: path))
                    print("snapshot: \(path)")
                } catch {
                    print("snapshot failed: \(error)")
                }
                NSApp.terminate(nil)
            }
        }
    }
}

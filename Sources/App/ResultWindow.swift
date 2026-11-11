import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class LookupViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle, waiting, streaming, done
        case failed(String)
    }

    @Published var sourceText = ""
    @Published private(set) var action: Action = .translate
    @Published private(set) var output = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stats: LookupStats?
    @Published private(set) var input: TextInput?
    @Published var pinned = false
    @Published var focusRequest = 0
    @Published var blurRequest = 0
    /// One-off message shown in the footer (e.g. why 替换 could not paste).
    @Published var notice: String?
    private(set) var context: SelectionContext?

    private unowned let app: AppModel
    private var handle: LookupHandle?
    private var generation = 0

    init(app: AppModel) {
        self.app = app
    }

    var modelName: String { app.settings.model(for: action) }
    var isBusy: Bool { phase == .waiting || phase == .streaming }

    func start(text: String, action: Action, context: SelectionContext?) {
        sourceText = text
        self.action = action
        self.context = context
        run()
    }

    func switchAction(_ newAction: Action) {
        guard newAction != action else { return }
        action = newAction
        run()
    }

    func run(useCache: Bool = true) {
        handle?.cancel()
        handle = nil
        generation += 1
        let gen = generation
        let input = TextAnalyzer.analyze(sourceText)
        self.input = input
        output = ""
        stats = nil
        notice = nil
        guard !input.text.isEmpty else {
            phase = .idle
            return
        }
        phase = .waiting
        let action = self.action
        app.whenClaudeReady { [weak self] in
            guard let self, gen == self.generation else { return }
            let model = self.app.settings.model(for: action)
            self.handle = self.app.engine.run(action: action, input: input, model: model, useCache: useCache,
                                              queue: .main) { [weak self] update in
                MainActor.assumeIsolated { self?.apply(update, generation: gen) }
            }
        }
    }

    func retry() { run(useCache: false) }

    func cancel() {
        generation += 1
        handle?.cancel()
        handle = nil
        if isBusy { phase = output.isEmpty ? .idle : .done }
    }

    private func apply(_ update: SessionUpdate, generation gen: Int) {
        guard gen == generation else { return }
        switch update {
        case .partial(let text):
            output = text
            phase = .streaming
        case .finished(let text, let stats):
            output = text
            self.stats = stats
            phase = .done
            handle = nil
        case .failed(let message):
            phase = .failed(message)
            handle = nil
        }
    }

    /// For polish, only the rewritten text; otherwise the whole answer.
    var copyText: String {
        if action == .polish, let polished = Prompts.extractPolished(from: output) { return polished }
        return output
    }

    /// What "替换原文" pastes over the selection. Needs the app the text came from and permission
    /// to send ⌘V; typed-in text has nothing to replace.
    var replacementText: String? {
        Prompts.replacementText(action: action, output: output, finished: phase == .done,
                                fromSourceApp: context?.pid != nil && AXIsProcessTrusted())
    }

    /// English in the answer worth reading aloud.
    var speakableOutput: String? {
        guard phase == .done else { return nil }
        if action == .polish { return Prompts.extractPolished(from: output) }
        if action == .translate, input?.language == .chinese, input?.kind != .word { return output }
        return nil
    }

    var statusLine: String {
        let model = (stats?.model ?? modelName).replacingOccurrences(of: "claude-", with: "")
        switch phase {
        case .idle: return "回车查询 · Esc 关闭"
        case .waiting: return "\(model) · 等待中…"
        case .streaming: return "\(model) · 生成中…"
        case .failed: return "出错了"
        case .done:
            guard let stats else { return model }
            if stats.cached { return "\(model) · 来自缓存" }
            let first = stats.firstTokenMs.map { String(format: "首字 %.1fs · ", Double($0) / 1000) } ?? ""
            return "\(model) · \(first)共 \(String(format: "%.1fs", Double(stats.totalMs) / 1000))"
        }
    }
}

struct ResultView: View {
    @ObservedObject var model: LookupViewModel
    @ObservedObject var speech: SpeechController
    @ObservedObject var app: AppModel
    var onClose: () -> Void
    var onReplace: (String) -> Void
    var onOpenSettings: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            source
            Divider()
            content
            Divider()
            footer
        }
        .onChange(of: model.focusRequest) { _, _ in inputFocused = true }
        .onChange(of: model.blurRequest) { _, _ in inputFocused = false }
    }

    private var header: some View {
        HStack(spacing: 2) {
            ForEach(Action.allCases, id: \.self) { action in
                let selected = model.action == action
                Button { model.switchAction(action) } label: {
                    Label(action.title, systemImage: action.symbol)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                }
                .buttonStyle(HoverButtonStyle(selected: selected))
            }
            Spacer(minLength: 8)
            IconButton(symbol: model.pinned ? "pin.fill" : "pin",
                       help: model.pinned ? "取消固定" : "固定：点击外部不关闭，新的查询都显示在这里") {
                model.pinned.toggle()
            }
            IconButton(symbol: "xmark", help: "关闭（Esc）", action: onClose)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(WindowDragArea())
    }

    private var source: some View {
        HStack(alignment: .top, spacing: 6) {
            TextField("输入英文或中文，回车查询", text: $model.sourceText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { model.run() }
            if let replacement = model.replacementText {
                Button { onReplace(replacement) } label: {
                    Label("替换原文", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(HoverButtonStyle(selected: true))
                .keyboardShortcut(.return, modifiers: .command)
                .help("把选中的原文直接换成润色结果（⌘↩）")
            }
            if !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                IconButton(symbol: speech.isReading(model.sourceText) ? "stop.fill" : "speaker.wave.2",
                           help: "朗读原文") {
                    speech.toggle(model.sourceText)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var content: some View {
        ScrollView {
            Group {
                if case .failed(let message) = model.phase {
                    errorView(message)
                } else if model.output.isEmpty {
                    placeholder
                } else {
                    MarkdownView(text: model.output, streaming: model.phase == .streaming)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.phase == .waiting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(model.modelName) 正在\(model.action.title)…").foregroundStyle(.secondary)
            }
        } else {
            Text("在任意 App 里选中文字后点工具条，或在上方输入后回车。")
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("没有拿到结果", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("重试") { model.retry() }
                if app.claudeStatus == .missing {
                    Button("打开设置", action: onOpenSettings)
                }
            }
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(model.notice ?? model.statusLine)
                .font(.system(size: 11))
                .foregroundStyle(model.notice == nil ? Color.secondary : Color.orange)
                .lineLimit(2)
            Spacer(minLength: 4)
            if let speakable = model.speakableOutput {
                IconButton(symbol: speech.isReading(speakable) ? "stop.fill" : "speaker.wave.2", help: "朗读结果") {
                    speech.toggle(speakable)
                }
            }
            TextButton(title: copied ? "已复制" : "复制", symbol: copied ? "checkmark" : "doc.on.doc") {
                SelectionReader.copyToClipboard(model.copyText)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            .disabled(model.output.isEmpty)
            IconButton(symbol: "arrow.clockwise", help: "重新生成（不用缓存）") { model.retry() }
                .disabled(model.sourceText.isEmpty)
            ResizeGrip().frame(width: 12, height: 12).padding(.leading, 2)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
    }
}

/// The GoldenDict-style result pop-up: appears near the selection, closes on an outside click
/// unless pinned, and remembers its size.
@MainActor
final class ResultController: NSObject, NSWindowDelegate {
    let model: LookupViewModel
    var onOpenSettings: (() -> Void)?

    private let app: AppModel
    private var panel: FloatingPanel?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private static let sizeKey = "resultPanel.size"

    init(app: AppModel) {
        self.app = app
        model = LookupViewModel(app: app)
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(text: String, action: Action, near point: NSPoint, context: SelectionContext?, focusInput: Bool = false) {
        let panel = ensurePanel()
        let keepPlace = panel.isVisible && model.pinned
        model.start(text: text, action: action, context: context)
        if !keepPlace { place(panel, near: point) }
        if focusInput || text.isEmpty {
            panel.makeKeyAndOrderFront(nil)
            model.focusRequest += 1
        } else {
            // Show the result without putting the source field into editing (select-all) state.
            panel.orderFrontRegardless()
            model.blurRequest += 1
            panel.makeFirstResponder(nil)
        }
        startMonitors()
    }

    func close() {
        model.cancel()
        panel?.orderOut(nil)
        stopMonitors()
    }

    func moveOffscreen() {
        guard let panel else { return }
        panel.setFrameOrigin(NSPoint(x: -8000, y: -8000))
    }

    func capture(to url: URL) throws {
        guard let view = panel?.contentView else { return }
        try Snapshot.write(view, to: url)
    }

    private func ensurePanel() -> FloatingPanel {
        if let panel { return panel }
        let panel = FloatingPanel(allowsKey: true, resizable: true, level: .floating)
        panel.minSize = NSSize(width: 340, height: 220)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        let view = ResultView(model: model, speech: app.speech, app: app,
                              onClose: { [weak self] in self?.close() },
                              onReplace: { [weak self] text in self?.replace(with: text) },
                              onOpenSettings: { [weak self] in self?.onOpenSettings?() })
        panel.contentView = PanelChrome.wrap(FirstMouseHostingView(rootView: view), radius: 12)
        self.panel = panel
        return panel
    }

    private var preferredSize: NSSize {
        if let saved = UserDefaults.standard.string(forKey: Self.sizeKey) {
            let size = NSSizeFromString(saved)
            if size.width >= 340, size.height >= 220 { return size }
        }
        return NSSize(width: 460, height: 480)
    }

    /// Below-right of the selection; flips above when there is no room.
    private func place(_ panel: NSPanel, near point: NSPoint) {
        let size = preferredSize
        let visible = FloatingPanel.visibleFrame(at: point)
        var origin = NSPoint(x: point.x - 12, y: point.y - 18 - size.height)
        if origin.y < visible.minY + 8 { origin.y = point.y + 18 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func replace(with text: String) {
        guard let pid = model.context?.pid else { return }
        // The panel never activates ClaudeDict, so the source app should still be in front.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            SelectionReader.copyToClipboard(text)
            model.notice = "原文所在的 App 已不在前台，润色结果已复制，请手动粘贴。"
            return
        }
        close()
        SelectionReader.paste(text, into: pid) { pasted in
            if !pasted {
                SelectionReader.copyToClipboard(text)
                NSSound.beep()
            }
        }
    }

    private func startMonitors() {
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.model.pinned else { return }
                    self.close()
                }
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.keyCode == 53, let panel = self.panel, panel.isKeyWindow else { return event }
                    self.close()
                    return nil
                }
            }
        }
    }

    private func stopMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    nonisolated func windowDidEndLiveResize(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let frame = panel?.frame else { return }
            UserDefaults.standard.set(NSStringFromSize(frame.size), forKey: Self.sizeKey)
        }
    }
}

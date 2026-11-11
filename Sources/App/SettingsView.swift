import AVFoundation
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @State private var claudePathDraft = ""
    @State private var testOutput = ""
    @State private var testing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    private let voices = SpeechController.voices(prefix: "en")

    var body: some View {
        Form {
            Section {
                modelPicker("翻译", selection: $app.settings.translateModel)
                modelPicker("润色", selection: $app.settings.polishModel)
                modelPicker("解析", selection: $app.settings.analyzeModel)
            } header: {
                Text("模型")
            } footer: {
                Text("通过 claude -p --model 调用。本机实测：haiku 预热后首字约 0.5 秒，sonnet 约 0.9 秒。每个用到的模型常驻一个预热的 claude 进程。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("划词") {
                Toggle("选中文字后显示工具条（豆包式）", isOn: $app.settings.toolbarEnabled)
                Toggle("连按两次 ⌘C 弹出翻译（GoldenDict 式，无需权限）", isOn: $app.settings.doubleCopyEnabled)
                Toggle("读不到选区时模拟 ⌘C（随后恢复剪贴板）", isOn: $app.settings.copyFallbackEnabled)
            }

            Section {
                Toggle("启用全局快捷键", isOn: $app.settings.hotkeysEnabled)
                ForEach(HotKeyCenter.all, id: \.id) { shortcut in
                    LabeledContent(shortcut.title) {
                        HStack(spacing: 6) {
                            Text(shortcut.display).monospaced()
                            if app.settings.hotkeysEnabled, HotKeyCenter.shared.failed.contains(where: { $0.id == shortcut.id }) {
                                Text("已被其他 App 占用").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } header: {
                Text("快捷键")
            }

            Section("朗读") {
                Picker("英文语音", selection: voiceBinding) {
                    Text("自动（音质最好的美式英语）").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name)（\(voice.language)，\(SpeechController.qualityLabel(voice))）").tag(voice.identifier)
                    }
                }
                HStack {
                    Text("语速")
                    Slider(value: $app.settings.speechRate, in: 0.3...0.6)
                    Button("试听") { app.speech.speak("Serendipity means finding something good without looking for it.") }
                }
                Text("想要更自然的声音：系统设置 › 辅助功能 › 朗读内容 › 系统声音 › 管理声音，下载 Premium 或 Enhanced 的英文语音。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Claude 命令行") {
                LabeledContent("状态") { statusText }
                HStack {
                    TextField("自定义 claude 路径（留空则自动查找）", text: $claudePathDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("应用") {
                        let trimmed = claudePathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        let value: String? = trimmed.isEmpty ? nil : trimmed
                        if value == app.settings.claudePath { app.locateClaude() } else { app.settings.claudePath = value }
                    }
                }
                HStack {
                    Button("重新检测") { app.locateClaude() }
                    Button(testing ? "测试中…" : "测试一次翻译") { runTest() }.disabled(testing)
                    Text(testOutput).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Section("权限与启动") {
                LabeledContent("辅助功能（划词需要）") {
                    if app.accessibilityTrusted {
                        Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("去授权") { app.requestAccessibility() }
                    }
                }
                Text("重新编译安装后 macOS 会把它当成新的 App：先在“隐私与安全性 › 辅助功能”里删掉旧的 ClaudeDict，再重新添加勾选。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLoginItem(enabled) }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 700)
        .onAppear { claudePathDraft = app.settings.claudePath ?? "" }
    }

    @ViewBuilder
    private var statusText: some View {
        switch app.claudeStatus {
        case .checking:
            Text("查找中…").foregroundStyle(.secondary)
        case .found(let path):
            Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        case .missing:
            Text("没有找到可用的 claude").foregroundStyle(.red)
        }
    }

    private var voiceBinding: Binding<String> {
        Binding(get: { app.settings.voiceIdentifier ?? "" },
                set: { app.settings.voiceIdentifier = $0.isEmpty ? nil : $0 })
    }

    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        let current = selection.wrappedValue
        let options = AppSettings.suggestedModels.contains(current)
            ? AppSettings.suggestedModels : AppSettings.suggestedModels + [current]
        return Picker(title, selection: selection) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
    }

    private func runTest() {
        testing = true
        testOutput = ""
        let model = app.settings.translateModel
        app.whenClaudeReady {
            app.engine.run(action: .translate, input: TextAnalyzer.analyze("serendipity"), model: model,
                           useCache: false, queue: .main) { update in
                MainActor.assumeIsolated {
                    switch update {
                    case .partial:
                        break
                    case .finished(let text, let stats):
                        let first = text.split(separator: "\n").first.map(String.init) ?? text
                        let seconds = String(format: "%.1f", Double(stats.totalMs) / 1000)
                        testOutput = "✓ \(seconds)s：\(first)"
                        testing = false
                    case .failed(let message):
                        testOutput = "✗ \(message)"
                        testing = false
                    }
                }
            }
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        let isEnabled = SMAppService.mainApp.status == .enabled
        guard enabled != isEnabled else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "设置登录启动失败：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var app: AppModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ClaudeDict 已在菜单栏运行").font(.title3.bold())
                    Text("划词翻译、润色、解析和朗读，背后是 claude -p。").foregroundStyle(.secondary)
                }
            }
            Divider()
            step(1, "允许辅助功能权限", detail: "用来读取你选中的文字，并在选区旁显示工具条。", done: app.accessibilityTrusted) {
                Button("打开系统设置") { app.requestAccessibility() }
            }
            step(2, "Claude Code 命令行", detail: claudeDetail, done: app.claudePath != nil) {
                Button("重新检测") { app.locateClaude() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("怎么用").font(.headline)
                Text("• 在任意 App 里选中英文，旁边出现工具条：翻译 · 润色 · 解析 · 朗读 · 复制")
                Text("• 快捷键：⌃⌥D 翻译 · ⌃⌥E 润色 · ⌃⌥A 解析 · ⌃⌥S 朗读 · ⌃⌥I 输入框")
                Text("• 结果窗口：Esc 关闭；点图钉固定后，新的查询都显示在同一个窗口")
                Text("• 润色结果可以一键“替换原文”，直接改写你正在写的邮件或文档")
            }
            .font(.system(size: 13))
            HStack {
                Spacer()
                Button("开始使用", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var claudeDetail: String {
        switch app.claudeStatus {
        case .checking: return "正在查找 claude…"
        case .found(let path): return "使用 \(path)"
        case .missing: return "没有找到可用的 claude。请安装 Claude Code 并登录，或在设置里填写路径。"
        }
    }

    private func step<Accessory: View>(_ number: Int, _ title: String, detail: String, done: Bool,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.system(size: 18))
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done { accessory() }
        }
    }
}

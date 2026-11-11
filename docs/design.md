# ClaudeDict 设计说明

2026-11-10

## 目标

在 macOS 上做一个豆包式的划词 AI 工具：选中文字后出现工具条，可以翻译、润色、解析、朗读，主要服务英译中和英文写作。LLM 后端用 `claude -p`。

## 为什么是原生 Swift，而不是 fork GoldenDict

需求里提到“基于 GoldenDict”。动手前查了这台机器：

- 没有安装 GoldenDict，也没有它的源码。
- 没有 Qt；GoldenDict-ng 是 C++/Qt6（含 WebEngine）的大工程，在这里编译要先装 Qt 和十来个依赖。
- 只有 Xcode Command Line Tools，没有完整 Xcode；SwiftPM 编译 Package.swift 会链接失败（PackageDescription 符号缺失），`swiftc` 本身可用。
- GoldenDict 在 macOS 上的弹窗靠剪贴板触发，没有“选中即出工具条”。豆包式的交互无论如何都要新写。

所以做了一个原生 App，保留 GoldenDict 的交互习惯，并能接回 GoldenDict：

- 结果窗口就是 GoldenDict 式的查词弹窗：出现在选区旁，点别处关闭，可以固定。
- 单词结果是词典格式：英美音标、词性释义、例句。
- 支持 GoldenDict 在 macOS 上的“连按两次 ⌘C”查词。
- 可执行文件带 `--cli` 模式，可以在 GoldenDict 里配成“程序”词典（Html 类型）。

如果之后确实要在 GoldenDict-ng 源码里加 AI，`Sources/Core` 里的提示词、流式解析和预热进程池可以直接对照移植。

## 结构

```
Sources/Core   与界面无关，可测试
  TextAnalyzer   清理选中文本（PDF 断行、连字符、单词两侧标点），判断语言和类型（单词/短语/句子/段落）
  Prompts        一个通用 system prompt + 按 动作 × 语言 × 类型 的任务说明
  StreamParser   解析 claude -p 的 stream-json 输出；LineBuffer 处理跨块的 UTF-8
  Markdown       提示词要求的 Markdown 子集，按行解析（流式输出随时可渲染），也能转 HTML
  ClaudeCommand  启动参数、环境变量、claude 路径查找（逐个用 --version 验证）
  ClaudeSession  一个 claude -p 进程：先启动等待，再写入一条消息；SparePool 预热池；LookupEngine 加缓存
  Settings       设置（缺字段时用默认值）和 LRU 缓存
Sources/App    AppKit + SwiftUI
  SelectionReader  辅助功能读选区，失败时模拟 ⌘C 并恢复剪贴板；ClipboardWatcher（⌘C⌘C）；SelectionMonitor（全局鼠标）
  Toolbar          选区旁的工具条
  ResultWindow     结果窗口和它的 view model
  Speech           AVSpeechSynthesizer 朗读
  HotKeys          Carbon RegisterEventHotKey 全局快捷键
  AppDelegate      菜单栏、设置联动、URL scheme、snapshot 自检模式
  CLI              --cli 命令行模式
  SelfTest         --selftest-ax 辅助功能自检
```

## 调用 claude 的方式

每个进程的参数：

```
claude -p --model <m> --system-prompt <通用提示词> --tools "" --no-session-persistence --safe-mode
       --input-format stream-json --output-format stream-json --include-partial-messages --verbose
```

- `--safe-mode`：不加载用户的 hooks、插件、MCP、CLAUDE.md，但保留 OAuth 登录。本机实测 haiku 冷启动首字从 12.25 秒降到 3.86 秒（`scripts/probes/probe_latency.py haiku` 与加 `--safe-mode` 各 1 次，2026-11-10）。不用 `--bare`，因为它只认 API key，不读 OAuth 登录。
- 预热：进程先启动，在 stdin 上等待；查询时写入一条 stream-json 消息并关闭 stdin，进程回答一次后退出。本机实测预热后 haiku 首字 0.53 秒、sonnet 0.92 秒，冷启动是 3.86 秒和 4.15 秒（`scripts/probes/probe_prewarm.py`、`probe_latency.py`，各 1 次）。闲置 60 秒后的预热进程仍可用（首字 0.63 秒），内存约 42 MB，启动 5 秒时约 206 MB（`scripts/probes/probe_idle.py`，进程树 RSS 合计）。走 App 完整代码路径的预热耗时用 `scripts/bench-warm.sh` 测，结果见 README。
- 预热池：每个用到的模型一个进程；被取走后 0.5 秒补一个；超过 20 分钟或已退出的每 5 分钟替换；Mac 唤醒后全部重建；退出 App 时等最多 1 秒，仍在运行的直接 SIGKILL。
- 错误：未知模型等错误在 stream-json 里是 `result` 事件，`subtype` 仍为 `success`，但 `is_error: true`，进程退出码 1；按 `is_error` 判断。进程崩溃没有 result 时，报告退出码和 stderr 末尾。
- 选中的文本放在 `<text>…</text>` 里，system prompt 说明它是数据而不是指令；文本中的 `<text>`、`</text>` 会被改写，不能提前闭合。

## 读选区

1. 只在拖选、双击/三击、Shift 点击之后读取，且前台不是 ClaudeDict 自己。
2. 先用辅助功能读焦点元素的 `AXSelectedText`。密码框（`AXSecureTextField`）直接跳过。拖选起点不在焦点元素范围内（比如拖窗口）时不弹工具条。
3. 辅助功能读取失败、且焦点不是列表、表格、按钮这类非文本控件、前台也不是 Finder 时，模拟 ⌘C，读完恢复剪贴板。
4. Electron/Chromium 应用会先设置 `AXManualAccessibility`，让它们暴露辅助功能树。

## 验证

- `scripts/test.sh`：50 项核心自测，用 `Tests/fixtures/fake-claude.sh` 模拟 stream-json 协议，不联网。为确认测试真能发现问题，做过 6 次故意破坏（去掉 --safe-mode、把错误当成功、按块解码 UTF-8、不读缓存、关机时不 SIGKILL、预热进程启动即失败时丢掉原因），每次都由对应的测试报错，恢复后全部通过。
- `--selftest-ax`：在本进程的屏幕外窗口里放一个 NSTextView 和一个密码框，用真实的辅助功能 API 读取选区、可编辑性、元素范围，并确认不读密码框。去掉密码框判断后该项报错。
- `--snapshot`：用真实 claude 跑一次查询，把结果窗口画成 PNG 检查排版，也用来测预热后的耗时（数据见 README）。
- 正常模式启动检查：找到 `~/.local/bin/claude`，haiku、sonnet 各一个预热进程，5 个快捷键都注册成功；收到 SIGTERM 后正常退出，没有遗留 claude 进程。

## 已知限制和后续可做

- ad-hoc 签名：每次重新编译后要重新授权辅助功能。如果需要，可以建一个自签名证书固定签名。
- 没有真机点击测试：工具条按钮、结果窗口拖动和缩放、替换原文等交互没有自动化测试，是按 AppKit 的标准做法实现的，需要人用一遍。
- GoldenDict 的“程序”词典每次都冷启动（约 5.9 秒）。可以让 CLI 通过本地 socket 复用正在运行的 App 里的预热进程。
- 还没有查词历史和生词本（GoldenDict 有历史和收藏），可以加在菜单栏里。

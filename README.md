# ClaudeDict

macOS 菜单栏上的划词工具：在任意 App 里选中英文，旁边出现一个小工具条，可以 **翻译 · 润色 · 解析 · 朗读 · 复制**。交互参考豆包的划词和 GoldenDict 的弹窗查词，后端是本机的 `claude -p`。

- **翻译**：单词给出词典式释义（英美音标、词性、例句），句子和段落给出地道的中文译文；选中中文则译成英文。
- **润色**：英文改写成母语者的写法，并逐条说明改了什么、为什么；结果可以一键“替换原文”。
- **解析**：单词讲词源、搭配、例句和辨析；句子讲结构、语法和重点词汇；段落讲大意和难句。
- **朗读**：系统自带语音，离线，可选声音和语速。

## 安装

需要 macOS 14 或更新，装好 Xcode Command Line Tools，并且 Claude Code 已登录（终端里 `claude` 能用）。

```bash
cd <仓库目录>
scripts/build.sh --install
```

会编译并安装到 `~/Applications/ClaudeDict.app`，然后启动。菜单栏会出现一个书本图标。

第一次使用要给“辅助功能”权限（读取选中的文字需要它）：菜单栏图标 › “⚠️ 划词需要辅助功能权限…”，或在 系统设置 › 隐私与安全性 › 辅助功能 里打开 ClaudeDict。

> 这个 App 是本地 ad-hoc 签名的。每次重新编译安装后，macOS 会把它当成新的 App，需要重新勾选一次辅助功能。`build.sh --install` 会先清掉旧的授权记录。

## 使用

| 操作 | 方式 |
| --- | --- |
| 划词 | 选中文字（拖选、双击、Shift 点击）后出现工具条 |
| 翻译选中文字 | ⌃⌥D |
| 润色选中文字 | ⌃⌥E |
| 解析选中文字 | ⌃⌥A |
| 朗读选中文字 | ⌃⌥S |
| 打开输入框 | ⌃⌥I（没选中文字时按 ⌃⌥D 也会打开） |
| 连按两次 ⌘C | GoldenDict 的 macOS 查词方式，默认关闭，在设置里打开；不需要辅助功能权限 |
| 替换原文 | 润色完成后，原文旁边出现“替换原文”按钮（窗口在前台时也可以按 ⌘↩），把你选中的文字直接换成润色结果 |
| 结果窗口 | Esc 关闭；点图钉固定后，点别处不关闭，新的查询都显示在这个窗口 |

快捷键用的是 ⌃⌥ 组合，避开了 Bob、Easydict 默认的 ⌥D、⌥A、⌥S。

也可以用 URL 调起，方便接 Alfred、Raycast 或脚本：

```bash
open "claudedict://translate?text=serendipity"   # 还有 polish、analyze、speak、input、settings
```

## 速度

每个用到的模型都常驻一个预热好的 `claude -p` 进程，查词时直接用，用完立刻补一个。以下是本机实测（2026-11-10，`claude` 2.1.322，`scripts/bench-warm.sh`：App 的 snapshot 模式，预热 8 秒后查询）：

| 场景 | 首字 | 总耗时 |
| --- | --- | --- |
| haiku 查单词 ubiquitous（3 次） | 0.5–0.6 秒 | 1.1–1.2 秒 |
| haiku 翻译一句话（2 次） | 0.5–0.6 秒 | 0.7–0.8 秒 |
| sonnet 润色一句话（2 次） | 0.5–0.8 秒 | 1.6–2.3 秒 |
| 对照：不预热的冷启动，haiku 查单词（snapshot 不加 --warm-wait，1 次） | 4.4 秒 | 5.2 秒 |

默认模型：翻译用 haiku，润色和解析用 sonnet，可以在设置里改（haiku、sonnet、opus、fable）。同样的查询有内存缓存，第二次是瞬间出来的。

## 接入 GoldenDict

ClaudeDict 的可执行文件带一个命令行模式，可以作为 GoldenDict / GoldenDict-ng 的“程序”词典来源：

GoldenDict › 编辑 › 词典 › 词典来源 › 程序 › 添加：

- 类型：`Html`
- 名称：`Claude 翻译`
- 命令行：`/Users/<你的用户名>/Applications/ClaudeDict.app/Contents/MacOS/ClaudeDict --cli translate --html %GDWORD%`

想在 GoldenDict 里看单词精讲，再加一条，把 `translate` 换成 `analyze`。GoldenDict 每次查词都会新起一个进程，用不上预热，单词翻译本机实测约 5.9 秒（冷启动，2026-11-10）。

命令行也可以直接用：

```bash
ClaudeDict --cli translate serendipity
ClaudeDict --cli polish "I want discuss with you about the plan."
echo "Had I known, I would have come." | ClaudeDict --cli analyze
```

## 隐私

- 只有在你点工具条按钮或按快捷键时，选中的文字才会发给 Claude。单纯选中文字只在本机读取，不会发出去。
- 密码输入框里的内容永远不读。
- 读不到选区时会模拟一次 ⌘C，读完立刻把剪贴板恢复原样。这个行为可以在设置里关掉。
- “替换原文”是借剪贴板粘贴：放入润色结果，按 ⌘V，1 秒后把原来的剪贴板内容（包括图片、富文本等所有格式）放回去。只有原文所在的 App 还在前台时才会粘贴；不在前台时只把结果复制到剪贴板并提示你。
- `claude` 以 `--safe-mode --tools "" --no-session-persistence` 运行：不加载你的 hooks、插件、MCP 和 CLAUDE.md，不开任何工具，也不保存会话记录。

## 常见问题

**提示没有找到 claude。** App 按顺序找 `~/.local/bin/claude`、`~/.claude/local/claude`、`/opt/homebrew/bin/claude`、`/usr/local/bin/claude`，并用 `claude --version` 确认能运行。也可以在设置里填写完整路径。

**`/opt/homebrew/bin/claude` 报 `TypeError: Cannot read properties of undefined (reading 'prototype')`。** 那是旧的 npm 版 Claude Code，在 Node 25 下起不来。ClaudeDict 会跳过它，改用 `~/.local/bin/claude`。

**授权了辅助功能还是不出工具条。** 多半是重新编译过：在 系统设置 › 隐私与安全性 › 辅助功能 里删掉 ClaudeDict 再重新添加，或者执行 `tccutil reset Accessibility local.claudedict.app` 后重新授权。

**朗读的声音很机械。** 系统设置 › 辅助功能 › 朗读内容 › 系统声音 › 管理声音，下载 Premium 或 Enhanced 的英文语音，然后在 ClaudeDict 设置里选它。

## 卸载

菜单栏图标 › 退出，然后：

```bash
rm -rf ~/Applications/ClaudeDict.app ~/Library/Application\ Support/ClaudeDict
defaults delete local.claudedict.app
tccutil reset Accessibility local.claudedict.app
```

## 开发

```bash
scripts/test.sh                                   # 核心逻辑自测（51 项，用假的 claude 脚本，不联网）
scripts/build.sh                                  # 只编译到 build/ClaudeDict.app
build/ClaudeDict.app/Contents/MacOS/ClaudeDict --selftest-ax   # 辅助功能读选区自测（需要终端有辅助功能权限）
build/ClaudeDict.app/Contents/MacOS/ClaudeDict --snapshot translate out.png --warm-wait 8 "serendipity"
```

这台机器只有 Command Line Tools，SwiftPM 无法编译 Package.swift，所以直接用 `swiftc` 编译，不依赖 Xcode 和第三方库。设计说明见 `docs/design.md`。

# ClaudeDict

A macOS menu-bar tool for text you select. Select English in any app and a small toolbar appears next to it: **Translate · Polish · Analyze · Read aloud · Copy**. The interaction follows Doubao's select-to-translate toolbar and GoldenDict's lookup popup, and the answers come from your local `claude -p`.

The interface and the answers are in Chinese. ClaudeDict is made for Chinese speakers who read and write English.

- **Translate (翻译)**: a word gets a dictionary entry (UK and US phonetics, parts of speech, example sentences); a sentence or paragraph gets a natural Chinese translation. Selected Chinese is translated into English.
- **Polish (润色)**: rewrites your English the way a native speaker would and explains each change. One click on **替换原文** (Replace) puts the result in place of your selection.
- **Analyze (解析)**: for a word, its origin, collocations, examples and how it differs from similar words; for a sentence, its structure, grammar and key vocabulary; for a paragraph, the main idea and the hard sentences.
- **Read aloud (朗读)**: uses the macOS system voices, works offline, with a choice of voice and speed.

## Install

You need macOS 14 or later, the Xcode Command Line Tools, and Claude Code signed in (`claude` works in Terminal).

```bash
git clone https://github.com/lqglqy/claude-dict.git
cd claude-dict
scripts/build.sh --install
```

This builds the app, installs it to `~/Applications/ClaudeDict.app` and starts it. A book icon appears in the menu bar.

On first use, grant the Accessibility permission, which ClaudeDict needs to read the selected text: menu-bar icon › “⚠️ 划词需要辅助功能权限…”, or turn on ClaudeDict in System Settings › Privacy & Security › Accessibility.

> The app is ad-hoc signed on your Mac. After each rebuild and reinstall, macOS treats it as a new app, so you need to turn Accessibility on for it again. `build.sh --install` clears the old permission entry first.

## Usage

| Action | How |
| --- | --- |
| Select text | Select text (drag, double-click or Shift-click) and the toolbar appears |
| Translate the selection | ⌃⌥D |
| Polish the selection | ⌃⌥E |
| Analyze the selection | ⌃⌥A |
| Read the selection aloud | ⌃⌥S |
| Open the input box | ⌃⌥I (⌃⌥D also opens it when nothing is selected) |
| Press ⌘C twice | GoldenDict's lookup method on macOS. Off by default; turn it on in Settings. Needs no Accessibility permission |
| Replace the original | When polishing finishes, a **替换原文** (Replace) button appears next to the original text (⌘↩ also works while the window is in front). It replaces the text you selected with the polished version |
| Result window | Esc closes it. Once pinned, it stays open when you click elsewhere, and new lookups show in it |

The shortcuts use ⌃⌥ so they don't clash with the ⌥D, ⌥A and ⌥S defaults of Bob and Easydict.

You can also start a lookup from a URL, which is handy for Alfred, Raycast or scripts:

```bash
open "claudedict://translate?text=serendipity"   # also polish, analyze, speak, input, settings
```

## Speed

Each model in use keeps one warm `claude -p` process waiting. A lookup uses it, and a replacement starts right away. Measured on the author's Mac (2026-11-10, `claude` 2.1.322, `scripts/bench-warm.sh`: the app's snapshot mode, querying 8 seconds after warm-up):

| Case | First token | Total |
| --- | --- | --- |
| haiku, look up the word "ubiquitous" (3 runs) | 0.5–0.6 s | 1.1–1.2 s |
| haiku, translate one sentence (2 runs) | 0.5–0.6 s | 0.7–0.8 s |
| sonnet, polish one sentence (2 runs) | 0.5–0.8 s | 1.6–2.3 s |
| For comparison: cold start without warm-up, haiku word lookup (snapshot without `--warm-wait`, 1 run) | 4.4 s | 5.2 s |

Default models: haiku for Translate, sonnet for Polish and Analyze. You can change them in Settings (haiku, sonnet, opus, fable). Repeated lookups come from an in-memory cache and show up instantly.

## Use with GoldenDict

The ClaudeDict executable has a command-line mode, so GoldenDict or GoldenDict-ng can use it as a "program" dictionary source:

GoldenDict › Edit › Dictionaries › Sources › Programs › Add:

- Type: `Html`
- Name: any, for example `Claude`
- Command line: `/Users/<your user name>/Applications/ClaudeDict.app/Contents/MacOS/ClaudeDict --cli translate --html %GDWORD%`

For detailed word notes in GoldenDict, add a second entry with `translate` changed to `analyze`. GoldenDict starts a new process for every lookup, so it can't use the warm processes: a word translation took about 5.9 seconds on the author's Mac (cold start, 2026-11-10).

The command line also works on its own:

```bash
ClaudeDict --cli translate serendipity
ClaudeDict --cli polish "I want discuss with you about the plan."
echo "Had I known, I would have come." | ClaudeDict --cli analyze
```

## Privacy

- Selected text is sent to Claude only when you click a toolbar button or press a shortcut. Just selecting text reads it on your Mac and sends nothing.
- Password fields are never read.
- When the selection can't be read directly, ClaudeDict simulates one ⌘C and puts the clipboard back as it was right after reading. You can turn this off in Settings.
- **替换原文** (Replace) pastes through the clipboard: it puts the polished text there, presses ⌘V, and after 1 second restores what the clipboard held before, in every format (images, rich text and so on). It pastes only while the app the text came from is still in front. Otherwise it only copies the result to the clipboard and tells you.
- `claude` runs with `--safe-mode --tools "" --no-session-persistence`: it loads none of your hooks, plugins, MCP servers or CLAUDE.md, has no tools, and keeps no session history.
- Lookups go through your own `claude` login, so they count toward that Claude account's usage.

## FAQ

**It says claude was not found.** ClaudeDict looks for `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.npm-global/bin/claude` and `~/.bun/bin/claude` in that order, then runs `command -v claude` in a login shell, and checks each candidate with `claude --version`. You can also enter the full path in Settings.

**`/opt/homebrew/bin/claude` fails with `TypeError: Cannot read properties of undefined (reading 'prototype')`.** That is the old npm build of Claude Code, which doesn't start under Node 25. ClaudeDict skips it and uses `~/.local/bin/claude`.

**Accessibility is on, but no toolbar appears.** Most likely the app was rebuilt. Remove ClaudeDict in System Settings › Privacy & Security › Accessibility and add it again, or run `tccutil reset Accessibility local.claudedict.app` and grant the permission again.

**The voice sounds robotic.** Go to System Settings › Accessibility › Spoken Content › System Voice › Manage Voices, download a Premium or Enhanced English voice, then choose it in ClaudeDict's Settings.

## Uninstall

Menu-bar icon › 退出 ClaudeDict (Quit), then:

```bash
rm -rf ~/Applications/ClaudeDict.app ~/Library/Application\ Support/ClaudeDict
defaults delete local.claudedict.app
tccutil reset Accessibility local.claudedict.app
```

## Development

```bash
scripts/test.sh                                   # core logic self-tests (51, using a fake claude script, offline)
scripts/build.sh                                  # build only, to build/ClaudeDict.app
build/ClaudeDict.app/Contents/MacOS/ClaudeDict --selftest-ax   # Accessibility self-test for reading selections (Terminal needs Accessibility)
build/ClaudeDict.app/Contents/MacOS/ClaudeDict --snapshot translate out.png --warm-wait 8 "serendipity"   # one real lookup, result window saved as a PNG
```

The build calls `swiftc` directly, so it needs neither Xcode nor any third-party library. There is no Package.swift because SwiftPM could not build one on the author's Mac, which has only the Command Line Tools. Design notes are in [docs/design.md](docs/design.md).

## License

[MIT](LICENSE).

ClaudeDict is an independent project. It is not affiliated with or endorsed by Anthropic, GoldenDict or Doubao.

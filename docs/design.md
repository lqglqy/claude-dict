# ClaudeDict design notes

2026-11-10

## Goal

A Doubao-style select-and-ask AI tool for macOS: select text and a toolbar appears next to it, offering translate, polish, analyze and read aloud. It is mainly for Chinese speakers reading and writing English. The LLM backend is `claude -p`.

## Why native Swift, not a GoldenDict fork

The original request said "based on GoldenDict". Before writing code, I checked the development Mac:

- GoldenDict was not installed, and its source was not there either.
- Qt was not installed. GoldenDict-ng is a large C++/Qt6 project (including WebEngine); building it here would first need Qt and about ten other dependencies.
- Only the Xcode Command Line Tools were installed, not full Xcode. SwiftPM failed to link Package.swift (missing PackageDescription symbols), while `swiftc` itself works.
- On macOS, GoldenDict's popup is triggered through the clipboard; it has no "toolbar on selection". The Doubao-style interaction had to be written from scratch either way.

So ClaudeDict is a native app that keeps GoldenDict's habits and can plug back into GoldenDict:

- The result window works like GoldenDict's lookup popup: it opens next to the selection, closes when you click elsewhere, and can be pinned.
- Word results use a dictionary layout: UK and US phonetics, definitions by part of speech, example sentences.
- It supports GoldenDict's "press ⌘C twice" lookup on macOS.
- The executable has a `--cli` mode, so GoldenDict can use it as a "program" dictionary (Html type).

If AI is ever added to the GoldenDict-ng source itself, the prompts, stream parsing and warm process pool in `Sources/Core` can serve as a reference for the port.

## Structure

```
Sources/Core   UI-independent and testable
  TextAnalyzer   cleans selected text (PDF line breaks, hyphenation, punctuation around a single word); detects language and kind (word/phrase/sentence/paragraph)
  Prompts        one generic system prompt plus task instructions per action × language × kind
  StreamParser   parses claude -p stream-json output; LineBuffer handles UTF-8 split across chunks
  Markdown       the Markdown subset the prompts ask for, parsed line by line (so streaming output can render at any point); can also convert to HTML
  ClaudeCommand  launch arguments, environment variables, finding claude (each candidate verified with --version)
  ClaudeSession  one claude -p process: start it and let it wait, then write one message; SparePool is the warm pool; LookupEngine adds the cache
  Settings       settings (missing fields fall back to defaults) and the LRU cache
Sources/App    AppKit + SwiftUI
  SelectionReader  reads the selection through Accessibility; if that fails, simulates ⌘C and restores the clipboard; ClipboardWatcher (⌘C⌘C); SelectionMonitor (global mouse)
  Toolbar          the toolbar next to the selection
  ResultWindow     the result window and its view model
  Speech           read-aloud with AVSpeechSynthesizer
  HotKeys          global shortcuts with Carbon RegisterEventHotKey
  AppDelegate      menu bar, settings wiring, URL scheme, snapshot self-check mode
  CLI              --cli command-line mode
  SelfTest         --selftest-ax Accessibility self-test
```

## How claude is called

Arguments for each process:

```
claude -p --model <m> --system-prompt <generic prompt> --tools "" --no-session-persistence --safe-mode
       --input-format stream-json --output-format stream-json --include-partial-messages --verbose
```

- `--safe-mode` skips the user's hooks, plugins, MCP servers and CLAUDE.md but keeps the OAuth login. Measured on the development Mac, haiku's cold-start first token dropped from 12.25 s to 3.86 s (`scripts/probes/probe_latency.py haiku`, one run without and one with `--safe-mode`, 2026-11-10). `--bare` is not used because it accepts only an API key and ignores the OAuth login.
- Warm-up: the process starts and waits on stdin. A lookup writes one stream-json message and closes stdin; the process answers once and exits. Measured on the development Mac, the first token after warm-up took 0.53 s for haiku and 0.92 s for sonnet, against 3.86 s and 4.15 s cold (`scripts/probes/probe_prewarm.py` and `probe_latency.py`, one run each). A warm process that sat idle for 60 seconds still worked (first token 0.63 s) and used about 42 MB, against about 206 MB 5 seconds after start (`scripts/probes/probe_idle.py`, summed RSS of the process tree). `scripts/bench-warm.sh` measures warm latency through the app's full code path; the results are in the README.
- Warm pool: one process per model in use. A replacement starts 0.5 seconds after one is taken. Every 5 minutes, processes older than 20 minutes or already exited are replaced. All are rebuilt after the Mac wakes. On quit, the app waits up to 1 second, then SIGKILLs any that are still running.
- Errors: an error such as an unknown model arrives in stream-json as a `result` event whose `subtype` is still `success` but with `is_error: true`, and the process exits with code 1, so the app checks `is_error`. If the process crashes without a result, the app reports the exit code and the end of stderr.
- The selected text goes inside `<text>…</text>`, and the system prompt says it is data, not instructions. Any `<text>` or `</text>` inside the selection is rewritten so it cannot close the block early.

## Reading the selection

1. Read only after a drag selection, a double or triple click, or a Shift-click, and only when ClaudeDict itself is not the frontmost app.
2. First read `AXSelectedText` from the focused element through Accessibility. Password fields (`AXSecureTextField`) are skipped. If the drag started outside the focused element's frame (for example, dragging a window), no toolbar appears.
3. If the Accessibility read fails, the focus is not a non-text control such as a list, table or button, and the frontmost app is not Finder, simulate ⌘C and restore the clipboard after reading.
4. For Electron and Chromium apps, set `AXManualAccessibility` first so they expose their accessibility tree.

## Replacing the original text

When a polish result is complete and the original text came from a selection in another app (through the toolbar, a shortcut or ⌘C⌘C), a "替换原文" (Replace) button appears in the original-text row. `Prompts.replacementText` decides whether it shows. It no longer looks at the Accessibility "editable" flag, because input boxes on web pages (such as the input boxes of chat websites) often don't report it, so the button never appeared there.

Replacing works by pasting. The result window doesn't activate ClaudeDict, so the original app stays in front and its selection stays in place. When the button is clicked, the window closes first, then waits 0.25 seconds for keyboard focus to return to the original app, checks that the original app is still frontmost, puts the polished text on the clipboard and sends ⌘V. 1 second later it restores the user's original clipboard (browsers paste asynchronously, so restoring too early would paste the old content). If the original app is no longer in front, it doesn't paste; it copies the result and shows a note at the bottom of the window.

## Verification

- `scripts/test.sh`: 51 core self-tests, using `Tests/fixtures/fake-claude.sh` to simulate the stream-json protocol, with no network. To confirm the tests can catch real problems, the code was broken on purpose 7 times (dropping --safe-mode, treating an error as success, decoding UTF-8 per chunk, skipping the cache, not SIGKILLing at shutdown, losing the reason when a warm process fails at start, showing the Replace button regardless of where the text came from). Each time the matching test failed, and all passed again after the code was restored.
- `--selftest-ax`: puts an NSTextView and a password field in an off-screen window in its own process, reads the selection, editability and element frame through the real Accessibility API, and confirms the password field is not read. It then checks on a private pasteboard that after "替换原文" borrows the clipboard, every format comes back. Removing the password-field check, or restoring only plain text, makes the matching check fail.
- `--snapshot`: runs one lookup with the real claude and draws the result window into a PNG to check the layout. It is also used to measure warm latency (numbers in the README).
- Startup check in normal mode: it finds `~/.local/bin/claude`, keeps one warm process each for haiku and sonnet, and registers all 5 shortcuts. On SIGTERM it exits cleanly with no leftover claude processes.

## Known limitations and possible next steps

- Ad-hoc signing: Accessibility must be granted again after every rebuild. A self-signed certificate could keep the signature stable if needed.
- No real-click testing: the toolbar buttons, dragging and resizing the result window, Replace and similar interactions have no automated tests. They follow standard AppKit practice and need a person to try them.
- GoldenDict's "program" dictionary cold-starts every time (about 5.9 seconds on the development Mac, see the README). The CLI could reuse the running app's warm processes through a local socket.
- There is no lookup history or word list yet (GoldenDict has history and favorites). These could go in the menu bar.

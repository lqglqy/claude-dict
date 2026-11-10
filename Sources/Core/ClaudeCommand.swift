import Foundation

/// How we run `claude`.
enum ClaudeCommand {
    /// Arguments for a pre-warmed process that waits on stdin for exactly one message.
    ///
    /// --safe-mode skips the user's hooks, plugins, MCP servers and CLAUDE.md while keeping OAuth
    /// login; measured on this machine it cut haiku's first token from 12.25s to 3.86s (cold).
    /// --bare is not used because it ignores OAuth logins.
    static func spareArguments(model: String) -> [String] {
        ["-p",
         "--model", model,
         "--system-prompt", Prompts.system,
         "--tools", "",
         "--no-session-persistence",
         "--safe-mode",
         "--input-format", "stream-json",
         "--output-format", "stream-json",
         "--include-partial-messages",
         "--verbose"]
    }

    /// One stream-json user message, newline-terminated.
    static func messageLine(_ text: String) -> String {
        let object: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// GUI apps get launchd's minimal environment; also drop markers that make `claude` think it
    /// is nested inside another Claude Code session.
    static func childEnvironment(from environment: [String: String], home: String) -> [String: String] {
        var env = environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] {
            env.removeValue(forKey: key)
        }
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        if env["HOME"] == nil { env["HOME"] = home }
        return env
    }
}

/// Finds a `claude` binary that actually runs. On the development machine the Homebrew/npm copy
/// earlier in PATH crashes under Node 25, so every candidate is verified with `--version`.
enum ClaudeLocator {
    static func candidates(home: String, override: String?) -> [String] {
        var list: [String] = []
        if let o = override?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            list.append((o as NSString).expandingTildeInPath)
        }
        list += [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    static func locate(override: String?, home: String, shellLookup: () -> String?,
                       validator: (String) -> Bool) -> String? {
        let list = candidates(home: home, override: override)
        for path in list where validator(path) { return path }
        if let found = shellLookup(), !list.contains(found), validator(found) { return found }
        return nil
    }

    static func locateDefault(override: String?) -> String? {
        locate(override: override, home: NSHomeDirectory(), shellLookup: loginShellLookup,
               validator: { isWorkingClaude($0, timeout: 8) })
    }

    static func isWorkingClaude(_ path: String, timeout: TimeInterval) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        guard let (status, output) = run(path, ["--version"], timeout: timeout) else { return false }
        return status == 0 && output.contains("Claude Code")
    }

    /// `command -v claude` in a login shell, for installs outside the usual places.
    static func loginShellLookup() -> String? {
        guard let (status, output) = run("/bin/zsh", ["-lc", "command -v claude"], timeout: 5), status == 0 else {
            return nil
        }
        let path = output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return (path?.hasPrefix("/") ?? false) ? path : nil
    }

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (Int32, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ClaudeCommand.childEnvironment(from: ProcessInfo.processInfo.environment,
                                                             home: NSHomeDirectory())
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

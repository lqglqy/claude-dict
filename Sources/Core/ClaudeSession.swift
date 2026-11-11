import Foundation

struct LookupStats: Equatable {
    var model: String?
    var firstTokenMs: Int?
    var totalMs: Int
    var costUSD: Double?
    var cached: Bool
}

enum SessionUpdate {
    /// Everything received so far (not just the newest chunk).
    case partial(String)
    case finished(String, LookupStats)
    case failed(String)

    var isTerminal: Bool {
        if case .partial = self { return false }
        return true
    }
}

enum EngineError: Error, Equatable {
    case claudeNotFound
    case spawnFailed(String)

    var message: String {
        switch self {
        case .claudeNotFound:
            return "没有找到可用的 claude 命令行。请先安装 Claude Code 并登录，或在设置里填写 claude 的完整路径。"
        case .spawnFailed(let detail):
            return "无法启动 claude：\(detail)"
        }
    }
}

/// One `claude -p` process. It is started ahead of time (a "spare"), then `send` writes a single
/// stream-json message and closes stdin, so the process answers once and exits.
final class ClaudeSession {
    let model: String
    let createdAt = Date()

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()

    // Guarded by `lock`.
    private var lineBuffer = LineBuffer()
    private var stderrData = Data()
    private var handler: ((SessionUpdate) -> Void)?
    private var queue: DispatchQueue?
    private var text = ""
    private var assistantText = ""
    private var assistantError: String?
    private var resolvedModel: String?
    private var sentAt: Date?
    private var firstTokenAt: Date?
    private var delivered = false
    private var cancelled = false
    private var stdinClosed = false
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exited = false
    private var exitStatus: Int32 = 0

    init(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL, model: String) {
        self.model = model
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    var processIdentifier: Int32 { process.processIdentifier }

    /// The OS process is still there (also true for a cancelled session that is shutting down).
    var isRunning: Bool { process.isRunning }

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !exited && !cancelled && process.isRunning
    }

    /// Callers must ignore SIGPIPE (signal(SIGPIPE, SIG_IGN)): writing to a process that already
    /// died would otherwise kill the app.
    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutDidClose()
            } else {
                consume(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            lock.lock()
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrClosed = true
            } else {
                stderrData.append(data)
                if stderrData.count > 64_000 { stderrData = Data(stderrData.suffix(16_000)) }
            }
            lock.unlock()
            if data.isEmpty { finalizeAfterExit() }
        }
        process.terminationHandler = { [self] p in
            lock.lock()
            exited = true
            exitStatus = p.terminationStatus
            lock.unlock()
            p.terminationHandler = nil
            finalizeAfterExit()
        }
        try process.run()
    }

    func send(_ prompt: String, queue: DispatchQueue, handler: @escaping (SessionUpdate) -> Void) {
        lock.lock()
        self.queue = queue
        self.handler = handler
        sentAt = Date()
        let alreadyDead = exited
        let canWrite = !stdinClosed && !alreadyDead
        stdinClosed = true
        lock.unlock()

        if canWrite {
            let writer = stdinPipe.fileHandleForWriting
            do {
                try writer.write(contentsOf: Data(ClaudeCommand.messageLine(prompt).utf8))
            } catch {
                // The process died; its exit is reported with stderr by finalizeAfterExit.
            }
            try? writer.close()
        }
        if alreadyDead { finalizeAfterExit() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        handler = nil
        let closeStdin = !stdinClosed
        stdinClosed = true
        lock.unlock()
        if closeStdin { try? stdinPipe.fileHandleForWriting.close() }
        if process.isRunning {
            process.terminate()
            let p = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    // MARK: Output handling

    private func consume(_ data: Data) {
        lock.lock()
        let lines = lineBuffer.append(data)
        lock.unlock()
        for line in lines { handle(StreamParser.parse(line: line)) }
    }

    private func stdoutDidClose() {
        lock.lock()
        let tail = lineBuffer.flush()
        lock.unlock()
        if let tail { handle(StreamParser.parse(line: tail)) }
        lock.lock()
        stdoutClosed = true
        lock.unlock()
        finalizeAfterExit()
    }

    private func handle(_ event: StreamEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered, !cancelled else { return }
        switch event {
        case .initialized(let model):
            resolvedModel = model
        case .textDelta(let chunk):
            if firstTokenAt == nil { firstTokenAt = Date() }
            text += chunk
            emit(.partial(text))
        case .assistantText(let message, let error):
            if let error {
                assistantError = message.isEmpty ? error : message
            } else {
                if firstTokenAt == nil { firstTokenAt = Date() }
                assistantText += message
            }
        case .result(let info):
            if info.isError {
                finish(.failed(info.text.isEmpty ? (assistantError ?? "claude 返回了错误。") : info.text))
            } else {
                let final = !text.isEmpty ? text : (!info.text.isEmpty ? info.text : assistantText)
                finish(.finished(final, stats(cost: info.costUSD)))
            }
        case .ignored:
            break
        }
    }

    /// Runs once the process has exited and both output pipes are drained, for runs that ended
    /// without a result event.
    private func finalizeAfterExit() {
        lock.lock()
        defer { lock.unlock() }
        guard exited, stdoutClosed, stderrClosed, !delivered, !cancelled, handler != nil else { return }
        if let assistantError {
            finish(.failed(assistantError))
            return
        }
        let final = !text.isEmpty ? text : assistantText
        if exitStatus == 0, !final.isEmpty {
            finish(.finished(final, stats(cost: nil)))
            return
        }
        var message = "claude 进程意外退出（退出码 \(exitStatus)）。"
        let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderrText.isEmpty { message += "\n" + String(stderrText.suffix(800)) }
        finish(.failed(message))
    }

    // Both helpers expect `lock` to be held.

    private func emit(_ update: SessionUpdate) {
        guard let handler, let queue else { return }
        queue.async { handler(update) }
    }

    private func finish(_ update: SessionUpdate) {
        guard !delivered, handler != nil else { return }
        delivered = true
        emit(update)
        handler = nil
    }

    private func stats(cost: Double?) -> LookupStats {
        let sent = sentAt ?? createdAt
        return LookupStats(model: resolvedModel ?? model,
                           firstTokenMs: firstTokenAt.map { Int($0.timeIntervalSince(sent) * 1000) },
                           totalMs: Int(Date().timeIntervalSince(sent) * 1000),
                           costUSD: cost,
                           cached: false)
    }
}

/// Keeps one idle `claude` process per model so a lookup skips the ~3.3s CLI start-up.
/// Measured: haiku first token 0.53s from a warm spare vs 3.86s cold.
final class SparePool {
    let maxAge: TimeInterval
    private let executable: () -> String?
    private let environment: [String: String]
    private let workingDirectory: URL
    private let replacementDelay: TimeInterval
    private let lock = NSLock()
    private let spawnQueue = DispatchQueue(label: "claudedict.spare-pool")
    private var spares: [String: ClaudeSession] = [:]
    private var wanted: [String] = []
    private var isShutdown = false

    init(executable: @escaping () -> String?, environment: [String: String], workingDirectory: URL,
         maxAge: TimeInterval = 20 * 60, replacementDelay: TimeInterval = 0.5) {
        self.executable = executable
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.maxAge = maxAge
        self.replacementDelay = replacementDelay
    }

    /// Keep exactly these models warm.
    func prewarm(models: [String]) {
        lock.lock()
        isShutdown = false
        wanted = models
        let unwanted = spares.filter { !models.contains($0.key) }
        for key in unwanted.keys { spares[key] = nil }
        lock.unlock()
        unwanted.values.forEach { $0.cancel() }
        for model in models { ensureSpare(model: model) }
    }

    /// Hands out the warm process for `model` (or starts a cold one) and schedules a replacement.
    func acquire(model: String) throws -> ClaudeSession {
        lock.lock()
        let spare = spares.removeValue(forKey: model)
        let keepWarm = wanted.contains(model) && !isShutdown
        lock.unlock()
        if keepWarm {
            spawnQueue.asyncAfter(deadline: .now() + replacementDelay) { [weak self] in self?.ensureSpare(model: model) }
        }
        if let spare {
            if spare.isAlive { return spare }
            spare.cancel()
        }
        return try spawn(model: model)
    }

    /// Replaces spares that are older than `maxAge` or have died (e.g. after the Mac slept).
    func refreshStale() {
        lock.lock()
        let now = Date()
        let stale = spares.filter { !$0.value.isAlive || now.timeIntervalSince($0.value.createdAt) > maxAge }
        for key in stale.keys { spares[key] = nil }
        let models = wanted
        lock.unlock()
        stale.values.forEach { $0.cancel() }
        for model in models { ensureSpare(model: model) }
    }

    /// Drops every spare and starts fresh ones (after a settings or binary change).
    func recycleAll() {
        lock.lock()
        let old = Array(spares.values)
        spares.removeAll()
        let models = wanted
        lock.unlock()
        old.forEach { $0.cancel() }
        for model in models { ensureSpare(model: model) }
    }

    /// Stops all spares. With `wait`, blocks until they exit and SIGKILLs any still running, so
    /// none outlive the app (cancel's own delayed SIGKILL never fires once the app has quit).
    func shutdown(wait: TimeInterval = 0) {
        lock.lock()
        isShutdown = true
        let old = Array(spares.values)
        spares.removeAll()
        lock.unlock()
        old.forEach { $0.cancel() }
        guard wait > 0 else { return }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline, old.contains(where: { $0.isRunning }) { Thread.sleep(forTimeInterval: 0.02) }
        for session in old where session.isRunning { kill(session.processIdentifier, SIGKILL) }
    }

    func spareCount(model: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return (spares[model]?.isAlive ?? false) ? 1 : 0
    }

    func spare(model: String) -> ClaudeSession? {
        lock.lock()
        defer { lock.unlock() }
        return spares[model]
    }

    private func ensureSpare(model: String) {
        lock.lock()
        if isShutdown || (spares[model]?.isAlive ?? false) {
            lock.unlock()
            return
        }
        let dead = spares.removeValue(forKey: model)
        lock.unlock()
        dead?.cancel()
        guard let session = try? spawn(model: model) else { return }
        lock.lock()
        if isShutdown || (spares[model]?.isAlive ?? false) {
            lock.unlock()
            session.cancel()
            return
        }
        spares[model] = session
        lock.unlock()
    }

    private func spawn(model: String) throws -> ClaudeSession {
        guard let path = executable() else { throw EngineError.claudeNotFound }
        let session = ClaudeSession(executable: path, arguments: ClaudeCommand.spareArguments(model: model),
                                    environment: environment, workingDirectory: workingDirectory, model: model)
        do {
            try session.start()
        } catch {
            throw EngineError.spawnFailed(error.localizedDescription)
        }
        return session
    }
}

final class LookupHandle {
    fileprivate(set) var session: ClaudeSession?

    func cancel() { session?.cancel() }
}

/// Lookups with a result cache in front of the spare pool.
final class LookupEngine {
    let pool: SparePool
    private var cache = LRUCache<String, String>(capacity: 300)
    private let lock = NSLock()

    init(pool: SparePool) { self.pool = pool }

    @discardableResult
    func run(action: Action, input: TextInput, model: String, useCache: Bool = true,
             queue: DispatchQueue, handler: @escaping (SessionUpdate) -> Void) -> LookupHandle {
        let handle = LookupHandle()
        let key = "\(action.rawValue)\u{1F}\(model)\u{1F}\(input.text)"
        if useCache {
            lock.lock()
            let hit = cache[key]
            lock.unlock()
            if let hit {
                queue.async {
                    handler(.finished(hit, LookupStats(model: model, firstTokenMs: 0, totalMs: 0, costUSD: nil, cached: true)))
                }
                return handle
            }
        }
        let session: ClaudeSession
        do {
            session = try pool.acquire(model: model)
        } catch let error as EngineError {
            queue.async { handler(.failed(error.message)) }
            return handle
        } catch {
            queue.async { handler(.failed(error.localizedDescription)) }
            return handle
        }
        handle.session = session
        session.send(Prompts.userMessage(action: action, input: input), queue: queue) { [weak self] update in
            if case .finished(let text, _) = update, !text.isEmpty, let self {
                self.lock.lock()
                self.cache[key] = text
                self.lock.unlock()
            }
            handler(update)
        }
        return handle
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

import Foundation

/// Command-line mode, e.g. as a GoldenDict "Program" dictionary source:
///   ClaudeDict --cli translate --html %GDWORD%
enum CLI {
    static let usage = """
    用法: ClaudeDict --cli [translate|polish|analyze] [--model 模型] [--html] [文本…]
      不给文本时从标准输入读取。--html 输出 HTML 片段（GoldenDict 的 Html 类型程序词典）。
    """

    static func run(_ arguments: [String]) -> Int32 {
        var action = Action.translate
        var model: String?
        var html = false
        var words: [String] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--cli":
                continue
            case "--model", "-m":
                model = iterator.next()
            case "--html":
                html = true
            case "-h", "--help":
                print(usage)
                return 0
            default:
                if words.isEmpty, let chosen = Action(rawValue: argument) { action = chosen } else { words.append(argument) }
            }
        }
        var text = words.joined(separator: " ")
        if text.isEmpty {
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        let input = TextAnalyzer.analyze(text)
        guard !input.text.isEmpty else {
            printError("没有要处理的文本。\n" + usage)
            return 2
        }

        let settings = AppModel.loadSettings()
        guard let claude = claudePath(override: settings.claudePath) else {
            printError(EngineError.claudeNotFound.message)
            return 3
        }
        let workDir = AppModel.supportDirectory.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let pool = SparePool(executable: { claude },
                             environment: ClaudeCommand.childEnvironment(from: ProcessInfo.processInfo.environment,
                                                                         home: NSHomeDirectory()),
                             workingDirectory: workDir)
        let engine = LookupEngine(pool: pool)
        let queue = DispatchQueue(label: "claudedict.cli")
        let done = DispatchSemaphore(value: 0)
        var printed = 0
        var status: Int32 = 0

        engine.run(action: action, input: input, model: model ?? settings.model(for: action), queue: queue) { update in
            switch update {
            case .partial(let soFar):
                guard !html, soFar.count > printed else { return }
                write(String(soFar.dropFirst(printed)))
                printed = soFar.count
            case .finished(let final, _):
                if html {
                    write("<div class=\"claudedict\" style=\"line-height:1.55\">\(Markdown.html(final))</div>\n")
                } else {
                    write((final.count > printed ? String(final.dropFirst(printed)) : "") + "\n")
                }
                done.signal()
            case .failed(let message):
                printError(message)
                status = 1
                done.signal()
            }
        }
        done.wait()
        pool.shutdown()
        return status
    }

    /// The path the app last verified, else a full search.
    private static func claudePath(override: String?) -> String? {
        if let override, !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let cached = UserDefaults.standard.string(forKey: AppModel.cachedClaudePathKey),
           FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        return ClaudeLocator.locateDefault(override: override)
    }

    private static func write(_ string: String) {
        FileHandle.standardOutput.write(Data(string.utf8))
    }

    private static func printError(_ string: String) {
        FileHandle.standardError.write(Data((string + "\n").utf8))
    }
}

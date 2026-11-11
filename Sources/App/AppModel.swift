import AppKit
import ApplicationServices
import SwiftUI

enum ClaudeStatus: Equatable {
    case checking
    case found(String)
    case missing
}

/// Where a selection came from, so "替换" can paste back into the same app.
struct SelectionContext {
    var pid: pid_t?
    var bundleID: String?
    var isEditable: Bool
}

/// The located claude path, read by the spare pool off the main thread.
final class PathBox {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

extension Action {
    var symbol: String {
        switch self {
        case .translate: return "character.book.closed"
        case .polish: return "wand.and.stars"
        case .analyze: return "text.magnifyingglass"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    @Published private(set) var claudeStatus: ClaudeStatus = .checking
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()

    let speech = SpeechController()
    let pool: SparePool
    let engine: LookupEngine
    /// Called after settings that affect monitors or hotkeys change.
    var onSettingsChanged: (() -> Void)?

    private let pathBox = PathBox()
    private var pendingUntilReady: [() -> Void] = []
    nonisolated private static let settingsKey = "settings.v1"
    nonisolated static let cachedClaudePathKey = "claudePath.lastFound"

    init() {
        settings = Self.loadSettings()
        let workDir = Self.supportDirectory.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let box = pathBox
        pool = SparePool(executable: { box.value },
                         environment: ClaudeCommand.childEnvironment(from: ProcessInfo.processInfo.environment,
                                                                     home: NSHomeDirectory()),
                         workingDirectory: workDir)
        engine = LookupEngine(pool: pool)
        speech.rate = settings.speechRate
        speech.voiceIdentifier = settings.voiceIdentifier
    }

    nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClaudeDict", isDirectory: true)
    }

    nonisolated static func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    private func settingsDidChange(from old: AppSettings) {
        guard settings != old else { return }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        speech.rate = settings.speechRate
        speech.voiceIdentifier = settings.voiceIdentifier
        if settings.claudePath != old.claudePath {
            locateClaude()
        } else if settings.modelsInUse != old.modelsInUse, case .found = claudeStatus {
            pool.prewarm(models: settings.modelsInUse)
        }
        onSettingsChanged?()
    }

    // MARK: claude binary

    var claudePath: String? {
        if case .found(let path) = claudeStatus { return path }
        return nil
    }

    func locateClaude(models: [String]? = nil) {
        claudeStatus = .checking
        let override = settings.claudePath
        let wanted = models ?? settings.modelsInUse
        DispatchQueue.global(qos: .userInitiated).async {
            let path = ClaudeLocator.locateDefault(override: override)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.claudeLocated(path, models: wanted) }
            }
        }
    }

    private func claudeLocated(_ path: String?, models: [String]) {
        let changed = pathBox.value != path
        pathBox.value = path
        claudeStatus = path.map { .found($0) } ?? .missing
        if let path {
            UserDefaults.standard.set(path, forKey: Self.cachedClaudePathKey)
            if changed { pool.recycleAll() }
            pool.prewarm(models: models)
        } else {
            pool.shutdown()
        }
        let waiting = pendingUntilReady
        pendingUntilReady.removeAll()
        waiting.forEach { $0() }
    }

    /// Runs `block` now, or once the claude lookup has finished.
    func whenClaudeReady(_ block: @escaping () -> Void) {
        if case .checking = claudeStatus {
            pendingUntilReady.append(block)
        } else {
            block()
        }
    }

    // MARK: Accessibility

    func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

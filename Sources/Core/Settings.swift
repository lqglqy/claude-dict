import Foundation

struct AppSettings: Codable, Equatable {
    var translateModel = "haiku"
    var polishModel = "sonnet"
    var analyzeModel = "sonnet"
    /// Doubao-style toolbar after selecting text (needs Accessibility permission).
    var toolbarEnabled = true
    /// GoldenDict-style trigger: copy the same text twice quickly (Cmd+C, Cmd+C). Off by default
    /// because many people press Cmd+C twice out of habit.
    var doubleCopyEnabled = false
    /// When an app does not expose the selection through Accessibility, send Cmd+C and restore
    /// the clipboard afterwards.
    var copyFallbackEnabled = true
    var hotkeysEnabled = true
    /// AVSpeechUtterance rate: 0.5 is the system default, lower is slower.
    var speechRate: Float = 0.5
    var voiceIdentifier: String?
    var claudePath: String?
    var toolbarAutoHideSeconds: Double = 6

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        translateModel = try c.decodeIfPresent(String.self, forKey: .translateModel) ?? d.translateModel
        polishModel = try c.decodeIfPresent(String.self, forKey: .polishModel) ?? d.polishModel
        analyzeModel = try c.decodeIfPresent(String.self, forKey: .analyzeModel) ?? d.analyzeModel
        toolbarEnabled = try c.decodeIfPresent(Bool.self, forKey: .toolbarEnabled) ?? d.toolbarEnabled
        doubleCopyEnabled = try c.decodeIfPresent(Bool.self, forKey: .doubleCopyEnabled) ?? d.doubleCopyEnabled
        copyFallbackEnabled = try c.decodeIfPresent(Bool.self, forKey: .copyFallbackEnabled) ?? d.copyFallbackEnabled
        hotkeysEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeysEnabled) ?? d.hotkeysEnabled
        speechRate = try c.decodeIfPresent(Float.self, forKey: .speechRate) ?? d.speechRate
        voiceIdentifier = try c.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        toolbarAutoHideSeconds = try c.decodeIfPresent(Double.self, forKey: .toolbarAutoHideSeconds)
            ?? d.toolbarAutoHideSeconds
    }

    func model(for action: Action) -> String {
        switch action {
        case .translate: return translateModel
        case .polish: return polishModel
        case .analyze: return analyzeModel
        }
    }

    /// Models to keep a warm `claude` process for, in action order, without duplicates.
    var modelsInUse: [String] {
        var seen = Set<String>()
        return Action.allCases.map(model(for:)).filter { seen.insert($0).inserted }
    }

    static let suggestedModels = ["haiku", "sonnet", "opus", "fable"]
}

struct LRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) { self.capacity = capacity }

    subscript(key: Key) -> Value? {
        mutating get {
            guard let value = values[key] else { return nil }
            touch(key)
            return value
        }
        set {
            if let newValue {
                values[key] = newValue
                touch(key)
                while order.count > capacity { values[order.removeFirst()] = nil }
            } else {
                values[key] = nil
                order.removeAll { $0 == key }
            }
        }
    }

    mutating func removeAll() {
        values.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

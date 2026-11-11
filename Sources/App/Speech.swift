import AVFoundation
import Combine

/// Read-aloud with the system voices (offline). Picks the best installed English voice unless the
/// user chose one; Chinese text gets a Chinese voice.
@MainActor
final class SpeechController: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var speakingText: String?
    @Published private(set) var spokenRange: NSRange?

    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var voiceIdentifier: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = voice(for: TextAnalyzer.detectLanguage(clean))
        utterance.rate = rate
        current = utterance
        speakingText = clean
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func isReading(_ text: String) -> Bool {
        isSpeaking && speakingText == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func toggle(_ text: String) {
        if isReading(text) { stop() } else { speak(text) }
    }

    func stop() {
        current = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        speakingText = nil
        spokenRange = nil
    }

    func voice(for language: InputLanguage) -> AVSpeechSynthesisVoice? {
        if language == .chinese {
            return Self.voices(prefix: "zh-CN").first ?? AVSpeechSynthesisVoice(language: "zh-CN")
        }
        if let id = voiceIdentifier, let chosen = AVSpeechSynthesisVoice(identifier: id) { return chosen }
        return Self.voices(prefix: "en-US").first ?? Self.voices(prefix: "en").first
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Installed voices for a language prefix, best quality first, without novelty voices.
    nonisolated static func voices(prefix: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter {
                $0.language.hasPrefix(prefix)
                    && !$0.voiceTraits.contains(.isNoveltyVoice)
                    && !$0.voiceTraits.contains(.isPersonalVoice)
            }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                if a.language != b.language { return a.language > b.language } // en-US before en-GB
                return a.name < b.name
            }
    }

    nonisolated static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "标准"
        }
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if utterance === self.current { self.spokenRange = characterRange }
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        ended(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        ended(utterance)
    }

    nonisolated private func ended(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard utterance === self.current else { return }
                self.current = nil
                self.isSpeaking = false
                self.speakingText = nil
                self.spokenRange = nil
            }
        }
    }
}

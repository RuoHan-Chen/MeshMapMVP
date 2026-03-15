import Foundation
import AVFoundation

/// Offline text-to-speech for accessibility. Uses AVSpeechSynthesizer (no internet required).
final class SpeechManager {
    static let shared = SpeechManager()
    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    /// Speak the given text. Works fully offline.
    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.5
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    /// Stop any current speech.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

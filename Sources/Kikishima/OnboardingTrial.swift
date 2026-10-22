import Foundation
import AVFoundation

enum OnboardingTrial {
    static func canComplete(startedGeneration: Int?, currentGeneration: Int,
                            sourceFinal: Bool, translationComplete: Bool,
                            source: String, translation: String, isDraft: Bool) -> Bool {
        startedGeneration == currentGeneration && sourceFinal && translationComplete &&
            source.contains(where: { $0.isLetter || $0.isNumber }) &&
            CaptionReadingPolicy.isReadable(translation, isDraft: isDraft)
    }

    static func sample(for locale: String) -> String? {
        switch locale.replacingOccurrences(of: "_", with: "-").split(separator: "-").first {
        case "en": "Let's review the next steps together. The meeting starts at ten tomorrow."
        case "ja": "次の予定を一緒に確認しましょう。明日の会議は十時に始まります。"
        case "zh": "我们一起确认接下来的安排。明天的会议十点开始。"
        case "ko": "다음 일정을 함께 확인해 봅시다. 내일 회의는 열 시에 시작합니다."
        case "es": "Revisemos juntos los próximos pasos. La reunión empieza mañana a las diez."
        case "fr": "Examinons ensemble les prochaines étapes. La réunion commence demain à dix heures."
        case "de": "Besprechen wir gemeinsam die nächsten Schritte. Das Treffen beginnt morgen um zehn Uhr."
        case "pt": "Vamos revisar juntos os próximos passos. A reunião começa amanhã às dez."
        case "it": "Rivediamo insieme i prossimi passi. La riunione inizia domani alle dieci."
        default: nil
        }
    }
}

/// Local speech playback only, never Apple translation. It uses an installed
/// voice, then the normal system-audio → ASR → cloud translation pipeline.
@MainActor
final class OnboardingTrialAudio {
    private let speech = AVSpeechSynthesizer()

    @discardableResult
    func play(locale: String) -> Bool {
        let language = locale.replacingOccurrences(of: "_", with: "-")
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard let text = OnboardingTrial.sample(for: locale),
              let voice = voices.first(where: { $0.language == language }) ??
                voices.first(where: { $0.language.split(separator: "-").first == language.split(separator: "-").first })
        else { return false }
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        speech.speak(utterance)
        return true
    }

    func stop() { speech.stopSpeaking(at: .immediate) }
}

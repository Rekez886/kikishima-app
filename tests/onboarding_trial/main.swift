import Foundation

func canComplete(started: Int? = 10, current: Int = 10, final: Bool = true,
                 complete: Bool = true, source: String = "Test speech", translation: String = "测试语音",
                 draft: Bool = false) -> Bool {
    OnboardingTrial.canComplete(startedGeneration: started, currentGeneration: current,
        sourceFinal: final, translationComplete: complete, source: source,
        translation: translation, isDraft: draft)
}
precondition(canComplete())
precondition(!canComplete(started: nil))
precondition(!canComplete(current: 11))
precondition(!canComplete(final: false))
precondition(!canComplete(complete: false))
precondition(!canComplete(source: "..."))
precondition(!canComplete(translation: " \n"))
precondition(!canComplete(translation: "⚠ error"))
precondition(!canComplete(draft: true))
precondition(OnboardingTrial.sample(for: "en_US") == OnboardingTrial.sample(for: "en-GB"))
precondition(OnboardingTrial.sample(for: "ja_JP") != nil)
precondition(OnboardingTrial.sample(for: "unsupported") == nil)
print("PASS: only real finalized translation from this trial can complete onboarding; no audio or network invoked")

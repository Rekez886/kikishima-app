
@main
struct R7RuntimeChecks {
    @MainActor static func main() {
        for silent in [false, true] {
            for stalled in [false, true] {
                let text = CaptionListeningStatus.text(silentTooLong: silent, audioStalled: stalled)
                let expected = stalled ? "音频中断，正在恢复" : silent ? "没听到声音" : "正在听…"
                precondition(text == expected, "warning priority and copy")
                if silent || stalled { precondition(text != "正在听…", "warnings must not claim listening") }
            }
        }
        let state = ModelState()
        for progress in [nil, 0, 0.5, 0.99, 1] as [Double?] {
            state.modelProgress["en_US"] = progress
            for selected in [[], ["en_US"]] {
                state.meetingLocales = selected
                precondition(!state.modelReady("en_US"), "selection or stale progress cannot claim installation")
                state.installedModelLocales = [TranscribeEngine.modelLocaleKey("en-US")]
                precondition(state.modelReady("en_US"), "installed model is ready even with no progress or selection")
                precondition(state.modelReady("en-us"), "locale separators and case normalize")
                precondition(!state.modelReady("ja_JP"), "other locale remains uninstalled")
                state.installedModelLocales = []
                precondition(!state.modelReady("en_US"), "removed model cannot retain a checkmark")
            }
        }
        print("PASS r7 runtime: warning truth table; install snapshots beat selection/progress; locale normalization; model removal")
    }
}

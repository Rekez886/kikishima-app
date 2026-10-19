enum TranscriptionResultPolicy {
    static func accepts(resultGeneration: Int, currentGeneration: Int, draining: Bool, finished: Bool) -> Bool {
        resultGeneration == currentGeneration && !finished
    }
}

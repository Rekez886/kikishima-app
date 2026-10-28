enum TranslationCompletionPolicy {
    static func remainingInflight(_ count: Int, requestGeneration: Int, currentGeneration: Int) -> Int {
        requestGeneration == currentGeneration ? max(0, count - 1) : count
    }
}

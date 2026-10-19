enum AuthResponsePolicy {
    static func accepts(requestGeneration: Int, currentGeneration: Int, requestAccount: String, currentAccount: String) -> Bool {
        requestGeneration == currentGeneration && requestAccount == currentAccount
    }
}

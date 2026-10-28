enum ScreenRetentionPolicy {
    static func targetID(currentID: Int?, availableIDs: [Int], fallbackID: Int?) -> Int? {
        if let currentID, availableIDs.contains(currentID) { return currentID }
        if let fallbackID, availableIDs.contains(fallbackID) { return fallbackID }
        return availableIDs.first
    }
}

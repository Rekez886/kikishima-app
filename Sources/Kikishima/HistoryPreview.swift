/// Preserve native list multi-selection; only derive the single detail item.
enum HistoryPreview {
    static func selectedID<ID: Hashable>(
        previous: ID?, oldSelection: Set<ID>, selection: Set<ID>, orderedIDs: [ID]
    ) -> ID? {
        let added = selection.subtracting(oldSelection)
        if let addedID = orderedIDs.first(where: { added.contains($0) }) { return addedID }
        if let previous, selection.contains(previous), orderedIDs.contains(previous) { return previous }
        return orderedIDs.first(where: { selection.contains($0) })
    }
}

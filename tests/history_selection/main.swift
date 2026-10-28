func check(_ expected: Int?, previous: Int?, old: Set<Int>, selected: Set<Int>, visible: [Int] = [1, 2, 3]) {
    let actual = HistoryPreview.selectedID(previous: previous, oldSelection: old, selection: selected, orderedIDs: visible)
    precondition(actual == expected, "Expected \(String(describing: expected)), got \(String(describing: actual))")
}
check(1, previous: nil, old: [], selected: [1])
check(2, previous: 1, old: [1], selected: [2])
check(2, previous: 1, old: [1], selected: [1, 2]) // Command-add
check(1, previous: 2, old: [1, 2], selected: [1]) // Command-remove preview
check(2, previous: 1, old: [1], selected: [1, 2, 3]) // Shift range
check(2, previous: 2, old: [1, 2], selected: [1, 2]) // Stable on refresh
check(nil, previous: 2, old: [2], selected: []) // Clear/delete last selection
check(3, previous: 2, old: [1, 2, 3], selected: [3]) // Partial deletion
check(nil, previous: 2, old: [2], selected: [2], visible: [1, 3]) // Hidden by search
check(3, previous: 2, old: [2, 3], selected: [2, 3], visible: [3])
print("PASS: 10 history preview selection scenarios")

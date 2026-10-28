import Foundation
// Exact BASE island selection: retainedIndices, pending-dependent recentLimit,
// and latest readable ID as current. This deliberately preserves the old bug.
func readLayout(_ items: [CaptionReadingPolicy.DesktopItem], limit: Int, pending: Bool,
                sourceOnly: Bool, now: Double, queue: inout CaptionReadingPolicy.DesktopQueue) -> CaptionReadingPolicy.DesktopLayout {
    let indices = CaptionReadingPolicy.retainedIndices(readable: items.map { !sourceOnly && $0.translated },
        recentLimit: pending ? limit : limit + 1)
    let ids = indices.map { items[$0].id }
    let current = sourceOnly ? (pending ? nil : ids.last) : items.last(where: { $0.translated })?.id ?? (pending ? nil : ids.last)
    return .init(history: ids.filter { $0 != current }, current: current, showsPending: pending, sourceOnly: [])
}
func compactIDs(_ layout: CaptionReadingPolicy.DesktopLayout) -> [UUID] {
    layout.current.map { [$0] } ?? []
}

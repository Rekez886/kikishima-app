import Foundation
func readLayout(_ items: [CaptionReadingPolicy.DesktopItem], limit: Int, pending: Bool,
                sourceOnly: Bool, now: Double, queue: inout CaptionReadingPolicy.DesktopQueue) -> CaptionReadingPolicy.DesktopLayout {
    CaptionReadingPolicy.islandLayout(items: items, historyLimit: limit, pending: pending,
        showTranslation: !sourceOnly, now: now, queue: &queue)
}
func compactIDs(_ layout: CaptionReadingPolicy.DesktopLayout) -> [UUID] {
    CaptionReadingPolicy.islandVisibleIDs(layout, compact: true)
}

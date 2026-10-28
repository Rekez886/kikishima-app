import Foundation

enum CaptionReadingPolicy {
    /// Pending source and later unfinished requests must not evict the newest
    /// readable translation. Late results retain source order.
    static func retainedIndices(readable: [Bool], recentLimit: Int) -> [Int] {
        var indices = Array(readable.indices.suffix(max(1, recentLimit)))
        if let latest = readable.lastIndex(of: true) {
            indices.removeAll { $0 == latest }
            indices.insert(latest, at: 0)
        }
        return indices
    }

    static func isReadable(_ translation: String, isDraft: Bool) -> Bool {
        !isDraft && !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !translation.hasPrefix("⚠")
    }
}

// Presentation queue only. Translation scheduling and persisted chunks are untouched.
extension CaptionReadingPolicy {
    struct DesktopItem: Equatable {
        let id: UUID
        let finalized: Bool
        let translated: Bool
    }
    struct DesktopQueue: Equatable {
        var advanced: Set<UUID> = []
        var current: UUID?
        var currentSince: TimeInterval = 0
    }
    struct DesktopLayout {
        var history: [UUID]
        var current: UUID?
        var showsPending: Bool
        var sourceOnly: Set<UUID>
        var ids: [UUID] { history + (current.map { [$0] } ?? []) }
    }
    /// Call on input changes and clock ticks. The timeout starts on promotion to
    /// current, never on request creation. Late translations keep their source slot.
    static func desktopLayout(items: [DesktopItem], historyLimit: Int, pending: Bool,
                              now: TimeInterval, queue: inout DesktopQueue) -> DesktopLayout {
        let live = Set(items.map(\.id))
        queue.advanced.formIntersection(live)
        if let id = queue.current, !live.contains(id) { queue.current = nil }
        let capacity = max(1, historyLimit)
        for (index, item) in items.enumerated() where !queue.advanced.contains(item.id) {
            if queue.current != item.id {
                queue.current = item.id
                queue.currentSince = now
            }
            let pinned = items.filter { queue.advanced.contains($0.id) && !$0.finalized }.count
            let timedOut = !item.finalized && now - queue.currentSince > 5 &&
                items.dropFirst(index + 1).contains(where: { $0.translated })
            guard (item.finalized || timedOut), pinned < capacity else { break }
            queue.advanced.insert(item.id)
            queue.current = nil
        }
        var history = items.filter { queue.advanced.contains($0.id) }
        // Keep the last completed sentence in the current slot until the next
        // source arrives. It is still finalized and may be displaced.
        var current = queue.current
        if current == nil && !pending, let last = history.last, last.finalized {
            current = last.id
            history.removeLast()
        }
        while history.count > capacity {
            guard let victim = history.firstIndex(where: { $0.finalized }) else { break }
            history.remove(at: victim)
        }
        return DesktopLayout(history: history.map(\.id), current: current,
            showsPending: queue.current == nil && pending,
            sourceOnly: Set(history.filter { !$0.finalized }.map(\.id)))
    }
}

#if canImport(AppKit)
import AppKit
import CoreText

extension CaptionReadingPolicy {
    struct DesktopText {
        var primary: String
        var secondary: String?
        var overflow: [String]
        var lineCount: Int
        var translated: Bool
        func height(scale: Double) -> Double {
            Double(lineCount) * 24 * scale + (secondary == nil ? 0 : 18 * scale + 4)
        }
    }

    /// Use the same system font design and width as the desktop text column.
    /// CoreText breaks at words/CJK boundaries without displaying a window.
    static func desktopFont(size: Double, family: String, medium: Bool = false) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: medium ? .medium : .regular)
        let design: NSFontDescriptor.SystemDesign = switch family {
        case "rounded": .rounded
        case "serif": .serif
        case "mono": .monospaced
        default: .default
        }
        return font.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }
    static func desktopWrappedLines(_ text: String, width: Double, font: NSFont) -> [String] {
        guard !text.isEmpty else { return [""] }
        let value = text as NSString
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var start = 0
        var lines: [String] = []
        while start < value.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, max(1, width)))
            let range = value.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(count, value.length - start)))
            lines.append(value.substring(with: range).trimmingCharacters(in: .newlines))
            start = NSMaxRange(range)
        }
        return lines
    }
    static func desktopSourceTail(_ text: String, width: Double, font: NSFont) -> String {
        func fits(_ value: String) -> Bool {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: font]))
            return CTLineGetTypographicBounds(line, nil, nil, nil) <= max(1, width)
        }
        guard !fits(text) else { return text }
        let characters = Array(text.replacingOccurrences(of: "\n", with: " "))
        var lower = 0, upper = characters.count
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            if fits("…" + String(characters.suffix(middle))) { lower = middle } else { upper = middle - 1 }
        }
        return "…" + String(characters.suffix(lower))
    }
    static func desktopText(primary: String, secondary: String?, translated: Bool,
                            width: Double, userSize: Double, family: String = "system") -> DesktopText {
        let scale = userSize / 18
        let font = desktopFont(size: 17 * scale, family: family, medium: true)
        let lines = translated ? desktopWrappedLines(primary, width: width, font: font) : [desktopSourceTail(primary, width: width, font: font)]
        let visible = Array(lines.suffix(translated ? 2 : 1))
        let source = secondary.map { desktopSourceTail($0, width: width, font: desktopFont(size: 13 * scale, family: family)) }
        return DesktopText(primary: visible.joined(separator: "\n"), secondary: source,
            overflow: Array(lines.dropLast(visible.count)), lineCount: max(1, visible.count), translated: translated)
    }
}
#endif

extension CaptionReadingPolicy {
    /// Island presentation reuses the proven queue without changing any desktop
    /// behavior. Source-only keeps the pre-existing suffix selection exactly.
    static func islandLayout(items: [DesktopItem], historyLimit: Int, pending: Bool,
                             showTranslation: Bool, now: TimeInterval,
                             queue: inout DesktopQueue) -> DesktopLayout {
        if !showTranslation {
            let indices = retainedIndices(readable: items.map { _ in false },
                recentLimit: pending ? historyLimit : historyLimit + 1)
            var ids = indices.map { items[$0].id }
            let current = pending ? nil : ids.popLast()
            return DesktopLayout(history: ids, current: current, showsPending: pending, sourceOnly: [])
        }
        var layout = desktopLayout(items: items, historyLimit: historyLimit,
            pending: pending, now: now, queue: &queue)
        // The island's existing sizing function can return zero history slots.
        // Preserve its steady-state count; unfinished promoted history still
        // has priority over eviction, including at the smallest height.
        if historyLimit == 0 {
            layout.history.removeAll { id in !layout.sourceOnly.contains(id) }
        }
        return layout
    }
    static func islandVisibleIDs(_ layout: DesktopLayout, compact: Bool) -> [UUID] {
        compact ? layout.current.map { [$0] } ?? [] : layout.ids
    }
}

import AppKit
import SwiftUI

/// One owner across live captions and review, including multiple visible windows.
@MainActor
final class CopyFeedbackPresenter: ObservableObject {
    static let shared = CopyFeedbackPresenter()
    @Published private(set) var feedback = CopyFeedback()
    @Published private(set) var displayedID: String?
    private var expiry: Task<Void, Never>?

    func show(_ id: String) {
        expiry?.cancel()
        feedback.show(id, now: ProcessInfo.processInfo.systemUptime)
        displayedID = id
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: tr("已复制"),
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        expiry = Task { @MainActor in
            // Recheck the deadline so an early wake cannot hide the latest copy.
            while let deadline = feedback.deadline {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                if feedback.expire(now: ProcessInfo.processInfo.systemUptime) { break }
            }
            do { try await Task.sleep(nanoseconds: UInt64(CopyFeedback.fadeDuration * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            displayedID = nil
        }
    }
}

struct CopyFeedbackBadge: View {
    let id: String
    @ObservedObject private var presenter = CopyFeedbackPresenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        if presenter.displayedID == id {
            Label(tr("已复制"), systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(KKColor.textSecondary)
                .fixedSize()
                .opacity(appeared && presenter.feedback.id == id ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: CopyFeedback.fadeDuration),
                           value: appeared && presenter.feedback.id == id)
                .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
                .accessibilityLabel(tr("已复制"))
                .accessibilityHidden(presenter.feedback.id != id)
                .onAppear { appeared = true }
                .onDisappear { appeared = false }
                // Switching rows removes the old badge immediately, without an outgoing copy.
                .transition(.identity)
        }
    }
}

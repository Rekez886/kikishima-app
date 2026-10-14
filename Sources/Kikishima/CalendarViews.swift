import SwiftUI
import AppKit

struct CalendarMeetingCard: View {
    @Bindable var coordinator: CalendarCoordinator
    let isRunning: Bool
    @State private var showingPicker = false

    var body: some View {
        if isRunning, let context = coordinator.selectedContext {
            VStack(alignment: .leading, spacing: 6) {
                Text(context.title).font(.headline).lineLimit(2)
                Label(tr("已用于这场会议"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        } else if !isRunning {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(tr("日历会议"), systemImage: "calendar")
            }
            .task { await coordinator.refresh(force: false) }
            .sheet(isPresented: $showingPicker) {
                CalendarMeetingPicker(coordinator: coordinator)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.presentationState {
        case .needsPermission:
            Text(tr("连接 macOS 日历，开会前选择会议，Kikishima 会用标题和参会者姓名准备术语。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(tr("允许访问日历")) {
                Task { await coordinator.requestMacAccess() }
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(tr("正在读取会议…")).foregroundStyle(.secondary)
            }
        case .denied:
            Text(tr("Kikishima 没有日历权限，仍可直接开始字幕。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(tr("打开系统设置")) { CalendarSystemSettings.open() }
        case .empty:
            HStack {
                Text(tr("接下来没有找到会议。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(tr("刷新")) { Task { await coordinator.refresh(force: true) } }
                    .controlSize(.small)
            }
        case .available:
            if let candidate = coordinator.candidates.first {
                candidateDetails(candidate)
                HStack {
                    Button(tr("用于这场会议")) { coordinator.select(candidate) }
                        .buttonStyle(.bordered)
                    Button(tr("今天的会议…")) { showingPicker = true }
                }
            }
        case .selected:
            if let context = coordinator.selectedContext {
                Text(context.title).font(.headline).lineLimit(2)
                Text(timeText(start: context.startDate, end: context.endDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Label(tr("已用于这场会议"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button(tr("更换会议")) { showingPicker = true }
                    Button(tr("清除"), role: .destructive) { coordinator.clearSelection() }
                }
            }
        }
    }

    @ViewBuilder
    private func candidateDetails(_ candidate: CalendarEventCandidate) -> some View {
        Text(candidate.title).font(.headline).lineLimit(2)
        HStack(spacing: 10) {
            Text(timeText(start: candidate.startDate, end: candidate.endDate))
            Text(sourceText(candidate.sources))
            if !candidate.attendeeNames.isEmpty {
                Text(tr("%@ 位参会者", candidate.attendeeNames.count))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct CalendarMeetingPicker: View {
    @Bindable var coordinator: CalendarCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tr("今天的会议")).font(.title2.bold())
                Spacer()
                Button(tr("刷新")) { Task { await coordinator.refreshToday(force: true) } }
                    .disabled(coordinator.isRefreshing)
                Button(tr("完成")) { dismiss() }
            }

            if coordinator.isRefreshing, coordinator.todayCandidates.isEmpty {
                HStack {
                    Spacer()
                    ProgressView(tr("正在读取会议…"))
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else if coordinator.todayCandidates.isEmpty {
                ContentUnavailableView(
                    tr("今天没有找到会议"),
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text(tr("你仍可不选择会议，直接开始字幕。"))
                )
            } else {
                List(coordinator.todayCandidates) { candidate in
                    Button {
                        coordinator.select(candidate)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: isSelected(candidate) ? "checkmark.circle.fill" : "calendar")
                                .foregroundStyle(isSelected(candidate) ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.title).font(.headline)
                                Text(timeText(start: candidate.startDate, end: candidate.endDate))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(sourceText(candidate.sources))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .task { await coordinator.refreshToday(force: false) }
    }

    private func isSelected(_ candidate: CalendarEventCandidate) -> Bool {
        guard let selected = coordinator.selectedContext else { return false }
        return selected.title == candidate.title
            && selected.startDate == candidate.startDate
            && selected.endDate == candidate.endDate
    }
}

struct MacCalendarSettingsRow: View {
    @Bindable var coordinator: CalendarCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(tr("macOS 日历"), systemImage: "calendar")
                Spacer()
                statusControl
            }
            Text(tr("macOS 会显示“完全访问”。Kikishima 只读取会议标题、时间和参会者姓名，不会修改你的日历。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if coordinator.authorization(for: .macOS) == .denied
                || coordinator.authorization(for: .macOS) == .restricted
                || coordinator.authorization(for: .macOS) == .needsReconnect {
                Text(tr("请前往：系统设置 > 隐私与安全性 > 日历 > Kikishima"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task { await coordinator.refresh(force: false) }
    }

    @ViewBuilder
    private var statusControl: some View {
        switch coordinator.authorization(for: .macOS) {
        case .notDetermined:
            Button(tr("允许访问")) { Task { await coordinator.requestMacAccess() } }
                .disabled(coordinator.isRefreshing || coordinator.isRequestingMacAccess)
        case .authorized:
            Label(tr("已连接"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied, .restricted:
            Button(tr("打开系统设置")) { CalendarSystemSettings.open() }
        case .needsReconnect:
            HStack(spacing: 6) {
                Button(tr("重试")) { Task { await coordinator.requestMacAccess() } }
                    .disabled(coordinator.isRequestingMacAccess)
                Button(tr("打开系统设置")) { CalendarSystemSettings.open() }
            }
        }
    }
}

enum CalendarSystemSettings {
    @MainActor
    static func open() {
        let workspace = NSWorkspace.shared
        let calendarURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        if !workspace.open(calendarURL),
           let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            workspace.open(fallback)
        }
    }
}

@MainActor
private func timeText(start: Date, end: Date) -> String {
    "\(start.formatted(date: .omitted, time: .shortened)) ～ \(end.formatted(date: .omitted, time: .shortened))"
}

@MainActor
private func sourceText(_ sources: Set<CalendarSource>) -> String {
    CalendarSource.allCases
        .filter(sources.contains)
        .map { source in
            switch source {
            case .macOS: return tr("macOS 日历")
            case .google: return tr("Google 日历")
            }
        }
        .joined(separator: " + ")
}

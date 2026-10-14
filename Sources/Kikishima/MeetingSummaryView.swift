import AppKit
import SwiftUI

struct MeetingSummaryDetailView: View {
    let transcript: TranscriptFile
    let document: MeetingSummaryDocument?
    let canRetry: Bool
    let onRetry: () -> Void

    @State private var expandedSourceIDs: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(transcript.name)
                        .font(.system(size: 20, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { recordDate; openRecord }
                        VStack(alignment: .leading, spacing: 6) { recordDate; openRecord }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        statusView
                        if let document, document.status == .failed || document.status == .interrupted {
                            Button(tr("重试"), action: onRetry).buttonStyle(.link).disabled(!canRetry)
                        }
                    }.font(.system(size: 12))
                }

                if let document {
                    summaryContent(document)
                } else {
                    ContentUnavailableView(
                        tr("尚未生成总结"),
                        systemImage: "list.bullet.clipboard",
                        description: Text(tr("原始会议记录仍可正常打开。"))
                    )
                }
            }
            .font(.system(size: 13))
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var recordDate: some View {
        Text(transcript.date, style: .date).font(.system(size: 12)).foregroundStyle(.secondary)
    }
    private var openRecord: some View {
        Button(tr("打开原始记录")) { NSWorkspace.shared.open(transcript.url) }
            .buttonStyle(.link).font(.system(size: 12))
    }

    @ViewBuilder
    private var statusView: some View {
        if let document {
            switch document.status {
            case .active, .finalizing:
                Label(tr("正在整理会议要点…"), systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            case .failed:
                Label(tr("总结暂时不可用"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .interrupted:
                Label(tr("总结已中断"), systemImage: "pause.circle")
                    .foregroundStyle(.orange)
            case .finished:
                Label(tr("会议总结"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func summaryContent(_ document: MeetingSummaryDocument) -> some View {
        let content = document.content
        blocksSection(tr("概览"), blocks: content.overview, document: document, bullets: false)
        blocksSection(tr("当前状态"), blocks: content.currentState, document: document)
        blocksSection(tr("关键决定"), blocks: content.decisions, document: document)

        if !content.actionItems.isEmpty {
            summarySection(tr("待办事项")) {
                ForEach(content.actionItems) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                            Text(item.text).textSelection(.enabled)
                        }
                        if item.owner != nil || item.deadline != nil {
                            Text([item.owner, item.deadline].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 18)
                        }
                        sourceRefs(item.sourceRefs, document: document)
                            .padding(.leading, 18)
                    }
                }
            }
        }

        blocksSection(tr("与你相关"), blocks: content.personalItems, document: document)
        blocksSection(tr("未决问题"), blocks: content.openQuestions, document: document)
    }

    @ViewBuilder
    private func blocksSection(
        _ title: String,
        blocks: [SummaryBlock],
        document: MeetingSummaryDocument,
        bullets: Bool = true
    ) -> some View {
        if !blocks.isEmpty {
            summarySection(title) {
                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if bullets { Text("•") }
                            Text(block.text).textSelection(.enabled)
                        }
                        sourceRefs(block.sourceRefs, document: document)
                            .padding(.leading, bullets ? 18 : 0)
                    }
                }
            }
        }
    }

    private func summarySection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
    }

    private func sourceRefs(
        _ refs: [SummarySourceRef],
        document: MeetingSummaryDocument
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(refs, id: \.self) { ref in
                    Button {
                        if expandedSourceIDs.contains(ref.segmentID) {
                            expandedSourceIDs.remove(ref.segmentID)
                        } else {
                            expandedSourceIDs.insert(ref.segmentID)
                        }
                    } label: {
                        Text(tr("来源 %@", formattedTime(ref.startSeconds)))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(expandedSourceIDs.contains(ref.segmentID) ? tr("已展开") : tr("已收起"))
                }
            }
            ForEach(refs.filter { expandedSourceIDs.contains($0.segmentID) }, id: \.self) { ref in
                if let source = document.sourceIndex[ref.segmentID] {
                    Text(source.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private func formattedTime(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}

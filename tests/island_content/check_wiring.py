from pathlib import Path
import sys

panel = Path('Sources/Kikishima/CaptionPanel.swift').read_text()
island = Path('Sources/Kikishima/IslandNotch.swift').read_text()
rows = panel.split('private var captionRows:')[1].split('private var islandPauseRow:')[0]
assert 'if isIsland || hostedInNotch' in rows
assert 'surfaceBase' not in rows and 'desktopCaptionRows' in rows
assert 'if state.paused { islandPauseRow }' in rows
assert 'geometry.size.height' in rows and '.fixedSize(horizontal: false, vertical: true)' in rows
assert 'ScrollView(.vertical)' in panel and '.scrollClipDisabled' not in panel
assert 'height: Double(islandHeightCap)' in panel
pause = panel.split('private var islandPauseRow:')[1].split('private var desktopCaptionRows:')[0]
assert 'pause.fill' in pause and 'KKColor.textSecondary' in pause
assert 'surfaceRaised' not in pause
assert 'context.duration = 0.2' in island and 'controlPoints: 0.2, 0, 0, 1' in island
assert 'context.duration = 0.1' in island and 'accessibilityReduceMotion' in island
assert 'measured: display.measuredHeight' in island
assert 'measured: islandDisplay.measuredHeight' in panel
assert 'CaptionIslandToolbarLayout.floatingWindowHeight(contentHeight: content.height, expanded: expanded)' in panel
assert 'CaptionIslandToolbarLayout.floatingWindowHeight(contentHeight: content.height, expanded: expanded)' in island
assert 'height: content.height + notchH + 15' in island
start = island.index('@MainActor @Observable')
end = island.index('/// Content shift:', start)
Path(sys.argv[1]).write_text('import Foundation\nimport CoreGraphics\n' + island[start:end].replace('@MainActor @Observable', '@MainActor'))
print('PASS segment A wiring')
# r14b: a fixed outer frame still needs an animated internal status/scroll boundary.
assert 'AnyLayout(IslandCaptionColumn(statusFraction: displayedErrorStatus == nil ? 0 : 1))' in panel
assert 'var animatableData: CGFloat' in panel
assert 'IslandCaptionColumnGeometry(bounds: bounds,' in panel
assert 'statusHeight: cache.statusHeight, fraction: statusFraction' in panel
assert 'if status > 0 { cache.statusHeight = status }' in panel
assert 'func updateCache(_ cache: inout Cache, subviews: Subviews) {}' in panel
assert 'duration: toolbarMode == .island ? 0.2 : 0.12' in panel
assert '.frame(minHeight: 0, maxHeight: .infinity, alignment: .top)\n                .clipped()' in panel
assert '.accessibilityHidden(displayedErrorStatus == nil)' in panel
row = panel.split('private func captionRow(', 1)[1].split('private func copyFeedbackID', 1)[0]
assert '.id(chunk.displayTranslation.isEmpty)\n                    .transition(.identity)' in row
assert '.textSelection(.enabled)\n            .accessibilityElement(children: .ignore)\n            .accessibilityLabel(text.accessibilityText)' in row
assert 'islandHost.sizingOptions = []' in panel
assert panel.index('islandHost.sizingOptions = []') < panel.index('p.contentView = islandHost')
print('PASS r14b production wiring: animatable internal column, visible-text-only AX, controller-owned panel size')

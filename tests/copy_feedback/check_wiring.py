from pathlib import Path
import json

root = Path('Sources/Kikishima')
panel = (root / 'CaptionPanel.swift').read_text()
review = (root / 'CaptionReview.swift').read_text()
ui = (root / 'CopyFeedbackView.swift').read_text()
assert 'static let shared = CopyFeedbackPresenter()' in ui
assert 'expiry?.cancel()' in ui and 'guard !Task.isCancelled' in ui
assert 'feedback.expire(now: ProcessInfo.processInfo.systemUptime)' in ui
assert '@Environment(\\.accessibilityReduceMotion)' in ui
assert 'reduceMotion ? nil : .easeInOut(duration: CopyFeedback.fadeDuration)' in ui
assert 'if reduceMotion { $0.animation = nil; $0.disablesAnimations = true }' in ui
assert '.transition(.identity)' in ui
assert 'Label(tr("已复制"), systemImage: "checkmark")' in ui
assert '.foregroundStyle(KKColor.textSecondary)' in ui
assert '.announcementRequested' in ui and '.announcement: tr("已复制")' in ui
assert '.accessibilityHidden(presenter.feedback.id != id)' in ui
for forbidden in ('KKColor.brand', '.background(', 'NSSound', 'toast'):
    assert forbidden not in ui
for text in ('zh', 'en'):
    assert f'copy(chunk.{text}, feedbackID: copyFeedbackID(chunk))' in panel
assert 'CopyFeedbackBadge(id: copyFeedbackID(chunk))' in panel
row = panel.split('private func captionRow(')[1].split('private func copyFeedbackID')[0]
assert row.index('HStack(') < row.index('CopyFeedbackBadge(') < row.index('.contextMenu')
assert 'feedbackID' not in panel.split('private func copyAll()')[1].split('\n}')[0]
assert 'copy(matches, feedbackID: copyFeedbackID("toolbar"))' in review
assert 'copy([chunk], feedbackID: copyFeedbackID(chunk.id.uuidString))' in review
assert review.count('CopyFeedbackBadge(id:') == 2
assert '.accessibilityIdentifier("kk-review-copy")' in review
for source in (panel, review):
    assert '@State private var copyFeedbackOwner = UUID()' in source
    assert 'CopyFeedbackPresenter.shared.show(feedbackID)' in source
for lang, value in {'zh-Hant': '已複製', 'ja': 'コピーしました', 'en': 'Copied', 'ko': '복사됨'}.items():
    name = f'Resources/l10n/{lang}.json'
    current = json.loads(Path(name).read_text())
    assert current['已复制'] == value
print('PASS copy feedback wiring, reduce motion, announcement, four feedback translations')

"""Check actual view ordering and preserve baseline visibility, fallback and style.

The fixture is the eight complete conditional blocks from 61cd3a1, with
indentation stripped. Only their order may change. Compile the actual guards
below with synthetic values; never instantiate CaptionState or read defaults.
"""
import json
from pathlib import Path
import sys

root = Path('Sources/Kikishima')
panel = (root / 'CaptionPanel.swift').read_text()
island = (root / 'IslandNotch.swift').read_text()
assert 'NSHostingView(rootView: CaptionFeedView(state: s))' in panel
assert 'CaptionFeedView(state: state, hostedInNotch: true, hostSideInset: display.hostSideInset)' in island
assert 'notchless' in island and 'IslandExpandedView(state:' in island

def block(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return '\n'.join(line.strip() for line in source[start:end].splitlines() if line.strip())

# Hides bilingual history source; keep current compact/regular guards,
# fallback behavior and translation-first order.
row = panel[panel.index('private func captionRow('):]
assert row.index('chunk.displayTranslation') < row.index('if CaptionHierarchy.showsSource')
assert panel.index('Text(state.pendingDraft)') < panel.index('Text(state.pendingEn)')
assert 'state.translationPaused && !state.showSource ? chunk.en : "…"' in row
assert 'state.translationPaused ? (state.showSource ? "" : chunk.en) : "…"' in row
source_condition = row[row.index('if CaptionHierarchy.showsSource'):].split('{', 1)[0]
source_guard = ' '.join(source_condition[3:].split())
policy = block((root / 'CaptionIsland.swift').read_text(), 'static func showsSource(')
guards = []
for name in ['compact', 'regular']:
    guard = source_guard.replace('state.compactCaptions', 'true' if name == 'compact' else 'false')
    guards.extend([(name, 'source', guard), (name, 'translation', 'state.showTranslation'),
                   (name, 'pendingSource', 'state.showSource && !state.pendingEn.isEmpty'),
                   (name, 'pendingTranslation', 'state.showTranslation && !state.pendingDraft.isEmpty')])

# Execute actual Swift visibility expressions for both current and historical
# sentences, all display modes, empty/nonempty translation and pending text.
harness = 'enum CaptionHierarchy {\n' + policy + '\n}\n' + '''
struct State {
    var showSource: Bool; var showTranslation: Bool
    var pendingEn: String; var pendingDraft: String
}
struct Chunk { var zh: String }
for mode in ["both", "source", "translation"] {
  for sentence in ["current", "history"] {
    for translated in [false, true] {
      for pending in [false, true] {
        let state = State(showSource: mode != "translation", showTranslation: mode != "source",
                          pendingEn: pending ? "source" : "", pendingDraft: pending ? "translation" : "")
        let chunk = Chunk(zh: translated ? "translation" : "")
        let current = sentence == "current"
'''
for name, key, guard in guards:
    expected = {
        'source': '(mode != "translation" && (sentence == "current" || mode == "source") && (mode == "source" || translated))' if name == 'compact' else '(mode != "translation" && (sentence == "current" || mode == "source"))',
        'translation': '(mode != "source")',
        'pendingSource': '(mode != "translation" && pending)',
        'pendingTranslation': '(mode != "source" && pending)',
    }[key]
    harness += f'precondition(({guard}) == {expected}, "{name}.{key} \\(sentence) \\(mode)")\n'
harness += '      }\n    }\n  }\n}\nprint("PASS caption visibility: current/history, bilingual/source/translation, pending and empty translation")\n'
Path(sys.argv[1]).write_text(harness)

tokens = (root / 'DesignTokens.swift').read_text()
active = block(tokens, 'func kkPrimaryButton(active: Bool)')
assert 'if active {' in active
assert '.tint(KKColor.surfaceRaised).foregroundStyle(KKColor.textPrimary)' in active
assert 'else {\nself.kkPrimaryButton()' in active
idle = block(tokens, 'func kkPrimaryButton()')
assert 'self.buttonStyle(KKFilledButtonStyle(active: false))' in block(tokens, 'func kkPrimaryButton()')
assert '.foregroundStyle(KKColor.brandOn)' in block(tokens, 'func kkPrimaryButton()')
assert '.background(active ? KKColor.surfaceRaised : KKColor.brand,' in block(tokens, 'private struct KKFilledButtonArtwork:')
assert '.foregroundStyle(active ? KKColor.textPrimary : KKColor.brandOn)' in block(tokens, 'private struct KKFilledButtonArtwork:')
menu = (root / 'App.swift').read_text()
preview = (root / 'HomeCaptionPreview.swift').read_text()
main = (root / 'MainWindow.swift').read_text()
assert '.kkPrimaryButton(active: state.running || state.starting)' in menu
assert '.kkPrimaryButton(active: active)' in preview
assert 'HomeCaptionControls(active: state.running || state.starting' in main
for folder in [Path('Sources'), Path('Resources/l10n')]:
    for path in folder.rglob('*'):
        if path.is_file():
            text = path.read_text()
            assert '⌃⌥P' not in text and '暂停快捷键' not in text, path
for source, label in [(main, '快捷键 %@'), (main, '当前生效：%@'),
                      (main, '2. 会议开始后'), (menu, '快捷键：%@'),
                      ((root / 'Onboarding.swift').read_text(), '开会时：菜单栏点图标')]:
    line = next(line for line in source.splitlines() if label in line)
    assert 'GlobalHotkey.displayText' in line
print('PASS view wiring: shared desktop/notch/capsule feed, translation first, active/idle buttons, current shortcuts')

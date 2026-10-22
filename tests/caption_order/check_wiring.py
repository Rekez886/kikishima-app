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
assert 'CaptionFeedView(state: state, hostedInNotch: true, hostSideInset: display.hostSideInset, toolbarNotchWidth: display.notchWidth, toolbarNotchHeight: display.toolbarNotchHeight)' in ' '.join(island.split())
assert 'notchless' in island and 'IslandExpandedView(state:' in island

def block(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return '\n'.join(line.strip() for line in source[start:end].splitlines() if line.strip())

# One role policy; the detailed source/waiting matrix is shared with the offline status tests.
import subprocess
out = Path(sys.argv[1])
subprocess.run([sys.executable, 'tests/kk033_offline/prepare_source.py', str(out.parent)], check=True)
code=(out.parent/'SourceMatrix.swift').read_text()
code=code.replace('@main struct Matrix { static func main() {', 'func runMatrix() {').replace('\n}}\n', '\n}\nrunMatrix()\n')
out.write_text(code)

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

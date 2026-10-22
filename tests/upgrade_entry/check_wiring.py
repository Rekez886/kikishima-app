"""Verify upgrade entry wiring without opening checkout or reading preferences."""
import json
from pathlib import Path
import re
import sys

root = Path('Sources/Kikishima')
menu = (root / 'App.swift').read_text().split('struct MenuContent:', 1)[1]
settings = (root / 'MainWindow.swift').read_text().split('struct SettingsPane:', 1)[1]
panel = (root / 'CaptionPanel.swift').read_text()
guard = 'if state.plan != "pro" && state.plan != "dev"'
button = 'Button(tr("升级 Pro")) { state.openUpgrade() }'

def block(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

menu_guard = 'if state.menuShowsUpgrade'
branches = [block(menu, menu_guard), block(settings, guard), block(block(panel, 'if action == .upgrade'), guard)]
for entry in branches:
    assert button in entry
    assert re.search(re.escape(button) + r'\s*\.kkPrimaryButton\(\)', entry)
    assert 'active:' not in entry
assert menu.count(button) == 1
assert menu.index('statusBlock') < menu.index(button) < menu.index('Text(state.remainingText)')
assert 'if state.menuShowsLogin' in menu
assert 'if state.captionDisplayStatus == .audioStalled' not in menu
assert 'Button(tr(action.title)) { state.performBanner(action) }' in panel
tokens = (root / 'DesignTokens.swift').read_text()
assert 'self.buttonStyle(KKFilledButtonStyle(active: false))' in block(tokens, 'func kkPrimaryButton()')
assert '.foregroundStyle(KKColor.brandOn)' in block(tokens, 'func kkPrimaryButton()')
assert '.background(active ? KKColor.surfaceRaised : KKColor.brand,' in block(tokens, 'private struct KKFilledButtonArtwork:')
assert '.foregroundStyle(active ? KKColor.textPrimary : KKColor.brandOn)' in block(tokens, 'private struct KKFilledButtonArtwork:')

# Trial countdown is currently part of the Pro/dev card, so the non-Pro rule
# deliberately leaves that card without an upgrade button.
main = (root / 'MainWindow.swift').read_text()
summary = block(main, 'private var accountSummary:')
assert 'if state.plan == "pro" || state.plan == "dev"' in summary
assert 'let days = state.trialDaysLeft' in summary
assert 'return .init(tier: .pro' in summary
assert 'openUpgrade' not in summary
state = (root / 'CaptionState.swift').read_text()
assert '需要订阅 Pro 才能继续翻译"), action: .upgrade)' in state

# Compile the actual guard copied from each view. No CaptionState is created.
harness = 'struct State { var plan: String; var sessionToken: String }\n'
for index, entry in enumerate(branches[1:], start=1):
    expression = entry.split('{', 1)[0].strip()[3:].replace(', ', ' && ')
    harness += f'func visible{index}(_ state: State) -> Bool {{ {expression} }}\n'
harness += '''
for plan in ["free", "pro", "dev", "", "unknown"] {
    let state = State(plan: plan, sessionToken: "fixture")
    let expected = plan != "pro" && plan != "dev"
    precondition(visible1(state) == expected, "settings eligibility")
    precondition(visible2(state) == expected, "banner eligibility")
}
let signedOut = State(plan: "free", sessionToken: "")
// Menu eligibility is exercised against production state properties elsewhere.
print("PASS upgrade eligibility: settings and banner agree for free/pro/dev/empty/unknown")
'''
Path(sys.argv[1]).write_text(harness)

# Later releases add real onboarding/review/sharing copy. Check the public
# contract (complete translations and matching formats), not a frozen global
# key fingerprint from before those approved features.
keys = set()
for path in root.glob('*.swift'):
    for match in re.finditer(r'\btr(?:Any)?\(\s*"((?:[^"\\]|\\.)*)"', path.read_text()):
        keys.add(match.group(1).replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\'))
price = 'Pro：$4.99/月 或 $39/年 · 7 天免费试用 · 随时取消'
assert price in keys
assert {'升级 Pro', '隐藏边栏', '显示边栏', '记录列表', '切换输出设备，当前 %@', '无'} <= keys
# Sidebar titles reach tr() through rawValue, rather than literal call sites.
keys.update(re.findall(r'=\s*"([^"]+)"', block(main, 'enum MainSection:')))
for language in ('zh-Hant', 'ja', 'en', 'ko'):
    path = Path('Resources/l10n') / f'{language}.json'
    table = json.loads(path.read_text())
    assert keys <= table.keys(), f'{path}: missing {sorted(keys - table.keys())}'
    assert '$4.99' in table[price] and '$39' in table[price]
    for key in keys:
        assert table[key] and table[key].count('%@') == key.count('%@'), (path, key)
print('PASS upgrade wiring and complete localized keys/format arguments')

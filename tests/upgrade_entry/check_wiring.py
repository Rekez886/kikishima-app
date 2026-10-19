"""Verify upgrade entry wiring without opening checkout or reading preferences."""
import hashlib
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

menu_guard = 'if !state.sessionToken.isEmpty, state.plan != "pro" && state.plan != "dev"'
branches = [block(menu, menu_guard), block(settings, guard), block(block(panel, 'if action == .upgrade'), guard)]
for entry in branches:
    assert button in entry
    assert re.search(re.escape(button) + r'\s*\.kkPrimaryButton\(\)', entry)
    assert 'active:' not in entry
assert menu.count(button) == 1
assert menu.index('Text(state.remainingText)') < menu.index(button) < menu.index('if state.audioStalled')
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
for index, entry in enumerate(branches):
    expression = entry.split('{', 1)[0].strip()[3:].replace(', ', ' && ')
    harness += f'func visible{index}(_ state: State) -> Bool {{ {expression} }}\n'
harness += '''
for plan in ["free", "pro", "dev", "", "unknown"] {
    let state = State(plan: plan, sessionToken: "fixture")
    let expected = plan != "pro" && plan != "dev"
    precondition(visible0(state) == expected, "menu eligibility")
    precondition(visible1(state) == expected, "settings eligibility")
    precondition(visible2(state) == expected, "banner eligibility")
}
let signedOut = State(plan: "free", sessionToken: "")
precondition(!visible0(signedOut), "signed-out menu has only one primary action")
print("PASS upgrade eligibility: menu, settings and banner agree for free/pro/dev/empty/unknown")
'''
Path(sys.argv[1]).write_text(harness)

# These fingerprints capture key sets at 61cd3a1, independently of git at test
# time. Catch new source keys and new or removed keys in all four tables.
def digest(keys):
    return hashlib.sha256(json.dumps(sorted(keys), ensure_ascii=False).encode()).hexdigest()

# Explicitly replaces these existing copy keys and removes one unused help key.
# Normalize only that approved delta; retain the original baseline for everything else.
r3_previous_keys = {
    '3. 字幕默认显示在屏幕顶部的灵动岛，也可在菜单面板切到桌面窗口。': '3. 字幕窗浮在会议窗口上，贴在屏幕顶部。',
    'API key 无效或已吊销 · 打开设置检查': 'API key 无效或已吊销 \u2014 打开设置检查',
    '无网络 · 字幕仅转写，恢复联网后自动继续翻译': '无网络 \u2014 字幕仅转写，恢复联网后自动继续翻译',
}
removed_help_key = '3. 字幕窗浮在会议窗口上；会议模式贴屏幕顶部，视频模式贴底部。'
baseline = json.loads(Path('tests/upgrade_entry/l10n_keys_baseline.json').read_text())
keys = set()
for path in root.glob('*.swift'):
    for match in re.finditer(r'\btr(?:Any)?\(\s*"((?:[^"\\]|\\.)*)"', path.read_text()):
        keys.add(match.group(1).replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\'))
# Authorizes two sidebar AX keys, the named history list, and the display-only price replacement.
r11_keys = {'隐藏边栏', '显示边栏', '记录列表'}
assert r11_keys <= keys
keys -= r11_keys
new_price = 'Pro：$4.99/月 或 $39/年 · 7 天免费试用 · 随时取消'
previous_price = new_price.replace('$4.99', '$'+str(999/100)).replace('$39', '$'+str(79))
assert new_price in keys and previous_price not in keys
keys.remove(new_price); keys.add(previous_price)
# Adds exactly these keys; preserve the original fingerprint for all others.
r8_keys = {
    '尚未确认系统音频权限，请在系统设置里检查；播放声音后回来重试。',
    '还没有会议记录。停止字幕时会自动保存到「%@」。',
    '停止字幕时会自动保存到「%@」。',
    '桌面窗口可拖动、可改大小。', '删除 %@', '下载中 %@%',
}
assert r8_keys <= keys
r9_keys = {'切换音频来源，当前 %@', '未知设备', '已安装', '暂停'}
# Replaces short pause AX copy with the existing caption-action keys.
assert r9_keys - {'暂停'} <= keys
keys -= r9_keys
keys.discard('术语表') # existing table key is now an explicit AX label
keys -= r8_keys
# AX labels now use these existing table entries as literals.
keys -= {'小', '大', '窄', '宽', '低', '高', '背景 %@%'}
keys.update({'还没有会议记录。停止字幕时会自动保存到「文稿 › Kikishima」。',
             '停止字幕时会自动保存到「文稿 › Kikishima」。'})
keys = [key for key in keys if key != '双语']
keys.append('原文 + 译文')
# Renders headings through the existing sidebar rawValue, so the literal scan
# no longer sees help/history. The greeting is intentionally no longer rendered.
# Normalize these removals only; no new source/table keys are permitted.
for key in ['帮助', '会议记录', '欢迎回来']:
    assert key not in keys, f'legacy title unexpectedly rendered: {key}'
    keys.append(key)
keys = sorted({r3_previous_keys.get(key, key) for key in keys})
assert digest(keys) == baseline['sourceKeys'], 'source l10n keys changed'
for language, fingerprint in baseline['tables'].items():
    table = json.loads(Path(f'Resources/l10n/{language}.json').read_text())
    assert '升级 Pro' in table
    assert r11_keys <= table.keys() and new_price in table
    assert '$4.99' in table[new_price] and '$39' in table[new_price]
    assert r8_keys <= table.keys()
    assert r9_keys <= table.keys()
    for key in r9_keys:
        assert table[key] and table[key].count('%@') == key.count('%@')
    for key in r8_keys:
        assert table[key] and table[key].count('%@') == key.count('%@')
    normalized = {r3_previous_keys.get(previous_price if key == new_price else key, previous_price if key == new_price else key) for key in table if key != '双语' and key not in r8_keys and key not in r9_keys and key not in r11_keys}
    normalized.add(removed_help_key)
    assert digest(normalized) == fingerprint, f'{language} l10n keys changed'
print('PASS upgrade wiring: checkout actions, brand style, account proximity, existing banner, only approved bilingual l10n key changes')

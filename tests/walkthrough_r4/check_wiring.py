"""Inspect all six page wiring and every source-only icon Button without running the app."""
from pathlib import Path
import re

root = Path('Sources/Kikishima')
read = lambda name: (root / name).read_text()
main, tokens, panel = map(read, ['MainWindow.swift', 'DesignTokens.swift', 'CaptionPanel.swift'])
# A single page header outside the switch guarantees identical placement/type/color.
header = main.split('} detail: {', 1)[1].split('.buttonStyle(', 1)[0]
assert header.count('MainPageTitle(') == 1
assert 'tr((state.mainSection ?? .captions).rawValue)' in header
# R11 keeps the approved 24 pt header inset; the interrupted 32 pt edit was reverted.
assert '.padding(.horizontal, KKSpace.six).padding(.top, KKSpace.six).padding(.bottom, KKSpace.four)' in header
for page in ['captions', 'history', 'glossary', 'languages', 'settings', 'help']:
    assert f'case .{page}:' in header
# A private account-name assertion was removed.
assert 'Text(state.status).font(.system(size: KKLayout.bodyFontSize))' in main
page_title = tokens.split('struct MainPageTitle:')[1]
assert '.font(.system(size: 24, weight: .bold))' in page_title
assert '.foregroundStyle(KKColor.textPrimary)' in page_title
assert '.accessibilityAddTraits(.isHeader)' in page_title
assert main.count('.system(size: 24, weight: .bold)') == 0

# Production row guard and both production height consumers share the tested policy.
# R13 routes the same mode/current flags through the shared row policy.
row = panel.split('private func captionRow(')[1].split('private func copyFeedbackID(', 1)[0]
assert 'let text = CaptionHierarchy.row(source: chunk.displaySource, translation: chunk.displayTranslation,' in row
assert 'current: current, showTranslation: state.showTranslation, showSource: state.showSource)' in row
policy = read('CaptionIsland.swift').split('static func row(', 1)[1].split('static func showsSource(', 1)[0]
assert 'if !showTranslation { return CaptionRowText(primary: source, secondary: nil, placeholder: false) }' in policy
assert 'return CaptionRowText(primary: translation,' in policy
assert 'secondary: current && showSource && !source.isEmpty ? source : nil, placeholder: false)' in policy
assert 'historyLineHeight(showTranslation:' in read('CaptionIsland.swift')
assert 'CaptionState.shared.islandHeight' in read('IslandNotch.swift')
assert 'height: Double(islandHeightCap)' in panel
pending = panel.split('if hasPending {', 1)[1].split('private var scale:', 1)[0]
assert 'let text = CaptionHierarchy.row(source: state.pendingEn, translation: state.pendingDraft,' in pending
assert 'waiting: !state.translationPaused && (state.running || state.starting || state.finishingCaptions),' in pending
assert 'current: true, showTranslation: state.showTranslation, showSource: state.showSource)' in pending
assert 'if translation.isEmpty {' in policy
assert 'let placeholder = waiting && !showSource' in policy
assert 'return CaptionRowText(primary: placeholder ? "…" : source, secondary: nil, placeholder: placeholder)' in policy
assert pending.index('Text(text.primary)') < pending.index('if let secondary = text.secondary') < pending.index('Text(secondary)')
assert row.index('Text(text.primary)') < row.index('if let secondary = text.secondary') < row.index('Text(secondary)')
assert '历史显示原文' not in main

# R11: hit geometry remains in Button artwork; focus is on the actual native Button.
for name in ['KKFilledButtonArtwork', 'KKQuietButtonArtwork', 'KKPlainButtonArtwork']:
    style = tokens.split(f'struct {name}:')[1].split('\n}\n', 1)[0]
    assert '.frame(minWidth: 28, minHeight: 28)' in style, name
    assert '.contentShape(' in style, name
assert 'Button(configuration)' in tokens and '.kkFocusRing(radius: radius)' in tokens
ring = tokens.split('private struct KKFocusRing:')[1].split('\n}\n', 1)[0]
assert '@FocusState private var focused: Bool' in ring
assert 'content.focused($focused).focusEffectDisabled()' in ring
assert 'KKFocusOutline(active: focused, radius: radius)' in ring
assert 'KKKeyboardFocusCoordinator' not in tokens
assert 'static let ringWidth: CGFloat = 2' in tokens and 'static let gap: CGFloat = 2' in tokens
segments = tokens.split('struct KKSegmentedPicker')[1].split('extension Text', 1)[0]
assert 'minWidth: 28, maxWidth: .infinity, minHeight: 28' in segments
assert '.buttonStyle(KKPlainButtonStyle(radius: 5))' in segments
assert '.accessibilityAddTraits(selected ? .isSelected : [])' in segments
assert '.accessibilityElement(children: .contain).accessibilityLabel(title)' in segments
assert 'KKSegmentedPicker(title: ""' not in read('IslandSettings.swift')

# Enumerate icon-only button labels with balanced braces, including multiline trash.
def end_brace(source, start):
    depth = 1
    for i in range(start + 1, len(source)):
        depth += (source[i] == '{') - (source[i] == '}')
        if depth == 0:
            return i
    raise AssertionError('unbalanced Button label')

icons = []
for path in sorted(root.glob('*.swift')):
    source = path.read_text()
    # Only scroll containers may opt out; no button/link/control can lose focus.
    scroll_ends = set()
    for scroll in re.finditer(r'\bScrollView\s*\{', source):
        brace = source.index('{', scroll.start())
        scroll_ends.add(end_brace(source, brace) + 1)
    for optout in re.finditer(r'\.focusable\(false\)', source):
        assert optout.start() in scroll_ends, path
    assert '.buttonStyle(.plain)' not in source, path
    assert '.buttonStyle(.link)' not in source, path
    for match in re.finditer(r'\bButton\b[^\n]*|\bButton\b', source):
        # Button declarations with a trailing label; no text constructor or addButton.
        start = match.start()
        if not re.match(r'Button(?:\s*\{|\(action:)', source[start:]):
            continue
        brace = source.find('{', start)
        action_end = end_brace(source, brace)
        if source[action_end + 1:].lstrip().startswith('label:'):
            label_start = source.index('{', action_end + 1)
        elif source[start:brace].startswith('Button(action:'):
            label_start = brace
        else:
            continue
        label_end = end_brace(source, label_start)
        label = source[label_start:label_end]
        if 'Image(systemName:' not in label or re.search(r'\b(?:Text|Label)\(', label):
            continue
        modifiers = source[label_end + 1:].split('\n', 7)[:7]
        modifiers = '\n'.join(modifiers)
        assert '.accessibilityLabel(' in modifiers, (path, label)
        if path.name == 'CaptionPanel.swift' and 'Image(systemName: "xmark")' not in label:
            toolbar = source.split('private var toolbar:')[1].split('var body:', 1)[0]
            assert '.buttonStyle(KKPlainButtonStyle())' in toolbar
        elif path.name == 'HomeCaptionPreview.swift':
            assert '.buttonStyle(KKQuietButtonStyle())' in modifiers
        else:
            assert '.buttonStyle(KKPlainButtonStyle())' in modifiers, (path, label)
        icons.append((path.name, label.strip(), modifiers))
# R12 moved the row trash action to a mouse/AX-only NSButton so the list is one Tab stop.
# R15 F splits the gear into mutually exclusive island/menu and desktop/popover buttons.
# Spec line 363: status lines have no close xmark; the banner xmark was removed.
assert len(icons) == 10, [(name, label) for name, label, _ in icons]
assert len([label for name, label, _ in icons if name == 'DesignTokens.swift' and 'sidebar.left' in label]) == 1
trash = main.split('private struct TranscriptTrashButton:')[1].split('private struct TranscriptRow:', 1)[0]
assert 'override var acceptsFirstResponder: Bool { false }' in trash
assert 'button.setAccessibilityLabel(tr("删除"))' in trash
assert 'button.refusesFirstResponder = true' in trash
assert '.onDeleteCommand' in main
assert '.focused($toolbarFocus, equals:' in panel
assert 'toolbarFocus != nil ? 1 : 0' in panel
menu = read('App.swift')
assert '.focused($primaryFocused)' in menu and '.defaultFocus($primaryFocused, true)' in menu
assert '.onChange(of: isPresented)' in menu
assert 'primaryFocused = presented' in menu
print('PASS r4 wiring: six shared headings; source/history policy; 28pt custom controls; focus ring; named groups; icon inventory; keyboard reveal and menu initial focus')
for name, label, _ in icons:
    print(f'  icon audit: {name}: {label.splitlines()[0]}')

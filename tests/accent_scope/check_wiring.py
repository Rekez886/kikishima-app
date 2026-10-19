"""Audit production control scopes without launching Kikishima or loading app state."""
from pathlib import Path
import re

ROOT = Path('Sources/Kikishima')


def code(source):
    # Preserve offsets while ignoring strings and comments during delimiter matching.
    return re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"',
                  lambda m: ' ' * len(m[0]), source)


def end(mask, start):
    pairs = {'(': ')', '{': '}', '[': ']'}
    stack = [pairs[mask[start]]]
    for i in range(start + 1, len(mask)):
        if mask[i] in pairs:
            stack.append(pairs[mask[i]])
        elif mask[i] == stack[-1]:
            stack.pop()
            if not stack:
                return i + 1
    raise AssertionError('unbalanced Swift control')


def modifiers(source, offset):
    mask = code(source)
    result = ''
    while True:
        match = re.match(r'\s*\.\w+\s*[({]', mask[offset:])
        if not match:
            return result
        start = offset + match.end() - 1
        stop = end(mask, start)
        result += source[offset:stop]
        offset = stop


def audit(sources):
    tokens = sources['DesignTokens.swift']
    for name, source in sources.items():
        assert 'kkBrandAccent' not in code(source), name
        assert not re.search(r'\.accentColor\(\s*KKColor\.brand\s*\)', code(source)), name
        assert not re.search(r'\.tint\(\s*KKColor\.brand\s*\)', code(source)), (name, 'brand tint remains')
        if name != 'DesignTokens.swift':
            for match in re.finditer(r'\bToggle\s*\(', code(source)):
                stop = end(code(source), match.end() - 1)
                chain = modifiers(source, stop)
                assert '.toggleStyle(KKSwitchToggleStyle())' in chain, (name, 'Toggle missing grayscale style')
    assert 'self.tint(KKColor.textSecondary).accentColor(KKColor.textSecondary)' in tokens
    roots = ['MainWindow.swift', 'App.swift', 'Onboarding.swift', 'HomeCaptionPreview.swift', 'IslandSettings.swift']
    for name in roots:
        assert '.kkNeutralControls()' in sources[name], name
    main = sources['MainWindow.swift']
    split = re.search(r'\bNavigationSplitView(?:\([^\n]*\))?\s*\{', code(main)).end() - 1
    sidebar_end = end(code(main), split)
    detail = code(main).index('{', sidebar_end)
    detail_end = end(code(main), detail)
    chain = modifiers(main, detail_end)
    assert '.kkNeutralControls()' in chain
    assert '.buttonStyle(KKQuietButtonStyle())' not in chain, 'toolbar inherits brand ButtonStyle'
    assert '.buttonStyle(KKQuietButtonStyle())' in main[detail:detail_end], 'text actions lost quiet style'
    assert '.foregroundStyle(KKColor.textPrimary)' in main
    assert '.background(selection == section ? KKColor.surfaceSelected : Color.clear,' in main
    assert 'Label(tr(section.rawValue), systemImage: section.icon)\n                            .foregroundStyle(KKColor.textPrimary)' in main
    assert 'List(selection:' not in main
    # Menu/Picker buttons must not inherit the text-action ButtonStyle.
    counts = {'Toggle': 0, 'Picker': 0, 'Menu': 0}
    for name, source in sources.items():
        mask = code(source)
        for match in re.finditer(r'\b(Toggle|Picker|Menu)\s*\(', mask):
            kind = match[1]
            counts[kind] += 1
            if kind == 'Toggle':
                continue
            stop = end(mask, match.end() - 1)
            next_nonspace = stop + len(mask[stop:]) - len(mask[stop:].lstrip())
            if mask[next_nonspace:next_nonspace+1] == '{':
                stop = end(mask, next_nonspace)
            assert '.buttonStyle(.automatic)' in modifiers(source, stop), (name, kind)
    assert counts == {'Toggle': 12, 'Picker': 7, 'Menu': 3}, counts  # remove detached home/semantic-only Toggle copies; all 12 real call sites remain.
    assert 'Toggle(tr("紧凑字幕"), isOn: $state.compactCaptions).toggleStyle(KKSwitchToggleStyle())' in sources['App.swift']
    # Non-allowlisted explicit orange was audited as well as inherited tint.
    assert 'KKColor.brand' not in code(sources['CalendarViews.swift'])
    language_source = sources['OnboardingComponents.swift']
    language_start = language_source.index('struct LanguageChoiceTile:')
    language_end = end(code(language_source), code(language_source).index('{', language_start))
    language = language_source[language_start:language_end]
    onboarding = sources['Onboarding.swift']
    card_start = onboarding.index('                    Button {', onboarding.index('struct MeetingLanguagesPage:'))
    card_end = onboarding.index('.help(localeName(id))', card_start) + len('.help(localeName(id))')
    meeting_card = onboarding[card_start:card_end]
    for card, selected in [(language, 'selected'), (meeting_card, 'on')]:
        assert 'KKColor.brand' not in code(card), 'language card uses brand'
        assert '.foregroundStyle(KKColor.textPrimary)' in card
        assert f'.background({selected} ? KKColor.surfaceSelected : KKColor.surfaceRaised,' in card
        assert f'.strokeBorder(KKColor.textPrimary.opacity({selected} ? 1 : 0), lineWidth: 1)' in card
        assert '.buttonStyle(KKPlainButtonStyle(radius: 8))' in card
        assert f'.accessibilityAddTraits({selected} ? [.isSelected] : [])' in card
    assert 'Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? KKColor.textPrimary : KKColor.textSecondary)' in meeting_card
    # Uses one uninstalled representation, with no native colored progress.
    assert 'ProgressView' not in meeting_card
    assert 'Text(tr("需下载"))' in meeting_card
    assert 'Image(systemName: "checkmark.circle.fill")' in meeting_card
    # Every shared segment and secondary action stays grayscale.
    def declaration(source, signature):
        start = source.index(signature)
        return source[start:end(code(source), code(source).index('{', start))]

    segments = declaration(tokens, 'struct KKSegmentedPicker')
    assert 'KKColor.brand' not in code(segments)
    assert '.foregroundStyle(selected ? KKColor.textPrimary : KKColor.textSecondary)' in segments
    assert '.background(selected ? KKColor.surfaceSelected : KKColor.surfaceRaised,' in segments
    assert '.strokeBorder(KKColor.textPrimary.opacity(selected ? 1 : 0), lineWidth: 1)' in segments
    assert '.accessibilityAddTraits(selected ? .isSelected : [])' in segments
    quiet = declaration(tokens, 'private struct KKQuietButtonArtwork')
    assert '.foregroundStyle(KKColor.brand)' not in quiet
    assert '.foregroundStyle(KKColor.textPrimary)' in quiet
    assert '.background(KKColor.surfaceRaised,' in quiet
    assert 'artwork: KKQuietButtonArtwork(), radius: 6' in declaration(tokens, 'struct KKQuietButtonStyle:')
    sidebar = sources['SidebarAccountCard.swift']
    assert '.foregroundStyle(KKColor.brand)' not in sidebar
    logout = declaration(sidebar, 'private var logout:')
    assert '.buttonStyle(KKLinkButtonStyle())' in logout
    assert '.background(' not in logout
    assert sidebar.count('                        logout') == 1
    assert '                logout' in sidebar.split('case .pro:')[1]
    assert '.underline()' not in sidebar and '.underline()' not in main
    # Check the exact Button modifier chain, including multiline actions/labels.
    for name, titles in {
        'MainWindow.swift': ['更多语言…', '刷新订阅状态', '退出登录', '授予权限', '重新运行首次引导'],
        'SidebarAccountCard.swift': ['有邀请码？在这里兑换', '退出登录'],
        'CalendarViews.swift': ['允许访问', '允许访问日历'],
        'MeetingSummaryView.swift': ['打开原始记录'],
    }.items():
        source = sources[name]
        mask = code(source)
        for title in titles:
            label = source.index(f'tr("{title}")')
            start = list(re.finditer(r'\bButton\b', mask[:label]))[-1].start()
            opening = mask.index('(', start) if mask[start + 6:].lstrip().startswith('(') else mask.index('{', start)
            stop = end(mask, opening)
            while True:
                next_part = mask[stop:].lstrip()
                if next_part.startswith('{'):
                    stop = end(mask, mask.index('{', stop))
                elif next_part.startswith('label:'):
                    stop = end(mask, mask.index('{', stop))
                else:
                    break
            assert '.buttonStyle(KKLinkButtonStyle())' in modifiers(source, stop), (name, title)
    # Destructive intent stays in the confirmation; toolbar artwork stays gray.
    history = declaration(main, 'struct HistoryView:')
    toolbar = history.split('var body: some View {', 1)[1].split('TextField(', 1)[0]
    assert 'Label(tr("删除所选"), systemImage: "trash")' in toolbar
    assert '.foregroundStyle(KKColor.textPrimary)' in toolbar.split('Label(tr("删除所选")', 1)[1].split('Button(tr("打开文件夹"))', 1)[0]
    assert '.buttonStyle(KKQuietButtonStyle())' in toolbar.split('Label(tr("删除所选")', 1)[1].split('Button(tr("打开文件夹"))', 1)[0]
    assert 'requestDeletion(selectedFiles)' in toolbar and '.disabled(selectedFiles.isEmpty)' in toolbar
    for forbidden in ['KKColor.error', 'KKColor.warning', 'KKColor.brand', '.red', '.orange']:
        assert forbidden not in code(toolbar), forbidden
    folder_buttons = list(re.finditer(re.escape('Button(tr("打开文件夹"))'), main))
    assert len(folder_buttons) == 2
    for match in folder_buttons:
        stop = end(code(main), code(main).index('{', match.end()))
        chain = modifiers(main, stop)
        assert '.buttonStyle(KKQuietButtonStyle())' in chain
        assert '.foregroundStyle(KKColor.textPrimary)' in chain
        for forbidden in ['KKColor.error', 'KKColor.warning', 'KKColor.brand', '.red', '.orange']:
            assert forbidden not in chain, forbidden
    assert 'Button(tr("删除"), role: .destructive) { delete(pendingDeletions) }' in history
    assert 'Button(tr("取消"), role: .cancel) {}' in history
    switch = declaration(tokens, 'struct KKSwitchToggleStyle:')
    native = declaration(tokens, 'final class KKNativeSwitch:')
    host = declaration(tokens, 'private struct KKNativeSwitchHost:')
    assert 'state == .on ? KKColor.textPrimary : KKColor.textTertiary' in native
    assert 'NSColor(KKColor.surfaceBase).setFill()' in native
    assert 'changed(state == .on)' in native and 'view.changed = { isOn = $0 }' in host
    assert '@Environment(\\.controlSize)' in switch and 'case .small:' in switch
    assert 'KKNativeSwitchHost(' in switch and 'NSSwitch' in native
    assert '.accessibilityRepresentation' not in switch
    assert 'override func accessibilityFrame()' not in tokens and 'setAccessibilityFrame' not in tokens
    assert 'addSubview(label)' in native and 'let body = switchBodyRect' in native
    assert 'if hasKeyboardFocus {' in native and 'path.lineWidth = KKFocusGeometry.ringWidth' in native
    link = declaration(tokens, 'private struct KKLinkButtonLabel')
    for expected in ['.foregroundStyle(KKColor.textSecondary)', '.underline(hovering && enabled)',
                     '.onHover { hovering = $0 }', '.frame(minWidth: 28, minHeight: 28)']:
        assert expected in link, expected
    assert '.background(' not in link
    ring = declaration(tokens, 'private struct KKFocusRing:')
    assert 'content.focused($focused).focusEffectDisabled()' in ring
    assert 'KKFocusOutline(active: focused, radius: radius)' in ring
    outline = declaration(tokens, 'struct KKFocusOutline:')
    assert '.stroke(KKColor.focusRing, lineWidth: KKFocusGeometry.ringWidth)' in outline
    assert 'static let ringWidth: CGFloat = 2' in tokens
    assert 'KKSystemFocusButton(' in declaration(tokens, 'struct KKLinkButtonStyle:')
    assert 'KKColor.brand' not in code(sources['MeetingSummaryView.swift'])

    # Each remaining brand reference has one approved local use, including aliases.
    approved = {
        'DesignTokens.swift': [r'\.background\(active \? KKColor\.surfaceRaised : KKColor\.brand,', r'\.strokeBorder\(KKColor\.brand, lineWidth: 2\)'],
        'SidebarAccountCard.swift': [r'private var brand: Color \{ KKColor\.brand \}'],
        'App.swift': [r'private var brandRed: Color \{ KKColor\.brand \}'],
        'HomeCaptionPreview.swift': [r'Rectangle\(\)\.fill\(KKColor\.brand\)'],
        'CaptionPanel.swift': [r'Rectangle\(\)\.fill\(KKColor\.brand\)'],
        'IslandNotch.swift': [r'\.fill\(state\.silentTooLong \? KKColor\.warning : state\.running && !state\.paused \? KKColor\.brand : KKColor\.textTertiary\)', r'\.changeEffect\(\.glow\(color: KKColor\.brand, radius: 8\), value: state\.running\)'],
    }
    for name, source in sources.items():
        mask = code(source)
        allowed = set()
        for pattern in approved.get(name, []):
            for match in re.finditer(pattern, mask):
                allowed.update(range(match.start(), match.end()))
        for match in re.finditer(r'KKColor\.brand\b', mask):
            assert match.start() in allowed, (name, 'unapproved brand use', source[:match.start()].count('\n') + 1)
    assert '.background(brand, in:' in sidebar
    assert sources['App.swift'].count('brandRed') == 3
    assert 'Circle().fill(brand)' not in sources['SidebarAccountCard.swift']
    assert 'Circle().fill(KKColor.brand)' not in main
    assert '.background(KKColor.brand' not in sources['MeetingSummaryView.swift']
    return counts


def control_contrast(tokens):
    def rgb(name, dark):
        line = next(line for line in tokens.splitlines() if f'static let {name} =' in line)
        value = int(re.search(rf'{"dark" if dark else "light"}: 0x([0-9A-F]+)', line)[1], 16)
        return [(value >> shift & 255) / 255 for shift in [16, 8, 0]]

    def luminance(channels):
        return sum((c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4) * weight
                   for c, weight in zip(channels, [0.2126, 0.7152, 0.0722]))

    def contrast(a, b):
        low, high = sorted([luminance(a), luminance(b)])
        return (high + 0.05) / (low + 0.05)

    for dark in [False, True]:
        for track in ['textPrimary', 'textTertiary']:
            for surface in ['surfaceBase', 'surfaceRaised']:
                ratio = contrast(rgb(track, dark), rgb(surface, dark))
                assert ratio >= 3, (dark, track, surface, ratio)
        ratio = contrast(rgb('textTertiary', dark), rgb('surfaceBase', dark))
        print(f'PASS {"dark" if dark else "light"} switch off-track/base and thumb/off-track contrast: {ratio:.2f}:1')


sources = {p.name: p.read_text() for p in ROOT.glob('*.swift')}
counts = audit(sources)
control_contrast(sources["DesignTokens.swift"])
# Prove the audit rejects regressions, rather than only passing HEAD.
mutations = [
    ('MainWindow.swift', 'Label(tr("删除所选"), systemImage: "trash")\n                        .foregroundStyle(KKColor.textPrimary)', 'Label(tr("删除所选"), systemImage: "trash")\n                        .foregroundStyle(KKColor.error)'),
    ('MainWindow.swift', '}.buttonStyle(KKQuietButtonStyle()).foregroundStyle(KKColor.textPrimary)', '}.buttonStyle(KKQuietButtonStyle()).foregroundStyle(KKColor.warning)'),
    ('MeetingSummaryView.swift', '.buttonStyle(KKLinkButtonStyle())', '.buttonStyle(KKQuietButtonStyle())'),
    ('DesignTokens.swift', 'state == .on ? KKColor.textPrimary : KKColor.textTertiary', 'state == .on ? KKColor.textPrimary : KKColor.surfaceRaised'),
    ('DesignTokens.swift', 'changed(state == .on)', 'changed(true)'),
    ('DesignTokens.swift', 'let body = switchBodyRect', 'let body = bounds'),
    ('DesignTokens.swift', '.onHover { hovering = $0 }', '.onHover { hovering = false }'),
    ('MainWindow.swift', '.buttonStyle(KKLinkButtonStyle())', '.buttonStyle(KKQuietButtonStyle())'),
    ('CalendarViews.swift', '.buttonStyle(KKLinkButtonStyle())', '.buttonStyle(KKQuietButtonStyle())'),
    ('DesignTokens.swift', 'selected ? KKColor.surfaceSelected', 'selected ? KKColor.brand'),
    ('DesignTokens.swift', 'selected ? KKColor.textPrimary : KKColor.textSecondary', 'selected ? KKColor.brandOn : KKColor.textSecondary'),
    ('DesignTokens.swift', 'configuration.label.foregroundStyle(KKColor.textPrimary)', 'configuration.label.foregroundStyle(KKColor.brand)'),
    ('SidebarAccountCard.swift', '}.buttonStyle(KKLinkButtonStyle())', '}.buttonStyle(KKQuietButtonStyle())'),
    ('DesignTokens.swift', '.underline(hovering && enabled)', '.underline()'),
    ('MainWindow.swift', 'selection == section ? KKColor.surfaceSelected', 'selection == section ? KKColor.brand'),
    ('MainWindow.swift', 'Label(tr(section.rawValue), systemImage: section.icon)\n                            .foregroundStyle(KKColor.textPrimary)', 'Label(tr(section.rawValue), systemImage: section.icon)\n                            .foregroundStyle(KKColor.brandOn)'),
    ('MeetingSummaryView.swift', '.foregroundStyle(KKColor.textPrimary)', '.foregroundStyle(KKColor.brand)'),
    ('MainWindow.swift', '.kkNeutralControls()', '.accentColor(KKColor.brand)'),
    ('MainWindow.swift', '.kkNeutralControls()', '.buttonStyle(KKQuietButtonStyle()).kkNeutralControls()'),
    ('HomeCaptionPreview.swift', '.toggleStyle(KKSwitchToggleStyle())', '.toggleStyle(.switch)'),
    ('App.swift', '}.kkFocusRing().buttonStyle(.automatic)', '}.kkFocusRing()'),
    ('OnboardingComponents.swift', 'selected ? KKColor.surfaceSelected', 'selected ? KKColor.brand'),
    ('OnboardingComponents.swift', 'opacity(selected ? 1 : 0)', 'opacity(selected ? 0 : 0.1)'),
    ('Onboarding.swift', 'on ? KKColor.surfaceSelected', 'on ? KKColor.brand'),
    ('Onboarding.swift', 'opacity(on ? 1 : 0)', 'opacity(on ? 0 : 0.1)'),
    ('Onboarding.swift', 'on ? KKColor.textPrimary : KKColor.textSecondary', 'on ? KKColor.brand : KKColor.textSecondary'),
    ('Onboarding.swift', '.accessibilityAddTraits(on ? [.isSelected] : [])', '.tint(KKColor.brand)'),
]
for name, old, new in mutations:
    mutated = dict(sources)
    assert old in mutated[name], (name, old)
    mutated[name] = mutated[name].replace(old, new, 1)
    try:
        audit(mutated)
    except AssertionError:
        pass
    else:
        raise AssertionError(('regression escaped', name, old))
home = Path('tools/home_preview/main.swift').read_text()
onboarding_preview = Path('tools/onboarding_preview/main.swift').read_text()
assert 'Text(variant == 0 ? tr("就绪") : tr("暂停字幕")).font(.system(size: 13)).foregroundStyle(KKColor.textSecondary)' in home
assert 'Text("\\([1, 2, 5, 6, 4, 5][variant]) / 6").font(.caption).foregroundStyle(KKColor.textTertiary)' in onboarding_preview
assert 'Button(tr("上一步")) {}.buttonStyle(KKQuietButtonStyle())' in onboarding_preview
for title in ['下一步', '现在就试一下（开始字幕）']:
    assert f'Button(tr("{title}")) {{}}.kkPrimaryButton()' in onboarding_preview
assert '.borderedProminent' not in onboarding_preview
print(f'PASS accent scope: gray roots/toolbar/language cards, local switches, native menus/pickers, explicit-color audit; {counts}; {len(mutations)} regression probes')

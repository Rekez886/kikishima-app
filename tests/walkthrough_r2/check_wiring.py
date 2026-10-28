from pathlib import Path
r = Path('Sources/Kikishima')
read = lambda name: (r / name).read_text()
tokens = read('DesignTokens.swift')
assert 'self.buttonStyle(KKFilledButtonStyle(active: false))' in tokens
assert 'active ? KKColor.textPrimary : KKColor.brandOn' in tokens
assert 'selected ? KKColor.textPrimary : KKColor.textSecondary' in tokens
assert 'selected ? KKColor.surfaceSelected : KKColor.surfaceRaised' in tokens
assert '.background(KKColor.surfaceRaised' in tokens

def block(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

# r8 native segments are semantic-only; the visible artwork remains token based.
semantic = block(read('MainWindow.swift'), 'struct CaptionSegmentAccessibility<')
assert '.pickerStyle(.segmented)' in semantic
for name in ['MainWindow.swift', 'App.swift']:
    source = read(name).replace(semantic, '')
    import re
    representations = [block(source[match.start():], '.accessibilityRepresentation')
                       for match in re.finditer(r'\.accessibilityRepresentation\s*\{', source)]
    assert source.count('CaptionSegmentAccessibility(') == sum(part.count('CaptionSegmentAccessibility(') for part in representations)
for p in r.glob('*.swift'):
    # BrandIcons draws approved brand assets, outside the UI color-token audit.
    if p.name in {'DesignTokens.swift', 'BrandIcons.swift'}: continue
    source = p.read_text().replace(semantic, '')
    for forbidden in ['.pickerStyle(.segmented)', '.foregroundStyle(.secondary)', '.foregroundStyle(.tertiary)', 'Color.orange', '.foregroundStyle(.orange)', 'Color(red:', 'NSColor(srgbRed:', '.tint(.blue)', 'Color.accentColor']:
        assert forbidden not in source, (p, forbidden)
main = read('MainWindow.swift')
assert 'SidebarNavigation(selection: $state.mainSection)' in main
assert 'Label(tr(section.rawValue), systemImage: section.icon)\n                            .foregroundStyle(KKColor.textPrimary)' in main
assert '.background(selection == section ? KKColor.surfaceSelected : Color.clear,' in main
assert 'List(selection:' not in main
assert 'Text(tr("更多语言…"))' in main
assert '.buttonStyle(KKLinkButtonStyle())' in main.split('Text(tr("更多语言…"))')[1].split('\n', 2)[1]
assert 'KKColor.textTertiary.opacity(0.9)' in main
menu = read('App.swift')
assert '.background(KKColor.surfaceBase)' in menu
panel = read('CaptionPanel.swift')
assert 'ScrollView(.vertical) { captionRows }' in panel
assert '.lineLimit(current ? nil : 1)' in panel
assert 'CaptionReadingPolicy.islandLayout(' in panel
assert 'Rectangle().fill(KKColor.brand).frame(width: 2)' in panel
assert 'if current { Rectangle().fill(KKColor.brand).frame(width: 2) }' in panel
assert 'hasPending ? limit : limit + 1' in panel
assert 'CaptionHierarchy.desktopHistoryCount(' in panel
# R11 retains the hierarchy, with a contrast floor for historical ink.
assert '.opacity(current || chunk.zh.isEmpty ? 1 : max(CaptionOpacityPolicy.minimumHistoryInkOpacity, CaptionHierarchy.opacity(age: age)))' in panel
# R13: only the waiting placeholder is tertiary; source fallback is readable primary ink.
assert '.foregroundStyle(text.placeholder ? KKColor.textTertiary : chunk.zh.isEmpty || current ? KKColor.textPrimary : KKColor.historyInk)' in block(panel, 'private func captionRow(')
row_policy = block(read('CaptionIsland.swift'), 'static func row(')
assert 'let placeholder = waiting && !showSource' in row_policy
assert 'return CaptionRowText(primary: placeholder ? "…" : source, secondary: nil, placeholder: placeholder)' in row_policy
assert 'lineHeight: (current ? 24 : 21) * scale' in panel
assert 'lineHeight: 18 * scale' in panel
helper = Path('Sources/Kikishima/CaptionErrorStatus.swift').read_text().split('enum CaptionTitlebarAccessory {', 1)[1]
assert 'CaptionTitlebarAccessory.install(on: p, view: titlebarHost, titlebarHeight: titlebarHeight)' in panel.split('if !compact {', 1)[1]
assert 'addTitlebarAccessoryViewController' not in panel
assert helper.index('view.frame = NSRect(') < helper.index('accessory.layoutAttribute = .right') < helper.index('window.addTitlebarAccessoryViewController(accessory)')
assert 'width: CaptionDesktopStatusLayout.toolbarWidth' in helper and 'height: titlebarHeight)' in helper
assert ('.overlay(alignment: .topTrailing)' not in panel
        and 'CaptionTitlebarAccessory.install(on: p, view: titlebarHost, titlebarHeight: titlebarHeight)' in panel
        and '.fullSizeContentView' not in panel
        and 'compactStatusHeader' in panel
        and '.frame(height: CaptionDesktopStatusLayout.compactHeaderHeight)' in panel
        and 'layout.status.width' in panel and 'layout.toolbar.width' in panel
        and '.opacity(desktopToolbarVisible ? 1 : 0)' in panel)
assert '.onChange(of: size) { CaptionPanelController.shared.resizeIslandToContent() }' in read('IslandNotch.swift')
assert 'KKSpace.five - hostSideInset' in panel
# P1 #4: only desktop captions inherit system appearance.
assert '.environment(\\.colorScheme, .dark)' in panel
assert 'p.appearance = island ? NSAppearance(named: .darkAqua) : nil' in panel
assert 'CaptionIslandLayout.compactWidth(notchWidth: notchWidth) - 30' in read('IslandNotch.swift') # + host 30 = 240pt compact capsule
print('PASS r2 wiring: opaque token controls/panel, no visible native segments/system blues/hardcoded orange, bounded feed and current-only rail')

def rgb(value):
    return [(value >> shift & 255) / 255 for shift in [16, 8, 0]]
def luminance(channels):
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return sum(c * w for c, w in zip(linear, [0.2126, 0.7152, 0.0722]))
def contrast(fg, bg):
    a, b = sorted([luminance(fg), luminance(bg)])
    return (b + 0.05) / (a + 0.05)
for foreground, background in [(0x151515, 0xF2603D), (0xFFFFFF, 0xC8401F), (0xC8401F, 0xF7F7F8), (0xF2603D, 0x202123), (0x6B6B70, 0xFFFFFF), (0x6B6B70, 0xF7F7F8), (0x8A8A8A, 0x202123)]:
    assert contrast(rgb(foreground), rgb(background)) >= 4.5, (hex(foreground), hex(background))
for text, surface in [(0x6B6B70, 0xF7F7F8), (0x8A8A8A, 0x202123)]:
    blended = [0.9 * a + 0.1 * b for a, b in zip(rgb(text), rgb(surface))]
    assert contrast(blended, rgb(surface)) >= 3
print('PASS r2 contrast: CTA, quiet buttons, tertiary on both surfaces >= 4.5; disabled text >= 3')

# P1 #4: island hosts and feed use the dark palette; R15 F removes the island settings popover.
island = read('IslandNotch.swift')
assert 'w.appearance = nil' not in island
assert 'w.appearance = NSAppearance(named: .darkAqua)' in island
assert '.environment(\\.colorScheme, .dark)' in island
assert panel.count('p.appearance = island ? NSAppearance(named: .darkAqua) : nil') == 2
assert panel.count('if isIsland || hostedInNotch { scheme = .dark }') == 1
assert 'NSColor(KKColor.notchBackground)' not in panel
assert panel.count('NSColor(KKColor.captionWindowBackground).withAlphaComponent(s.captionOpacity)') == 2
assert '(isIsland ? KKColor.notchBackground : KKColor.captionWindowBackground).opacity(state.captionOpacity)' in panel
# P1 #13: island icons live directly on the fixed-dark header; only the
# unchanged desktop toolbar retains its translucent capsule chrome.
toolbar = panel.split('private var toolbar: some View')[1].split('private var toolbarButtons:')[0]
assert 'if toolbarMode == .island' in toolbar
assert '.buttonStyle(IslandToolbarButtonStyle())' in toolbar.split('} else {')[0]
assert '.background(Capsule().fill(KKColor.captionWindowBackground.opacity(0.55)))' in toolbar.split('} else {')[1]
preview = read('HomeCaptionPreview.swift')
assert 'desktop ? KKColor.captionWindowBackground : KKColor.notchBackground' in preview
assert '.environment(\\.colorScheme, .dark)' in preview
vendor = Path('Vendor/DynamicNotchKit/Sources/DynamicNotchKit/Views')
notchless = (vendor / 'NotchlessView.swift').read_text()
assert 'private let ink = Color.black' in notchless
assert '.background { panelShape.fill(ink) }' in notchless
assert '.environment(\\.colorScheme, .dark)' in notchless
assert '.foregroundStyle(.black)' in (vendor / 'NotchView.swift').read_text()
print('PASS P1 #4: fixed-dark island hosts and feed; desktop background preserved')

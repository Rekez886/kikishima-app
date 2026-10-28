"""Extract production model/actions; assert UI wiring without starting the app."""
from pathlib import Path
import ast
import json
import re
import sys

panel = Path('Sources/Kikishima/CaptionPanel.swift').read_text()
state = Path('Sources/Kikishima/CaptionState.swift').read_text()

def block(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

# Reproduce the actual a52f54e overlay path before requiring any new API.
# The old toolbar starts 8pt from the top; the banner's trailing close control
# starts at its 8pt vertical inset, 14pt from the right edge. Both are in the
# same content coordinate space. A 12pt close glyph is inside that toolbar.
if '.overlay(alignment: .topTrailing)' in panel:
    toolbar = block(panel, 'private var toolbar: some View')
    banner = panel.split('if let banner = state.errorBanner {', 1)[1].split('if state.paused', 1)[0]
    outer = float(re.search(r'\.padding\((\d+)\)', toolbar).group(1))
    horizontal, vertical = map(float, re.search(
        r'\.padding\(\.horizontal, (\d+)\)\.padding\(\.vertical, (\d+)\)', banner).groups())
    font = float(re.findall(r'\.font\(\.system\(size: (\d+)\)\)', toolbar)[-1])
    inner_y = float(re.search(r'\.padding\(\.vertical, (\d+)\)', toolbar).group(1))
    width = 360
    close = (width - horizontal - 12, vertical, width - horizontal, vertical + 12)
    # At least four 12pt glyphs plus the existing inter-button gaps and insets.
    toolbar_width = 4 * font + 3 * 6 + 2 * 8
    hover = (width - outer - toolbar_width, outer, width - outer, outer + font + 2 * inner_y)
    overlap = close[0] < hover[2] and hover[0] < close[2] and close[1] < hover[3] and hover[1] < close[3]
    print(f'Regression: close hit rect={close}, hover toolbar={hover}, overlap={overlap}', flush=True)
    assert not overlap, 'KK-034: error close hit area is covered by the hover toolbar'

helper_source = Path('Sources/Kikishima/CaptionErrorStatus.swift').read_text()
assert 'enum CaptionTitlebarAccessory {' in helper_source, (
    'KK-034 r5: missing sized accessory helper; baseline NSHostingView frame remains zero, '
    'so centered toolbar content extends past the window right edge')
helper = Path('Sources/Kikishima/CaptionErrorStatus.swift').read_text().split('enum CaptionTitlebarAccessory {', 1)[1]
assert 'CaptionTitlebarAccessory.install(on: p, view: titlebarHost, titlebarHeight: titlebarHeight)' in panel.split('if !compact {', 1)[1]
assert 'addTitlebarAccessoryViewController' not in panel
assert helper.index('view.frame = NSRect(') < helper.index('accessory.layoutAttribute = .right') < helper.index('window.addTitlebarAccessoryViewController(accessory)')
assert 'width: CaptionDesktopStatusLayout.toolbarWidth' in helper and 'height: titlebarHeight)' in helper

assert 'func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize' in panel, 'KK-034 r6: live resize has no delegate clamp after NSHostingView rewrites minSize'
resize = block(panel, 'func windowWillResize(')
assert 'else { return frameSize }' in resize
# The extracted method below exercises compact=true and island=true at runtime;
# do not replace it with an unconditional call to the resize helper.
assert 'return CaptionDesktopResizePolicy.constrained(frameSize)' in resize
assert 'p.delegate = self' in panel
programmatic = block(helper_source, 'class CaptionMinimumSizePanel:')
assert 'frame.size = CaptionDesktopResizePolicy.constrained(frame.size)' in programmatic
assert 'minSize.width' not in programmatic and 'minSize.height' not in programmatic
build = block(panel, 'private func build()')
assert panel.count('sizingOptions') == 1
assert 'islandHost.sizingOptions = []' in build
assert 'contentHost.sizingOptions' not in build and 'titlebarHost.sizingOptions' not in build
assert '.fullSizeContentView' not in panel
# Regression: title-bar chrome must expose the same translucent window background.
build = block(panel, 'private func build()')
assert 'p.titlebarAppearsTransparent = true' in build
background = 'p.backgroundColor = NSColor(KKColor.captionWindowBackground).withAlphaComponent(s.captionOpacity)'
assert background in build
appearance = block(panel, 'func applyAppearance()')
assert 'NSColor(KKColor.captionWindowBackground).withAlphaComponent(s.captionOpacity)' in appearance
host = block(panel, 'private final class CaptionTitlebarHostingView')
assert 'override var isOpaque: Bool { false }' in host
assert 'let titlebarHost = CaptionTitlebarHostingView(rootView: CaptionFeedView(' in build
assert '.background(Color.clear)' in build
assert 'titlebarHost.layer?.backgroundColor = NSColor.clear.cgColor' in build
assert 'accessory.view = view' in helper
assert 'NSVisualEffectView' not in host and '.background(' not in host
fast = '.timingCurve(0.2, 0, 0, 1, duration: 0.12)'
assert panel.count(fast) == 1
assert '.easeOut(duration: 0.15)' not in panel
assert fast in block(panel, 'private var compactStatusHeader: some View')
assert 'duration: toolbarMode == .island ? 0.2 : 0.12' in block(panel, 'private var content: some View')
header = block(panel, 'private var compactStatusHeader: some View')
assert '.frame(height: CaptionDesktopStatusLayout.compactHeaderHeight)' in header
assert 'compact: true' in header and 'leadingInset: KKSpace.five + KKSpace.three' in header
assert header.index('layout.status.width') < header.index('layout.toolbar.width')
assert '.offset(x: layout.status.minX)' in header and '.offset(x: layout.toolbar.minX)' in header
assert '.opacity(desktopToolbarVisible ? 1 : 0)' in header
assert 'if desktopToolbarVisible' not in header
assert '.clipped()' in header and '.contentShape(Rectangle())' in header
assert '.frame(height: CaptionDesktopStatusLayout.compactHeaderHeight - 10)' in block(panel, 'private var toolbar: some View')
feed = block(panel, 'private var feedBody: some View')
assert feed.index('compactStatusHeader') < feed.index('\n                    content')
assert 'toolbarMode == .captionWindow, state.compactCaptions' in feed
inline = block(panel, 'private func desktopStatusLine(')
assert 'CaptionStatusInlineLayout(lineHeight: state.compactCaptions ? 18 * scale : CaptionDesktopStatusLayout.statusRowHeight)' in inline
assert '.frame(height: CaptionDesktopStatusLayout.statusRowHeight)' in block(panel, 'private var content: some View')
assert '.padding(.top, KKSpace.one)' in block(panel, 'private var content: some View')
assert panel.count('p.minSize =') == 2
assert 'CaptionKeyboardPanel: CaptionMinimumSizePanel' in panel
assert panel.count('CaptionDesktopStatusLayout.minimumSize') == 2
for forbidden in ['.lineLimit(', '.truncationMode(', '.minimumScaleFactor(']:
    assert forbidden not in inline
assert '.help(banner.text).accessibilityLabel(banner.text)' in inline
assert 'Spacer' not in inline and 'xmark' not in inline
assert 'KKColor.error' in inline and 'state.captionFont(13 * scale)' in inline
assert 'bannerActionButton(banner, island: false)' in inline
bannerHelper = block(panel, 'private func bannerActionButton(')
assert 'state.performBanner(action)' in bannerHelper
assert 'CaptionStatusInlineGeometry(width: bounds.width' in panel
assert '.transition(.opacity)' in header and 'reduceMotion ? nil' in header
esc = block(panel, 'override func sendEvent(')
for required in ['isKeyWindow', 'event.keyCode == 53', '!CaptionState.shared.usesIslandCaptions',
                 'CaptionState.shared.dismissDesktopErrorStatus()', 'super.sendEvent(event)']:
    assert required in esc

# Capture error assignments use the production repair actions.
assignments = re.findall(r'errorBanner = CaptionBanner\(([^\n]+)\)', state)
expected = {
    '音频仍无法捕获：%@': 'retry',
    '无法继续：%@': 'retry',
    '没有「系统录音」权限，听不到会议声音。系统设置 › 隐私与安全性 › 屏幕录制与系统录音 里允许 Kikishima。': 'openSettings',
    '启动失败：%@': 'retry',
    '输出设备切换后无法继续捕获音频：%@': 'retry',
    '转写引擎反复中断：%@': 'retry',
    '转写引擎中断：%@': 'retry',
}
for text, action in expected.items():
    matches = [value for value in assignments if text in value]
    assert len(matches) == 1 and f'action: .{action}' in matches[0], (text, matches)
    assert 'severity: .info' not in matches[0]
for excluded in ['切换会议语言失败', '部分字幕未翻译完成', 'severity: .info']:
    assert all(excluded not in value for value in assignments)
failure = block(state, 'private func handleFailure(')
for name in ['network', 'server']:
    branch = failure.split(f'case .{name}', 1)[1].split('\n        case ', 1)[0]
    assert 'errorBanner =' not in branch
    assert 'status =' not in branch and 'tr(' not in branch and 'msg' not in branch
    assert 'translationFailed(chunk: chunk)' in branch
    connectivity = block(state, 'private func translationFailed(')
    assert 'updateTranslationConnectivity()' in connectivity
    assert 'translationConnectivity.failed(chunk: chunk, enabled: connectivityAvailable)' in connectivity
assert 'stop(reason: tr("切换会议语言失败，字幕已停止"))' in state
start = block(state, 'func start() -> Bool')
resolved = 'if errorBanner?.action == .retry || errorBanner?.action == .openSettings { errorBanner = nil }'
assert start.index('try startTap()') < start.index(resolved)

model = block(state, 'struct CaptionBanner:')
assert 'xmark' not in model and 'dismiss' not in model and 'close' not in model
# Five-language source table and generated outputs agree.
tree = ast.parse(Path('Resources/l10n/gen.py').read_text())
translations = next(ast.literal_eval(n.value) for n in tree.body
                    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'T' for t in n.targets))
assert '修复'.strip() and len(translations['修复']) == 4
for lang, value in zip(['zh-Hant', 'ja', 'en', 'ko'], translations['修复']):
    assert value.strip()
    assert json.loads(Path(f'Resources/l10n/{lang}.json').read_text())['修复'] == value

properties = state[state.index('    var errorBanner: CaptionBanner?'):state.index('    private var connectivityAvailable:')]
fixtures = """
import Foundation
func trAny(_ text: String) -> String { text }
func tr(_ text: String, _ args: CVarArg...) -> String { text }
final class StatusHost {
    var running = false
    var status = ""
    var paused = false, audioStalled = false, silentTooLong = false
    // PRODUCTION
}
"""
Path(sys.argv[1]).write_text(fixtures.replace('// PRODUCTION', properties) + '\n' + model)
print('PASS production wiring: native titlebar, fixed shared row, capture error assignments, Esc and five languages')

width = re.search(r'minimumSize = CGSize\(width: (\d+), height: 90\)', helper_source).group(1)
default = re.search(r'CaptionIslandLayout.idleMinWidth : (\d+)', panel).group(1)
Path(sys.argv[1]).with_name('Widths.txt').write_text(width + " " + default)

# Compile the exact production delegate method, including compact/island gates.
resize_fixture = """
import AppKit
@MainActor final class CaptionState {
    static let shared = CaptionState()
    var compactCaptions = false
}
@MainActor final class ResizeDelegate: NSObject, NSWindowDelegate {
    var usesIsland = false
""" + resize + """
}
@MainActor func configureResizePanel(_ p: CaptionMinimumSizePanel, island: Bool) {
""" + build.split('backing: .buffered, defer: false)', 1)[1].split('p.title =', 1)[0] + """
}
"""
Path(sys.argv[1]).with_name('ResizeDelegate.swift').write_text(resize_fixture)

# Runtime checks this source wiring after logging A and B, including on old archives.
sender_wiring = ('(sender as? CaptionMinimumSizePanel)?.isIslandPanel == false' in resize
                 and 'usesIsland' not in resize and 'CaptionState' not in resize)
with Path(sys.argv[1]).with_name('ResizeDelegate.swift').open('a') as generated:
    generated.write("\nlet resizeUsesBuiltWindow = " + str(sender_wiring).lower() + "\n")

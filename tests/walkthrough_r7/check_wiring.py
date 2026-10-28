"""Check production wiring and extract actual declarations for CLI-only verification.

No CaptionState initialization, GUI lifecycle, audio, installed-asset query, or app defaults.
"""
from pathlib import Path
import json
import re
import sys

root = Path('Sources/Kikishima')
read = lambda name: (root / name).read_text()

def block(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

main, onboarding, state, engine, app, tokens = map(read, [
    'MainWindow.swift', 'Onboarding.swift', 'CaptionState.swift', 'Transcribe.swift',
    'App.swift', 'DesignTokens.swift'])
meeting = block(onboarding, 'struct MeetingLanguagesPage:')
onboarding_root = block(onboarding, 'struct OnboardingView:')
assert 'GeometryReader' in onboarding_root and 'ScrollView {' in onboarding_root
assert onboarding_root.index('ScrollView {') < onboarding_root.index('case 2: MeetingLanguagesPage')
assert onboarding_root.index('.id(page)') < onboarding_root.index('Text("\\(page + 1) / \\(total)")')
assert 'ScrollView' not in meeting and '.frame(height: 210)' not in meeting
assert '.padding(.bottom, 16)' in meeting
assert '.fixedSize(horizontal: false, vertical: true)' in meeting
assert 'VStack(alignment: .leading, spacing: 6) {\n                Toggle(tr("选了就下载模型（建议在 Wi-Fi 下）")' in meeting

settings = block(main, 'struct SettingsPane:')
section = block(settings, 'Section(tr("字幕窗"))')
wrapper = block(settings, 'private func captionSetting<')
assert 'LabeledContent { content() } label:' in wrapper
for token in ['Text(title).foregroundStyle(KKColor.textPrimary)',
              '.accessibilityElement(children: .contain)', '.accessibilityLabel(title)',
              '.accessibilityValue(value)']:
    assert token in wrapper, token
labels = ['字幕位置', '显示内容', '字幕窗宽度', '高度', '字幕长度', '译文字号', '字体', '无人说话后收回']
for title in labels:
    row = block(section, f'captionSetting(tr("{title}"), value:')
    assert row.count('KKSegmentedPicker(') + row.count('CaptionSizeLevelPicker(') + row.count('KKSegmentedPickerAX(') + row.count('CaptionSizeLevelPickerAX(') == 1
    assert f'title: tr("{title}")' in row
    assert '.labelsHidden()' not in row
assert section.count('captionSetting(') == len(labels)
assert 'Slider(value: $state.captionOpacity, in: CaptionOpacityPolicy.minimum...1.0)' in section

permission = block(onboarding, 'struct PermissionRow:')
granted = permission.split('            case .granted:')[1].split('            case .needsSettings')[0]
assert 'Label(tr("已允许"), systemImage: "checkmark.circle.fill")' in granted
assert '.foregroundStyle(KKColor.textSecondary)' in granted
for forbidden in ['brand', '.kkPrimaryButton', '.disabled', '.opacity']:
    assert forbidden not in granted
assert 'Button(tr("允许")) { action() }.buttonStyle(KKQuietButtonStyle())' in permission
assert '.kkPrimaryButton' not in permission
assert '.kkPrimaryButton' not in block(onboarding, 'struct PermissionsPage:')
# Compute contrast from the actual adaptive token declarations on the row surface.
def color_pair(name):
    match = re.search(r'static let ' + name + r' = adaptive\([^\n]*dark: 0x([A-Fa-f0-9]+), light: 0x([A-Fa-f0-9]+)\)', tokens)
    assert match, name
    return [int(value, 16) for value in match.groups()]

def luminance(rgb):
    channels = [(rgb >> shift & 255) / 255 for shift in [16, 8, 0]]
    linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in channels]
    return sum(v * weight for v, weight in zip(linear, [0.2126, 0.7152, 0.0722]))

ratios = []
for text, surface in zip(color_pair('textSecondary'), color_pair('surfaceRaised')):
    lo, hi = sorted([luminance(text), luminance(surface)])
    ratios.append((hi + 0.05) / (lo + 0.05))
    assert ratios[-1] >= 4.5, ratios[-1]
print('PASS granted permission contrast (dark/light): ' + '/'.join(f'{v:.2f}:1' for v in ratios))

quiet = block(tokens, 'private struct KKQuietButtonArtwork:')
assert '.foregroundStyle(KKColor.textPrimary)' in quiet and '.background(KKColor.surfaceRaised,' in quiet
assert 'KKColor.brand' not in quiet

model_ready = block(state, 'func modelReady(')
refresh = block(state, 'func refreshModelInstallation(')
installed = block(engine, 'static func installedModelLocales(')
locale_key = block(engine, 'static func modelLocaleKey(')
assert 'installedModelLocales.contains(TranscribeEngine.modelLocaleKey(locale))' in model_ready
assert 'modelProgress' not in model_ready and 'meetingLocales' not in model_ready
assert 'await SpeechTranscriber.installedLocales' in installed
assert 'await TranscribeEngine.installedModelLocales()' in refresh
assert 'await state.refreshModelInstallation()' in meeting
for page in ['struct CaptionsHome:', 'struct LanguagesView:']:
    assert 'await state.refreshModelInstallation()' in block(main, page)
language = main[main.index('Section(tr("常用会议语言"))'):main.index('// MARK: - 设置')]
assert 'await state.refreshModelInstallation()' in language
for identifier in ['id', 'loc.identifier']:
    assert f'(state.modelReady({identifier}) ? "" : " · " + tr("需下载"))' in main
assert 'meetingLocales.contains(id) || state.modelReady' not in main
assert 'meetingLocales.contains(loc.identifier) || state.modelReady' not in main
row = block(language, 'HStack {')
assert row.index('if state.modelReady(id)') < row.index('checkmark.circle.fill') < row.index('else if let p = state.modelProgress') < row.index('Text(tr("需下载"))')
# r8: installed is a checkmark; every uninstalled model uses the same text.
assert meeting.index('if state.modelReady(id)') < meeting.index('Image(systemName: "checkmark.circle.fill")') < meeting.index('Text(tr("需下载"))')
assert 'arrow.down.circle.fill' not in meeting and 'ProgressView' not in meeting
assert 'Image(systemName: on ? "checkmark.circle.fill" : "circle")' in meeting
assert '.accessibilityAddTraits(on ? [.isSelected] : [])' in meeting
predownload = block(state, 'func predownloadModels(')
assert 'await refreshModelInstallation()' in predownload
assert 'modelProgress[l] = 1' not in predownload
start = block(engine, 'func start(')
assert start.index('downloadAndInstall()') < start.index('await CaptionState.shared.refreshModelInstallation()')
# On-demand engine downloads use the same UI progress dictionary as predownloads.
for token in ['CaptionState.shared.modelProgress[localeID] = 0',
              'state.modelProgress[localeID] = min(0.99, v)',
              'CaptionState.shared.modelProgress[localeID] = nil']:
    assert token in start
assert 'defer {\n                observer.invalidate()' in start
assert 'guard let self, self.gen == myGen else { return }' in start
assert 'if gen == myGen {' in start
assert 'CaptionState.shared.modelProgress[locale] = nil' in block(engine, 'func stop()')
assert 'defer { obs.invalidate() }' in predownload
assert 'if state.modelProgress[l] != nil' in predownload


status = block(app, 'enum CaptionListeningStatus')
call = 'state.captionStatusText'
assert f'case .running: {call}' in app
assert 'Text(statusLabel)' in app
assert 'case .paused: tr("已暂停")' in app
assert 'private var isListening: Bool { state.running && !state.paused' in app
panel, island = read('CaptionPanel.swift'), read('IslandNotch.swift')
assert f'.accessibilityLabel(state.captionDisplayStatus == .idle ? tr("字幕") : {call})' in panel
assert 'Text(state.captionStatusShortText)' in panel
assert f'.accessibilityLabel(state.captionDisplayStatus == .idle ? tr("字幕") : {call})' in island
for source in [app, panel, island]:
    assert 'state.running ? tr("正在听…")' not in source
assert 'if audioStalled' in status and 'if silentTooLong' in status

home = block(main, 'struct CaptionsHome:')
assert '.frame(maxWidth: KKLayout.homeContentMaxWidth, alignment: .leading)' in home
assert '.padding(.horizontal, KKSpace.eight).padding(.bottom, KKSpace.eight)\n            .frame(maxWidth: .infinity, alignment: .top)' in home
assert '.frame(maxWidth: .infinity, alignment: .topLeading)' not in home
preview = block(read('HomeCaptionPreview.swift'), 'struct HomeCaptionPreview:')
assert '.frame(maxWidth: 400)' in preview
assert 'VStack(spacing: 10)' in preview and '.multilineTextAlignment(.center)' in preview
assert 'Text(isExample ? tr("字幕预览 · 示例") : status)' in preview

for lang in ['zh-Hant', 'ja', 'en', 'ko']:
    table = json.loads(Path(f'Resources/l10n/{lang}.json').read_text())
    for key in ['没听到声音', '模型已安装', '常用会议语言', '音频中断，正在恢复']:
        assert table[key], (lang, key)

out = Path(sys.argv[1])
# Actual production functions, compiled against the installed Speech SDK. The system
# query is typechecked, not executed. Synthetic snapshots exercise only modelReady.
runtime = '''import Foundation
import Speech
@MainActor func tr(_ key: String) -> String { key }
@MainActor enum TranscribeEngine {
''' + locale_key + '\n' + installed + '''
}
@MainActor final class ModelState {
    var installedModelLocales: Set<String> = []
    var meetingLocales: [String] = []
    var modelProgress: [String: Double] = [:]
''' + model_ready + '\n' + refresh + '\n}\n@MainActor\n' + status
runtime += Path('tests/walkthrough_r7/runtime.swift').read_text()
(out / 'Runtime.swift').write_text(runtime)

# Typecheck the real permission row, meeting page, labeled settings section and
# preview. Stubs have no app, preferences, permission request, audio or network I/O.
fixture = Path('tests/walkthrough_r7/views.swift').read_text()
# Include the real shared row policy/types used by HomeCaptionPreview; no substitute stubs.
for signature in ['enum CaptionSizeLevel:', 'enum CaptionCollapseLevel:',
                  'enum CaptionHierarchy {', 'struct CaptionRowText:']:
    fixture += '\n' + block(read('CaptionIsland.swift'), signature)
fixture += '\n' + block(read('IslandSettings.swift'), 'struct CaptionSizeLevelPicker:')
fixture += '\n' + block(main, 'struct CaptionSegmentAccessibility<') + '\n'
fixture += '\n' + block(main, 'struct KKSegmentedPickerAX<') + '\n'
fixture += '\n' + block(main, 'struct CaptionSizeLevelPickerAX:') + '\n'
fixture += '\nenum PermissionStatus { case unknown, prompted, granted, denied, needsSettings, unconfirmed }\n'
fixture += permission + '\n' + meeting
fixture += '\nstruct LabeledSettingsFixture: View {\n @Bindable var state: CaptionState\n'
fixture += ' @ObservedObject private var captionPanel = CaptionPanelController.shared\n'
fixture += wrapper + '\n' + block(settings, 'private func sizeLabel(')
fixture += '\nvar body: some View { Form {\n' + section + '\n} }\n}\n'
(out / 'Views.swift').write_text(fixture)
# This smaller compile check covers the new Form and accessibility APIs without
# requiring a macro plugin. It uses the actual colors and helper declarations.
helpers = 'import SwiftUI\nimport AppKit\n@MainActor func tr(_ key: String) -> String { key }\n'
helpers += block(tokens, 'enum KKColor') + '\n'
helpers += block(read('CaptionIsland.swift'), 'enum CaptionSizeLevel:') + '\n'
helpers += 'struct SettingHelpersFixture: View {\n' + wrapper + '\n'
helpers += block(settings, 'private func sizeLabel(')
helpers += '\nvar body: some View { Form { captionSetting("title", value: sizeLabel("small", low: "low", high: "high")) { Text("value") } } }\n}\n'
(out / 'Helpers.swift').write_text(helpers)
print('PASS r7 wiring: scroll/footer, 8 visible labels and VO values, quiet permissions, actual installation predicate, warning surfaces, centered preview, localization')

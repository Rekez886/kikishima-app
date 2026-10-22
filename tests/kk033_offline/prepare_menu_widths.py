"""Extract menu picker and header production layout, only adding frame probes."""
from pathlib import Path
import sys,re
out=Path(sys.argv[1])
def block(s,sig):
 a=s.index(sig);b=s.index('{',a);i=b+1;d=1
 while d:
  d+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
app=Path('Sources/Kikishima/App.swift').read_text();tokens=Path('Sources/Kikishima/DesignTokens.swift').read_text()
assert app.count('options: menuCaptionOptions') == 2
options=block(app,'private var menuCaptionOptions:')
assert '(tr("双语"), "both")' in options
assert '(captionDisplayText("仅译文"), "translation")' in options
assert '(captionDisplayText("仅原文"), "source")' in options
assert 'Source' + ' Only' not in app
assert 'if state.menuShowsLogin { return tr("未登录，字幕只显示原文；登录后继续翻译") }' in app
assert '.lineLimit(state.menuShowsLogin ? 2 : nil)' in app
assert '.fixedSize(horizontal: false, vertical: state.menuShowsLogin)' in app
assert 'width: .custom(304)' in app
assert '.padding(.horizontal, 12).padding(.vertical, 10)' in app
geometry=Path('.build/checkouts/MacControlCenterUI/Sources/MacControlCenterUI/Menu Internal/Menu Constants.swift').read_text()
inset=float(re.search(r'menuHorizontalContentInset: CGFloat = (\d+)',geometry)[1])
picker_source=block(tokens,'struct KKSegmentedPicker<')
for sizing in ['HStack(spacing: 2)', '.font(.system(size: 12))', '.padding(.horizontal, 6)', '.padding(2)', '.frame(minWidth: 28, maxWidth: .infinity, minHeight: 28)']:
 assert sizing in picker_source, sizing
picker=picker_source.replace('Text(option.0).font(.system(size: 12))','Text(option.0).font(.system(size: 12)).captureFrame(index + 1)')
picker=picker.replace('.padding(.horizontal, 6)', '.padding(.horizontal, 6).captureFrame(index + 101)')
header=block(app[app.index('private var statusBlock:'):],'HStack(spacing: 8)')
header=header.replace('.changeEffect(.glow(color: brandRed, radius: 8), value: state.running)','')
header=header.replace('.fixedSize(horizontal: false, vertical: state.menuShowsLogin)','.fixedSize(horizontal: false, vertical: state.menuShowsLogin).captureFrame(1)')
header=header.replace('Spacer()', 'Spacer().captureFrame(2)')
code='import SwiftUI\nimport AppKit\n'+picker+'\nstruct MenuWidthState { var uiLanguage = "", menuShowsLogin = true, paused = false, running = true }\n'
code+='struct MenuWidthView: View { var state: MenuWidthState; var header: Bool\nlet warning = true, isListening = true; let brandRed = KKColor.brand\n'
code+=block(app,'private var menuCaptionOptions:')+'\n'
code+='var statusLabel: String { tr("未登录，字幕只显示原文；登录后继续翻译") }\n'
code+='var body: some View { if header { '+header+'.captureFrame(0).padding(.horizontal, 12) } else { KKSegmentedPicker(title: tr("显示内容"), selection: .constant("both"), options: menuCaptionOptions).controlSize(.small).labelsHidden().captureFrame(0) } }\n}\n'
code+=f'let menuContentWidth: CGFloat = 304 - 2 * {inset}\n'
code+=block(Path('Sources/Kikishima/L10n.swift').read_text(),'@MainActor func captionDisplayText(')+'\n'
main=Path('Sources/Kikishima/MainWindow.swift').read_text()
home=Path('Sources/Kikishima/HomeCaptionPreview.swift').read_text()
main_picker=block(main,'captionSetting(tr("显示内容")')
assert 'captionDisplayText(state.captionDisplay ==' in main_picker
assert main_picker.count('captionDisplayText("仅原文")') == 2
assert home.count('captionDisplayText("仅原文")') == 2
assert '.frame(minWidth: 460,' in main
assert '.frame(minWidth: 780, minHeight: 520)' in main
assert '.navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)' in main
assert '.padding(.horizontal, 32).padding(.bottom, 32)' in main
code+='@MainActor var settingsContentWidth: CGFloat { let split = NSSplitView(); split.dividerStyle = .thin; return max(460, 780 - 260 - split.dividerThickness) }\n'
code+='@MainActor var previewContentWidth: CGFloat { settingsContentWidth - 64 }\n'
assert '.formStyle(.grouped)\n        .font(.system(size: 13))' in main
# Settings uses the production LabeledContent and Form, including system insets.
main_picker=main_picker.replace('$state.captionDisplay','.constant("both")').replace('state.captionDisplay','"both"')
main_picker=main_picker.split('.accessibilityRepresentation')[0]+'}'
code+='struct SettingsWidthView: View { '+block(main,'private func captionSetting<')+'\nvar body: some View { Form { Section(tr("字幕窗")) { '+main_picker+' } }.formStyle(.grouped).font(.system(size: 13)) } }\n'
# Preview uses intrinsic segments and falls back to a native menu in a narrow slot.
preview_segment=next(line.strip() for line in home.splitlines() if 'KKSegmentedPicker(title: tr("显示内容")' in line).replace('$display', '.constant("both")')
preview=block(home,'private var displayPicker:').replace('$display','.constant("source")')
code+='struct PreviewWidthView: View { var fallback: Bool; '+preview+'\nvar body: some View { if fallback { displayPicker.pickerStyle(.menu).captureFrame(0) } else { '+preview_segment+'.captureFrame(0) } } }\n'
(out/'MenuWidthWiring.swift').write_text(code)
print('PASS menu extraction: production picker, options, header HStack and menu inset')

# Reuse the existing passive probe definitions, without its executable main.
measure=Path('tests/kk033_offline/measure_copy.swift').read_text()
(out/'WidthProbes.swift').write_text(measure.split('@main struct CopyMeasure')[0])

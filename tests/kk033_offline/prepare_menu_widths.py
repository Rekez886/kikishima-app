"""Extract preview picker layout and check shared selector source."""
from pathlib import Path
import sys
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
assert 'width: .custom(304)' in app
assert '.padding(.horizontal, 12).padding(.vertical, 10)' in app
picker_source=block(tokens,'struct KKSegmentedPicker<')
for sizing in ['HStack(spacing: 2)', '.font(.system(size: 12))', '.padding(.horizontal, 6)', '.padding(2)', '.frame(minWidth: 28, maxWidth: .infinity, minHeight: 28)']:
 assert sizing in picker_source, sizing
picker=picker_source.replace('Text(option.0).font(.system(size: 12))','Text(option.0).font(.system(size: 12)).captureFrame(index + 1)')
picker=picker.replace('.padding(.horizontal, 6)', '.padding(.horizontal, 6).captureFrame(index + 101)')
code='import SwiftUI\nimport AppKit\n'+picker+'\n'
code+=block(Path('Sources/Kikishima/L10n.swift').read_text(),'@MainActor func captionDisplayText(')+'\n'
main=Path('Sources/Kikishima/MainWindow.swift').read_text()
home=Path('Sources/Kikishima/HomeCaptionPreview.swift').read_text()
main_picker=block(main,'captionSetting(tr("显示内容")')
assert 'captionDisplayText(state.captionDisplay ==' in main_picker
assert main_picker.count('captionDisplayText("仅原文")') == 1
assert home.count('captionDisplayText("仅原文")') == 2
assert '.frame(minWidth: KKLayout.detailMinWidth,' in main
assert '.frame(minWidth: KKLayout.mainWindowMinSize.width, minHeight: KKLayout.mainWindowMinSize.height)' in main
assert '.navigationSplitViewColumnWidth(min: KKLayout.sidebarMinWidth, ideal: KKLayout.sidebarIdealWidth, max: KKLayout.sidebarMaxWidth)' in main
assert '.padding(.horizontal, KKSpace.eight).padding(.bottom, KKSpace.eight)' in main
code+='@MainActor var settingsContentWidth: CGFloat { let split = NSSplitView(); split.dividerStyle = .thin; return max(460, 780 - 260 - split.dividerThickness) }\n'
code+='@MainActor var previewContentWidth: CGFloat { settingsContentWidth - 64 }\n'
# Preview uses intrinsic segments and falls back to a native menu in a narrow slot.
preview_segment=next(line.strip() for line in home.splitlines() if 'KKSegmentedPicker(title: tr("显示内容")' in line).replace('$display', '.constant("both")')
preview=block(home,'private var displayPicker:').replace('$display','.constant("source")')
code+='struct PreviewWidthView: View { var fallback: Bool; '+preview+'\nvar body: some View { if fallback { displayPicker.pickerStyle(.menu).captureFrame(0) } else { '+preview_segment+'.captureFrame(0) } } }\n'
(out/'MenuWidthWiring.swift').write_text(code)
print('PASS picker extraction: production preview layout, options and frame probes')

# Reuse the existing passive probe definitions, without its executable main.
measure=Path('tests/kk033_offline/measure_copy.swift').read_text()
(out/'WidthProbes.swift').write_text(measure.split('@main struct CopyMeasure')[0])

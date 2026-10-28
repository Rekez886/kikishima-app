"""Extract production rows verbatim; inject only passive frame preferences.
Storage/hardware is a fixture. Glow and focus adornments are non-sizing overlays.
The actual button artwork, padding, minimum size, row layout and fonts are compiled.
"""
from pathlib import Path
import sys,json
out=Path(sys.argv[1]);read=lambda n:Path('Sources/Kikishima/'+n).read_text()
def block(s,sig):
 a=s.index(sig);b=s.index('{',a);i=b+1;d=1
 while d:
  d+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
state=read('CaptionState.swift');panel=read('CaptionPanel.swift');island=read('IslandNotch.swift');tokens=read('DesignTokens.swift')
code='import SwiftUI\nimport AppKit\n'
for sig in ['enum KKColor','struct KKQuietButtonStyle:','struct KKPlainButtonStyle:','private struct KKSystemFocusButton<','private struct KKQuietButtonArtwork:','private struct KKPlainButtonArtwork:']:
 code+=block(tokens,sig)+'\n'
code+='extension View { func kkFocusRing(radius: CGFloat = 6) -> some View { self }\n func kkPrimaryButton() -> some View { self } }\n'
code+=block(state,'struct CaptionBanner:')+'\n'
code+=block(panel,'private struct CaptionStatusInlineLayout:').replace('private ','')+'\n'
props=state[state.index('    var errorBanner: CaptionBanner?'):state.index('    private var connectivityAvailable:')].replace('private ','')
code+='''final class CaptionState {
 var status = "", running = true, paused = false, silentTooLong = false, audioStalled = false
 var compactCaptions = true, finishingCaptions = false
 func captionFont(_ size: Double) -> Font { .system(size: size) }
 func performBanner(_ action: CaptionBanner.Action) {}
'''+props+'\n}\n'
# Immutable input at the view boundary lets every catalog sentence occupy the
# real row, without falsely creating a production error for a process message.
code+='''struct RowInput {
 let captionDisplayStatus: CaptionStatusPriority
 let captionStatusBanner: CaptionBanner?
 let captionStatusShortText: String
 let captionStatusText: String
 var running = true, compactCaptions = true, finishingCaptions = false
 func captionFont(_ size: Double) -> Font { .system(size: size) }
 func performBanner(_ action: CaptionBanner.Action) {}
}
'''
compact=block(island,'struct IslandCompactLeading:').replace('@Bindable var state: CaptionState', 'var state: RowInput')
compact=compact.replace('.changeEffect(.glow(color: KKColor.brand, radius: 8), value: state.running)', '.captureFrame(0)')
compact=compact.replace('.foregroundStyle(state.captionDisplayStatus == .error ? KKColor.error : KKColor.warning)', '.foregroundStyle(state.captionDisplayStatus == .error ? KKColor.error : KKColor.warning)\n                    .captureFrame(1)')
compact=compact.replace('.buttonStyle(KKQuietButtonStyle()).controlSize(.small)', '.buttonStyle(KKQuietButtonStyle()).controlSize(.small).captureFrame(2)')
code+=compact+'\n'
desktop=block(panel,'private func desktopStatusLine(').replace('private ','')
desktop=desktop.replace('.accessibilityHidden(true)', '.accessibilityHidden(true).captureFrame(0)')
desktop=desktop.replace('.help(banner.text).accessibilityLabel(banner.text)', '.help(banner.text).accessibilityLabel(banner.text).captureFrame(1)')
helper='    @ViewBuilder\n    '+block(panel,'private func bannerActionButton(').replace('private ','')
helper=helper.replace('.disabled(action == .retry && state.finishingCaptions)', '.disabled(action == .retry && state.finishingCaptions).captureFrame(2)')
code+='struct DesktopRow: View { var state: RowInput; let banner: CaptionBanner; let scale = 1.0\n'+helper+'\n var body: some View { desktopStatusLine(banner) }\n'+desktop+'\n}\n'
(out/'WidthWiring.swift').write_text(code)
print('PASS width extraction: production compact leading, desktop row, inline layout, real button artwork; passive frame instrumentation')

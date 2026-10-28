from pathlib import Path
import ast
import json
import subprocess
import sys

out = Path(sys.argv[1])
state = Path('Sources/Kikishima/CaptionState.swift').read_text()
panel = Path('Sources/Kikishima/CaptionPanel.swift').read_text()
def block(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

# Execute the actual old failure branch before looking for any new file/API.
# This is a behavioral failure, not a missing-source compiler failure.
failure = block(state, 'private func handleFailure(')
if 'case .network(let msg):' in failure:
    network = failure.split('case .network(let msg):', 1)[1].split('case .server', 1)[0]
    probe = 'import Foundation\nvar status = "running"\nlet msg = "翻译请求超时"\n' + network
    probe += '\nprint("BASE: single timed-out chunk status=\\(status)")\n'
    probe += 'if status == msg { print("FAIL KK-033: one timeout exposes failure prose before the offline threshold"); exit(1) }\n'
    (out / 'Before.swift').write_text(probe)
    subprocess.run(['swiftc', str(out / 'Before.swift'), '-o', str(out / 'before')], check=True)
    subprocess.run([str(out / 'before')], check=True)
    raise AssertionError('BASE branch unexpectedly passed')

for name in ['network', 'server']:
    branch = failure.split('case .' + name, 1)[1].split('\n        case ', 1)[0]
    assert 'errorBanner =' not in branch
    assert 'status =' not in branch and 'tr(' not in branch and 'msg' not in branch
    assert 'translationFailed(chunk: chunk)' in branch
connectivity = block(state, 'private func translationFailed(')
assert 'updateTranslationConnectivity()' in connectivity
assert 'translationConnectivity.failed(chunk: chunk, enabled: connectivityAvailable)' in connectivity

assert 'TranslationConnectivityRequest.context.withValue(request)' in state
request_type = block(Path('Sources/Kikishima/TranslationConnectivityPolicy.swift').read_text(), 'struct TranslationConnectivityRequest:')
assert 'let chunk: UUID' in request_type and 'let attempt: UUID' in request_type
assert 'NSLock' not in request_type and 'pendingStatus' not in request_type and 'forwardsStatus' not in request_type
assert 'let request = TranslationConnectivityRequest.current' in state
consumer = block(state, 'private func consumeTranslationCallbacks(')
assert 'sessionGen == generation' in consumer
assert 'activeTranslationAttempts[request.chunk] == request.attempt' in consumer
assert 'var buffers: [UUID: TranslationConnectivityStatusBuffer] = [:]' in consumer
assert 'continuation.yield(.status(request, msg))' in state
assert 'continuation.yield(.failure(request, f))' in state
assert 'callbackContinuation?.yield(.completion(request)' in state
assert 'self.translationSucceeded()' in state
assert 'self.chunks[idx].translationExhausted = self.chunks[idx].translationAttempts == 3' in state
assert 'self.chunks[idx].zh = ""' in state
assert 'translationExhausted = false' in block(state, 'private func requestTranslation(for')
assert 'self.updateTranslationConnectivity()' in block(state, 'private func startMicPolling()')
assert 'if level > 0.02 { lastLoudAt = now; audibleTime += elapsed }' in state
assert 'audibleTime = 0' in block(state, 'func reset()')
for text in ['部分字幕未翻译完成，可重试', '部分字幕未翻译完成，可在记录中重试']:
    assert text not in state and text not in panel

row = block(panel, 'private func captionRow(')
assert 'CaptionHierarchy.row(source: chunk.displaySource' in row
assert 'Text(text.primary)' in row and 'if let secondary = text.secondary' in row
role_call = row.split('let text = ', 1)[1].split('\n        return HStack', 1)[0]
source_guard = '(' + role_call + ').primary == chunk.displaySource'
assert 'Button' not in row.split('.contextMenu', 1)[0]
status = block(panel, 'private var displayedErrorStatus:')
assert 'state.captionStatusBanner' in status
assert 'banner.severity == .info ? KKColor.warning : KKColor.error' in panel
assert panel.count('.timingCurve(0.2, 0, 0, 1, duration: 0.12)') == 1
assert 'duration: toolbarMode == .island ? 0.2 : 0.12' in panel
assert 'bannerActionButton(banner, island: false)' in block(panel, 'private func desktopStatusLine(')
assert 'if let action = banner.action' in block(panel, 'private func bannerActionButton(')

translations = {'zh-Hant': '離線，正在重新連線', 'ja': 'オフライン、再接続中', 'en': 'Offline, reconnecting', 'ko': '오프라인, 다시 연결 중'}
tree = ast.parse(Path('Resources/l10n/gen.py').read_text())
table = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'T' for t in n.targets))
assert table['离线，正在重连'] == list(translations.values())
for lang, expected in translations.items():
    assert json.loads(Path(f'Resources/l10n/{lang}.json').read_text())['离线，正在重连'] == expected

chunk = block(state, 'struct CaptionChunk:')
banner = block(state, 'struct CaptionBanner:')
properties = state[state.index('    var errorBanner: CaptionBanner?'):state.index('private func translationFailed(') + len(connectivity)]
methods = '\n'.join(block(state, sig).replace('private ', '') for sig in [
    'private func handleFailure(', 'private func pauseForInvalidOpenAIKey()', 'private func pause(_ r:',
])
# Extract the production completion branch, including actual exhaustion/reset logic.
completion = block(state, '                if final != nil {')
else_branch = state[state.index('                if final != nil {') + len(completion):]
completion += block(else_branch, ' else if self.running || self.finishingCaptions')
fixtures = Path('tests/kk033_offline/fixtures.swift').read_text()
production = fixtures.replace('// FAILURE TYPE', block(Path('Sources/Kikishima/Translate.swift').read_text(), 'enum TranslateFailure:')).replace('// EVENT', block(state, 'enum TranslationCallbackEvent:')).replace('// CHUNK', chunk + '\n' + banner).replace('// PROPERTIES', properties)
production = production.replace('// METHODS', methods + '\n' + consumer.replace('private ', ''))
production = production.replace('// COMPLETION', completion)
production += '\nfunc showsSource(_ chunk: CaptionChunk, _ state: DisplayState, current: Bool) -> Bool { ' + source_guard + ' }\n'
production += block(Path('Sources/Kikishima/CaptionIsland.swift').read_text(), 'enum CaptionHierarchy') + '\n'
production += block(Path('Sources/Kikishima/CaptionIsland.swift').read_text(), 'struct CaptionRowText:') + '\n'
(out / 'Production.swift').write_text(production)
print('PASS KK-033 production wiring and translations')

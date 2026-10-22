"""Compile whole production methods verbatim; only external services are fixtures."""
from pathlib import Path
import sys

source = Path('Sources/Kikishima/CaptionState.swift').read_text()
def block(signature):
    start = source.index(signature)
    opening = source.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

signatures = [
    'private func requestTranslation(for',
    'private func requestTranslationViaProxy(for',
    'private func consumeTranslationCallbacks(',
    'private func retryFailedChunks()',
]
fixture = Path('tests/kk033_offline/concurrency.swift').read_text()
fixture = fixture.replace('// PRODUCTION TYPES', block('struct CaptionChunk:') + '\n' + block('enum TranslationCallbackEvent:'))
fixture = fixture.replace('// PRODUCTION METHODS', '\n\n'.join(block(sig) for sig in signatures))
Path(sys.argv[1], 'Concurrency.swift').write_text(fixture)
print('PASS concurrency extraction: complete request, proxy, onDone, consumer and retry methods verbatim')

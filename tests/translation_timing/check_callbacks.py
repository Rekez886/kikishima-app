"""Execute production callback statements without UI, audio, account or network access."""
from pathlib import Path
import sys

source = Path('Sources/Kikishima/CaptionState.swift').read_text()
source = source[source.index('private func requestTranslationViaProxy('):]
def matching(text, start, opening, closing):
    depth, end = 1, start + 1
    while depth:
        depth += (text[end] == opening) - (text[end] == closing)
        end += 1
    return end

def task_body(anchor):
    marker = 'Task { @MainActor in\n'
    start = source.index(marker, source.index(anchor))
    return source[start + len(marker):matching(source, source.index('{', start), '{', '}') - 1]

delta = task_body('translator.translate(')
done = task_body('} onDone:')
finish = done.index('self.timingRecorder.finish(')
done = done[:matching(done, done.index('(', finish), '(', ')')]
harness = Path('tests/translation_timing/callbacks.swift').read_text()
Path(sys.argv[1]).write_text(harness.replace('// DELTA', delta).replace('// DONE', done))

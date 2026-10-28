"""Extract the REAL retry transition into a dependency-free Swift harness.
No replacement transition is implemented in tests. Stage B can preserve translation
ownership, or advance it while clearing both inflight and active attempts.
"""
from pathlib import Path
import re
import sys

source = Path('Sources/Kikishima/CaptionState.swift').read_text()
retry = source.split('func retryMeetingSummary(document:', 1)[1].split('private func handle(', 1)[0]
# The second task is the archived-record retry, after the isWorking early return.
anchor = 'if await coordinator.isWorking(recordID: document.recordID)'
start = retry.index('{', retry.index(anchor))
depth, end = 1, start + 1
while depth and end < len(retry):
    depth += (retry[end] == '{') - (retry[end] == '}')
    end += 1
if depth:
    raise SystemExit('FAIL audit25: cannot locate isWorking guard end')
transition = retry[end:retry.index('await coordinator.begin(', end)].strip()
errors = []
def check(value, message):
    if not value:
        errors.append(message)

check(bool(transition), 'archived-record retry transition must be exercised')
check('self.meetingSummaryGeneration = generation' in transition,
      'retry must register the generation used for coordinator work')
for call in ['begin', 'accept', 'finalize']:
    check(bool(re.search(r'coordinator\.' + call + r'\([\s\S]*?generation:\s*generation\b', retry)),
          f'retry coordinator.{call} must receive the registered generation')
check('if self.meetingSummaryGeneration == generation' in retry,
      'retry completion must retain its summary ownership guard')
# Both real completion paths must still guard translation ownership.
request = source.split('inflight += 1', 1)[1]
check('TranslationCompletionPolicy.remainingInflight(inflight, requestGeneration: gen, currentGeneration: sessionGen)' in request,
      'local translation completion must use the tested generation policy')
check('guard let self, gen == self.sessionGen, self.activeTranslationAttempts[id] == attempt else { return }' in request,
      'remote completion must verify generation AND attempt ownership')
check('self.activeTranslationAttempts.removeValue(forKey: id)' in request
      and 'self.inflight = max(0, self.inflight - 1)' in request,
      'current remote completion must unregister its attempt and release one slot')
# Detect the actual regression independently of the Swift runtime test.
clean = re.sub(r'//[^\n]*', '', transition)
if re.search(r'(?:self\.)?sessionGen\s*(?:\+=|=)', clean):
    check(bool(re.search(r'(?:self\.)?inflight\s*=\s*0\b', clean))
          and bool(re.search(r'(?:self\.)?activeTranslationAttempts\s*(?:=\s*\[:\]|\.removeAll\s*\()', clean)),
          'retry mutates translation generation without clearing BOTH inflight and activeTranslationAttempts')

# Compile these statements verbatim, with inert data fields instead of the app UI.
# The independent-summary-generation option may use this counter; it owns no
# translation slots. Its exact value is deliberately not asserted here.
harness = '''import Foundation
struct RetryDocument { let recordID: String }
final class RetryTransitionHarness {
    var sessionGen = 10
    var inflight = 0
    var activeTranslationAttempts: [UUID: UUID] = [:]
    var meetingSummaryGeneration: Int? = 10
    var meetingSummaryRetryGeneration = 10
    var meetingSummaryRecordID: String? = "live"
    var meetingSummarySnapshot: Int? = 1
    func applyRetryTransition() {
        let document = RetryDocument(recordID: "archived")
'''
harness += transition + '\n    }\n}\n'
Path(sys.argv[1]).write_text(harness)
for error in errors:
    print('FAIL audit25 wiring: ' + error, file=sys.stderr)
if errors:
    sys.exit(1)
print('PASS audit25 retry/coordinator and translation callback wiring')

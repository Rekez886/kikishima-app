"""Compile actual billing and refresh methods against in-memory transport."""
from pathlib import Path
import sys

source = Path('Sources/Kikishima/CaptionState.swift').read_text()
def method(signature):
    start = source.index(signature)
    start = source.rfind('\n', 0, start) + 1
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '')

names = [
    'private func authContext()', 'private func authIsCurrent(',
    'private func cancelBillingRequests()', 'private func resetBillingState()', 'private func showBillingError(',
    'func openUpgrade()', 'func openSubscriptionManagement()', 'private func openBilling(',
    'private func startBillingPoll(', 'func refreshPlan()', 'func restorePurchases()',
    'private func refreshPlan(restoring:', 'private static func parseISO(',
]
base = Path('tests/billing/harness.swift').read_text()
Path(sys.argv[1]).write_text(base.replace('// EXTRACTED_METHODS', '\n'.join(method(n) for n in names)))
assert 'resetBillingState()' in method('var sessionToken:')
assert 'checkoutBase' not in source and 'customer_email' not in source
app = Path('Sources/Kikishima/App.swift').read_text()
assert 'url.host == "billing-return"' in app and 'CaptionState.shared.restorePurchases()' in app
settings = Path('Sources/Kikishima/MainWindow.swift').read_text()
assert 'state.openSubscriptionManagement()' in settings and 'state.restorePurchases()' in settings
assert 'Text(state.billingError)' in settings
print('PASS billing UI and account lifecycle wiring')

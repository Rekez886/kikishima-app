#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
result=0
# Even when wiring fails, compile and run the extracted transition to expose leaks.
python3 tests/audit25/check_wiring.py "$test_dir/RetryTransition.swift" || result=1
sources=(tests/audit25/main.swift Sources/Kikishima/TranslationCompletionPolicy.swift "$test_dir/RetryTransition.swift")
if [[ -f Sources/Kikishima/MeetingSummaryRetryPolicy.swift ]]; then
    sources+=(Sources/Kikishima/MeetingSummaryRetryPolicy.swift)
fi
if swiftc -module-cache-path "$test_dir/module-cache" "${sources[@]}" -o "$test_dir/audit25"; then
    "$test_dir/audit25" || result=1
else
    result=1
fi
exit "$result"

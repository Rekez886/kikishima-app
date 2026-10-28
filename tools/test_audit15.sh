#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
python3 tests/audit15/extract_meter.py "$test_dir/AudioMeter.swift"
# Compile the real class against the synchronized snapshot() contract first.
# Missing API is a test failure, not a successful/expected-failure test run.
echo "audit15: checking AudioMeter.snapshot() contract, then concurrent ingest/reset/read"
swiftc -module-cache-path "$test_dir/module-cache" -sanitize=thread -g -Onone "$test_dir/AudioMeter.swift" tests/audit15/main.swift -o "$test_dir/audit15"
# Once the contract compiles, also fail on the first observed race.
TSAN_OPTIONS="halt_on_error=1:exitcode=66" "$test_dir/audit15"

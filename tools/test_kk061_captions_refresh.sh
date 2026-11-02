#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."

python3 tests/kk061_captions_refresh/check_wiring.py
python3 tests/kk061_captions_refresh/prepare.py "$KK_TEST_TMP_ROOT/policy.swift"
swiftc -parse-as-library "$KK_TEST_TMP_ROOT/policy.swift" tests/kk061_captions_refresh/main.swift \
    -o "$KK_TEST_TMP_ROOT/kk061-captions-refresh"
"$KK_TEST_TMP_ROOT/kk061-captions-refresh"

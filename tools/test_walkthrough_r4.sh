#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
python3 tests/walkthrough_r4/check_wiring.py
swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
    Sources/Kikishima/DesignTokens.swift Sources/Kikishima/CaptionIsland.swift \
    tests/walkthrough_r4/main.swift -o "$test_dir/r4"
"$test_dir/r4"

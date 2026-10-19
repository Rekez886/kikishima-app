#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
python3 tests/notch_default/check_wiring.py
swiftc -module-cache-path "$test_dir/module-cache" \
    Sources/Kikishima/CaptionSurfacePreference.swift Sources/Kikishima/CaptionScreenPolicy.swift \
    Sources/Kikishima/CaptionIslandScreen.swift \
    Vendor/DynamicNotchKit/Sources/DynamicNotchKit/Utility/NSScreen+Extensions.swift \
    tests/notch_default/main.swift -o "$test_dir/notch-default"
"$test_dir/notch-default"

#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
swiftc Sources/Kikishima/CaptionIsland.swift tests/notch_fixture/NotchMeasurement.swift tests/notch_fixture/main.swift -o "$KK_TEST_TMP_ROOT/notch-geometry"
"$KK_TEST_TMP_ROOT/notch-geometry"
if "$KK_TEST_TMP_ROOT/notch-geometry" --missing 2> "$KK_TEST_TMP_ROOT/missing.log"; then exit 1; fi
rg -Fx 'NOTCH MEASUREMENT MISSING: safeAreaTop in tests/notch_fixture/NotchMeasurement.swift' "$KK_TEST_TMP_ROOT/missing.log"

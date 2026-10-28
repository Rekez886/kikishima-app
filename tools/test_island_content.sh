#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
python3 tests/island_content/check_wiring.py "$KK_TEST_TMP_ROOT/DisplayContext.swift"
swiftc -parse-as-library Sources/Kikishima/CaptionIsland.swift "$KK_TEST_TMP_ROOT/DisplayContext.swift" tests/island_content/main.swift -o "$KK_TEST_TMP_ROOT/island-content"
"$KK_TEST_TMP_ROOT/island-content"

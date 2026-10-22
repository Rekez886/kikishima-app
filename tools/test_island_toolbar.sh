#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
python3 tests/island_toolbar/check_wiring.py
swiftc Sources/Kikishima/CaptionIsland.swift tests/island_toolbar/main.swift -o "$KK_TEST_TMP_ROOT/island-toolbar"
"$KK_TEST_TMP_ROOT/island-toolbar"

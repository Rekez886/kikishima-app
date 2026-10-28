#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
swiftc Sources/Kikishima/CaptionReadingPolicy.swift tests/caption_reading/main.swift -o "$KK_TEST_TMP_ROOT/reading"
"$KK_TEST_TMP_ROOT/reading"

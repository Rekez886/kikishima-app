#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
python3 tests/kk034_error_status/prepare.py "$KK_TEST_TMP_ROOT/Production.swift"
swiftc Sources/Kikishima/CaptionErrorStatus.swift Sources/Kikishima/CaptionStatusPriority.swift \
    Sources/Kikishima/TranslationConnectivityPolicy.swift "$KK_TEST_TMP_ROOT/Production.swift" \
    tests/kk034_error_status/main.swift -o "$KK_TEST_TMP_ROOT/status"
"$KK_TEST_TMP_ROOT/status"
swiftc -parse-as-library Sources/Kikishima/CaptionErrorStatus.swift \
    "$KK_TEST_TMP_ROOT/ResizeDelegate.swift" tests/kk034_error_status/accessory.swift -o "$KK_TEST_TMP_ROOT/accessory"
set +e
"$KK_TEST_TMP_ROOT/accessory" $(cat "$KK_TEST_TMP_ROOT/Widths.txt")
accessory_exit=$?
set -e
if [ "$accessory_exit" -eq 77 ]; then
    echo 'FAIL offscreen AppKit titlebar layout unavailable'
    exit "$accessory_exit"
elif [ "$accessory_exit" -ne 0 ]; then
    exit "$accessory_exit"
fi
echo 'PASS KK-034: offscreen titlebar and 28pt shared-row geometry, capture error classification, Esc and five languages'

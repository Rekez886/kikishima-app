#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
swiftc -parse-as-library Sources/Kikishima/CaptionFinalization.swift \
  Sources/Kikishima/TranscriptRecovery.swift Sources/Kikishima/TranscriptWriter.swift \
  tests/caption_finalization/main.swift -o "$KK_TEST_TMP_ROOT/finalization"
env KK_TEST_TMP_ROOT="$KK_TEST_TMP_ROOT" "$KK_TEST_TMP_ROOT/finalization"
python3 tests/caption_finalization/check_wiring.py "$KK_TEST_TMP_ROOT/stop.swift"
swiftc -parse-as-library Sources/Kikishima/CaptionFinalization.swift \
  Sources/Kikishima/TranslationRetryQueue.swift "$KK_TEST_TMP_ROOT/stop.swift" -o "$KK_TEST_TMP_ROOT/stop"
"$KK_TEST_TMP_ROOT/stop"

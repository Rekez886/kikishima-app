#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
swiftc Sources/Kikishima/SpeechActivityDetector.swift \
  Sources/Kikishima/TranslationRules.swift \
  tests/transcription_finalization/main.swift -framework AVFoundation -o "$test_dir/finalization"
"$test_dir/finalization"
echo 'PASS: transcription pause detection'

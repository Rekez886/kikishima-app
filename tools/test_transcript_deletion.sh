#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."

python3 tests/transcript_deletion/check_isolation.py --self-test
python3 tests/transcript_deletion/check_isolation.py
swiftc -parse-as-library Sources/Kikishima/TranscriptDeletion.swift \
    tests/transcript_deletion/main.swift -o "$KK_TEST_TMP_ROOT/transcript-deletion"
"$KK_TEST_TMP_ROOT/transcript-deletion"

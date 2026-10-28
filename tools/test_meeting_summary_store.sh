#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."

swiftc -parse-as-library Sources/Kikishima/MeetingSummary.swift \
    Sources/Kikishima/MeetingSummaryStore.swift Sources/Kikishima/TranscriptWriter.swift \
    Sources/Kikishima/TranscriptDeletion.swift tests/meeting_summary_store/main.swift \
    -o "$KK_TEST_TMP_ROOT/meeting-summary-store"
"$KK_TEST_TMP_ROOT/meeting-summary-store"

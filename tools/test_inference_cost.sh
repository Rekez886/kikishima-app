#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
swiftc -parse-as-library Sources/Kikishima/SessionLifecycle.swift Sources/Kikishima/Translate.swift \
  Sources/Kikishima/HTTPFailurePolicy.swift Sources/Kikishima/TranslationRules.swift \
  tests/inference_cost/main.swift -o "$KK_TEST_TMP_ROOT/translation-cost"
"$KK_TEST_TMP_ROOT/translation-cost"
swiftc -parse-as-library Sources/Kikishima/MeetingSummary.swift Sources/Kikishima/MeetingSummaryClient.swift \
  Sources/Kikishima/HTTPFailurePolicy.swift tests/meeting_summary_client/main.swift -o "$KK_TEST_TMP_ROOT/summary-client"
"$KK_TEST_TMP_ROOT/summary-client"
swiftc -parse-as-library Sources/Kikishima/MeetingSummary.swift Sources/Kikishima/MeetingSummaryClient.swift \
  Sources/Kikishima/HTTPFailurePolicy.swift Sources/Kikishima/MeetingSummaryCoordinator.swift Sources/Kikishima/MeetingSummaryStore.swift \
  Sources/Kikishima/TranscriptWriter.swift Sources/Kikishima/TranscriptDeletion.swift \
  tests/meeting_summary_coordinator/main.swift -o "$KK_TEST_TMP_ROOT/summary-coordinator"
"$KK_TEST_TMP_ROOT/summary-coordinator"

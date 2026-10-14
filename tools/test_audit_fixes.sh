#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swiftc Sources/Kikishima/TranslationRetryQueue.swift tests/translation_retry_queue/main.swift -o /tmp/kikishima-translation-retry-queue-test
/tmp/kikishima-translation-retry-queue-test

bash tools/test_session_lifecycle.sh

swiftc -parse-as-library Sources/Kikishima/LaunchAtLoginController.swift tests/launch_at_login/main.swift -o /tmp/kikishima-launch-at-login-test
/tmp/kikishima-launch-at-login-test

swiftc -parse-as-library Sources/Kikishima/MeetingSummary.swift Sources/Kikishima/MeetingSummaryStore.swift Sources/Kikishima/TranscriptWriter.swift Sources/Kikishima/TranscriptDeletion.swift tests/meeting_summary_store/main.swift -o /tmp/kikishima-summary-store-test
/tmp/kikishima-summary-store-test

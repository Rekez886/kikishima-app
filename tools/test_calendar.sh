#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."

swiftc Sources/Kikishima/CalendarDomain.swift tests/calendar_domain/main.swift -o "$KK_TEST_TMP_ROOT/kikishima-calendar-domain-test"
"$KK_TEST_TMP_ROOT/kikishima-calendar-domain-test"

swiftc Sources/Kikishima/CalendarDomain.swift Sources/Kikishima/MeetingContextTerms.swift tests/meeting_context_terms/main.swift -o "$KK_TEST_TMP_ROOT/kikishima-meeting-context-terms-test"
"$KK_TEST_TMP_ROOT/kikishima-meeting-context-terms-test"

swiftc -framework EventKit Sources/Kikishima/CalendarDomain.swift Sources/Kikishima/MacCalendarProvider.swift tests/mac_calendar_provider/main.swift -o "$KK_TEST_TMP_ROOT/kikishima-mac-calendar-provider-test"
"$KK_TEST_TMP_ROOT/kikishima-mac-calendar-provider-test"

swiftc -parse-as-library Sources/Kikishima/CalendarDomain.swift Sources/Kikishima/CalendarCoordinator.swift tests/calendar_coordinator/main.swift -o "$KK_TEST_TMP_ROOT/kikishima-calendar-coordinator-test"
"$KK_TEST_TMP_ROOT/kikishima-calendar-coordinator-test"

swiftc Sources/Kikishima/CalendarDomain.swift Sources/Kikishima/MeetingContextTerms.swift Sources/Kikishima/MeetingSessionContext.swift tests/meeting_context_session/main.swift -o "$KK_TEST_TMP_ROOT/kikishima-meeting-context-session-test"
"$KK_TEST_TMP_ROOT/kikishima-meeting-context-session-test"

swiftc Sources/Kikishima/MeetingLanguageTimeline.swift tests/meeting_language_timeline/main.swift -o "$KK_TEST_TMP_ROOT/kikishima-meeting-language-timeline-test"
"$KK_TEST_TMP_ROOT/kikishima-meeting-language-timeline-test"

swiftc Sources/Kikishima/MeetingSummary.swift tests/meeting_summary_model/main.swift -o "$KK_TEST_TMP_ROOT/kikishima-summary-model-test"
"$KK_TEST_TMP_ROOT/kikishima-summary-model-test"

bash tools/test_session_lifecycle.sh

python3 Resources/l10n/gen.py --check
./build.sh

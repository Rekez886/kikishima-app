#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swiftc Sources/Kikishima/CalendarDomain.swift tests/calendar_domain/main.swift -o /tmp/kikishima-calendar-domain-test
/tmp/kikishima-calendar-domain-test

swiftc Sources/Kikishima/CalendarDomain.swift Sources/Kikishima/MeetingContextTerms.swift tests/meeting_context_terms/main.swift -o /tmp/kikishima-meeting-context-terms-test
/tmp/kikishima-meeting-context-terms-test

swiftc -framework EventKit Sources/Kikishima/CalendarDomain.swift Sources/Kikishima/MacCalendarProvider.swift tests/mac_calendar_provider/main.swift -o /tmp/kikishima-mac-calendar-provider-test
/tmp/kikishima-mac-calendar-provider-test

swiftc -parse-as-library Sources/Kikishima/CalendarDomain.swift Sources/Kikishima/CalendarCoordinator.swift tests/calendar_coordinator/main.swift -o /tmp/kikishima-calendar-coordinator-test
/tmp/kikishima-calendar-coordinator-test

swiftc Sources/Kikishima/CalendarDomain.swift Sources/Kikishima/MeetingContextTerms.swift Sources/Kikishima/MeetingSessionContext.swift tests/meeting_context_session/main.swift -o /tmp/kikishima-meeting-context-session-test
/tmp/kikishima-meeting-context-session-test

swiftc Sources/Kikishima/MeetingLanguageTimeline.swift tests/meeting_language_timeline/main.swift -o /tmp/kikishima-meeting-language-timeline-test
/tmp/kikishima-meeting-language-timeline-test

swiftc Sources/Kikishima/MeetingSummary.swift tests/meeting_summary_model/main.swift -o /tmp/kikishima-summary-model-test
/tmp/kikishima-summary-model-test

bash tools/test_session_lifecycle.sh

python3 Resources/l10n/gen.py --check
./build.sh

#!/usr/bin/env python3
"""Keep meeting selections in memory and calendar mapping tests fixture-only."""

from pathlib import Path
import re


root = Path(__file__).resolve().parents[2]
for name in (
    "CalendarCoordinator.swift",
    "CalendarDomain.swift",
    "MeetingSessionContext.swift",
    "MeetingContextTerms.swift",
):
    path = root / "Sources" / "Kikishima" / name
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        for forbidden in ("UserDefaults", "@AppStorage", "selectedMeetingContext"):
            if forbidden in line:
                raise SystemExit(
                    f"FAIL {path.relative_to(root)}:{line_number}: "
                    f"meeting context must remain in memory; found {forbidden}"
                )

fixture_path = root / "tests" / "mac_calendar_provider" / "main.swift"
fixture = fixture_path.read_text()
for pattern in (
    r"\bEKEventStore\b",
    r"\bMacCalendarProvider\s*(?:\(|\.\s*init\s*\()",
    r"\brequest\w*Access\w*\s*\(",
    r"\bauthorizationStatus\s*\(",
):
    if re.search(pattern, fixture):
        raise SystemExit(
            "FAIL tests/mac_calendar_provider/main.swift: "
            "calendar tests must use only raw fixtures and pure mapping helpers"
        )

print("PASS: meeting context has no preference persistence; calendar mapping uses fixtures")

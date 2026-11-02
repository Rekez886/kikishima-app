from pathlib import Path

errors = []


def check(ok, message):
    print(("PASS " if ok else "FAIL wiring: ") + message)
    if not ok:
        errors.append(message)


main = Path("Sources/Kikishima/MainWindow.swift").read_text()
sim = Path("Sources/Kikishima/ShootSimulation.swift").read_text()
state = Path("Sources/Kikishima/CaptionState.swift").read_text()

start = main.index("Button { state.mainSection = .languages }")
end = main.index("CalendarMeetingCard", start)
task = main[start:end]
check("if ShootSimulation.requestedMode != nil {" in task, "captions task keeps the shoot branch")
check(
    "ShootSessionPolicy.refreshesModelInstallation(offscreenRender: ShootSimulation.isOffscreenRender)" in task,
    "captions task refreshes except for offscreen renders",
)
check(task.count("await state.refreshModelInstallation()") >= 2, "captions task refreshes in shoot and normal modes")
check("allLocales = state.meetingLocales; return" not in task, "captions task no longer returns before refreshing")
check("allLocales = state.meetingLocales" in task, "shoot caption list still uses meeting languages")

check("enum ShootSessionPolicy {" in sim, "pure shoot policy exists")
check(
    "func meetingLocales(current: String, existing: [String]) -> [String]" in sim,
    "meeting locale merge is pure and testable",
)
check(
    "func refreshesModelInstallation(offscreenRender: Bool) -> Bool" in sim,
    "offscreen refresh policy is pure and testable",
)
check(
    "nonisolated static var isOffscreenRender" in sim and "KIKISHIMA_SHOOT_RENDER" in sim,
    "offscreen render flag reads the render environment",
)
check("state.meetingLocales = [state.localeID]" not in sim, "shoot configure no longer replaces the language list")
check(
    "state.meetingLocales = ShootSessionPolicy.meetingLocales(current: state.localeID, existing: state.meetingLocales)" in sim,
    "shoot configure preserves enabled languages",
)

at = state.index("var meetingLocales:")
block = state[at:state.index("var modelProgress", at)]
check(
    "#if SHOOT || DEBUG" in block and "if ShootSimulation.requestedMode != nil { return }" in block,
    "shoot sessions do not persist meeting languages",
)
check(
    'UserDefaults.standard.set(meetingLocales, forKey: "meetingLocales")' in block,
    "normal sessions still persist meeting languages",
)

if errors:
    raise SystemExit(1)
print("PASS KK-061 wiring: caption refresh and shoot language list")

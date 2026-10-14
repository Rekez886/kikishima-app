# Whole-window diagnostic fixture

Run from the repository: `bash tools/window_preview/render.sh`.

Extracts the current MainWindowView and CaptionsHome verbatim, compiles them with synthetic state and placeholder calendar/records. Does not run the production app, use account credentials, request permissions or access real meeting files. Briefly opens a synthetic native window and captures only that window via screencapture.

Uses the same SwiftUI `Window` scene and 960×620 default size as the production app, then resizes to 780×520. Runs five languages in light/dark themes, covering signed-out, free and Pro fixtures. The process exits nonzero if the native split view extends outside its hosting view or capture fails.

Before the fix, the SwiftUI scene reproduced a 991pt split inside a 572pt host (including toolbar), with negative y. Explicit minimum widths on both column contents prevent narrow fitting-size measurement from inflating text height. Column-width preferences alone were insufficient.

Screenshots and per-case geometry are saved in `.build/window-preview/`. The fixture renders real main-window and home view code, with synthetic state and placeholder calendar/records. Other pages are placeholders; their interactions and actual audio/login flows are not covered.

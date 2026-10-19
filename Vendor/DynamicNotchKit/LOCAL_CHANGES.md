# Local DynamicNotchKit patch

Upstream: https://github.com/MrKai77/DynamicNotchKit
Version: 1.1.0, revision cd0b3e52d537db115ad3a9d89601f20e0bee8d27 (MIT; see LICENSE).

- Add `configureWindow` callback after initial frame assignment and before layout/display.
  Kikishima sets mouse handling, sharing policy, level and frame before the first visible frame.
- Package manifest omits the documentation-only plugin; upstream documentation assets are omitted, and runtime sources are otherwise preserved.
- Window lifecycle tests exercise the callback using real AppKit panels.

- 2026-10-18 audit 18: allow `expand(on:)` to migrate an already expanded island
  when the selected display ID changes, preserving same-screen no-op behavior.
- 2026-10-18 audit 19: retain the target by display ID on screen-parameter notifications,
  even if AppKit reorders/replaces NSScreen objects. If disconnected, use the host's
  `fallbackScreen` (meeting display), then an available display. Hidden panels stay hidden.
  Physical display disconnects still need manual verification.

- 2026-10-18 notch default: no-notch host frames begin 8pt below the screen top.
  Floating chrome uses pure black and rounded top corners, with the same host content
  in compact/expanded states. Notch detection also recognizes a built-in display with
  a positive top safe-area inset. The host now prioritizes a notched built-in display,
  otherwise the first/menu-bar display (superseding the audit 18 meeting-display rule).
  Covered by `tools/test_notch_default.sh`; hardware placement still needs visual QA.

When updating upstream, retain and rerun these tests before removing this patch.

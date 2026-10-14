# Local DynamicNotchKit patch

Upstream: https://github.com/MrKai77/DynamicNotchKit
Version: 1.1.0, revision cd0b3e52d537db115ad3a9d89601f20e0bee8d27 (MIT; see LICENSE).

- Add `configureWindow` callback after initial frame assignment and before layout/display.
  Kikishima sets mouse handling, sharing policy, level and frame before the first visible frame.
- Package manifest omits the documentation-only plugin; upstream documentation assets are omitted, and runtime sources are otherwise preserved.
- Window lifecycle tests exercise the callback using real AppKit panels.

When updating upstream, retain and rerun these tests before removing this patch.

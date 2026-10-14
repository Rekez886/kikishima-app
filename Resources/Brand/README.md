# Kikishima brand assets

Approved direction: C · キ, documented in `DESIGN.md`.

`Sources/Kikishima/BrandIcons.swift` is the geometric source for these assets and
all five 18 pt menu-bar template images. No font glyph or SF Symbol is used.
Run `bash tools/generate_icons.sh` to rebuild `AppIcon.icns` and `AppIcon-1024.png`.
The generated iconset and light/dark menu preview are in `.build/brand-assets/`.

- Brand: sRGB #FF3B1F with white geometry.
- Master: 1024 x 1024, stem 112 x 656; bars 512 x 104 and 608 x 104, rising 8 degrees.
- Legacy .icns: transparent rounded corners matching the approved preview;
  includes 16, 32, 128, 256 and 512 pt representations at 1x and 2x.
- Runtime: cached vector-backed NSImage templates, tinted by macOS.
- States: idle (45%), starting (35% bars, solid stem), running, paused,
  translation paused (top-right dot). Hover help and accessibility labels are localized.

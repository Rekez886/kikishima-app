---
name: Kikishima
description: 佐藤可士和 reduction for a macOS meeting-caption app — one 朱 block, one katakana, ink island, white paper.
status: all surfaces drafted 2026-09-15; polish pass 1 done (drawn icon set, core components bound to variables, i18n width audit)
colors:
  brand-red: "#FF3B1F"
  ink: "#1A1A1A"
  paper: "#FFFFFF"
  island: "#0F0F0F"
  caption-source: "rgba(255,255,255,0.68)"
  accent-system: "#3478F6"
  sidebar-bg: "#F6F7F9"
  card-bg: "#F7F7F7"
  control-bg: "#E4E4E4"
  label-primary: "#1D1D1F"
  label-secondary: "#6E6E73"
  label-tertiary: "#8E8E93"
typography:
  display:
    fontFamily: "SF Pro, PingFang SC, Hiragino Sans, Apple SD Gothic Neo"
    fontSize: "28px"
    fontWeight: 700
    lineHeight: 1.2
  body:
    fontFamily: "SF Pro, PingFang SC, Hiragino Sans, Apple SD Gothic Neo"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.25
  caption-translation:
    fontFamily: "SF Pro, PingFang SC, Hiragino Sans"
    fontSize: "24px"
    fontWeight: 600
    lineHeight: 1.3
  caption-source:
    fontFamily: "SF Pro, PingFang SC, Hiragino Sans"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.3
rounded:
  control: "6px"
  card: "10px"
  island: "18px"
  compact-panel: "14px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "14px"
  lg: "22px"
  page: "28px"
components:
  app-icon:
    backgroundColor: "{colors.brand-red}"
    textColor: "{colors.paper}"
    size: "1024px"
  menubar-glyph:
    textColor: "currentColor"
    size: "18px"
  island-idle:
    backgroundColor: "{colors.island}"
    textColor: "{colors.paper}"
    rounded: "{rounded.island}"
    height: "36px"
  button-primary:
    backgroundColor: "{colors.accent-system}"
    textColor: "{colors.paper}"
    rounded: "{rounded.control}"
    height: "22px"
---

## Overview

Kikishima (聞き島) is a macOS 26 menu-bar app that turns meeting audio into live translated captions under the camera. The visual world is a 佐藤可士和 reduction: one saturated 朱 block, one geometric katakana キ, ink for the island, white paper for the app. Brand lives in the icon, the island, and type; the main window stays on native macOS controls.

Decided so far: **app icon + menu-bar glyphs (2026-09-15, direction C · キ)**. Everything below the icon rows is provisional until those surfaces are built; the as-is main window values are recorded so redesign starts from measured truth, not memory.

## Colors

- `brand-red` is the only brand hue. It appears on the app icon, and may appear once per surface as an accent (e.g. the island's live dot). Never as a text color on white.
- `ink` / `island` are the dark surfaces: island, caption panel, menu-bar strip mocks. Caption source text is white at 68 %.
- The main window keeps macOS system colors (`accent-system`, `sidebar-bg`, `card-bg`, `control-bg`, label tiers). Redesign may replace `card-bg` grouping, but native control tints stay system.
- Dark mode: island values are the same in both modes; window colors follow the system.

## Typography

- System stack. Latin: SF Pro. CJK: PingFang SC / Hiragino Sans / Apple SD Gothic Neo per UI language. No third-party display face.
- Caption translation 24 px semibold default, user-adjustable 14–48; source line = translation × 0.55, min 12.
- Katakana キ in the icon is drawn geometry, not a font glyph.

## Layout

- Main window: sidebar 209 pt, content page padding 28, section gap 22, card padding 14. Min 780×520.
- Island: sits directly under the MacBook camera housing, top-center on external displays. Idle pill 180×36, expanded 720 wide.
- Japanese / Korean strings run 30–60 % longer than Chinese, English 50–100 %: size containers to the longest.

## Elevation & Depth

- Flat. The icon and island carry no shadow or gradient. The floating caption panel uses system window shadow only.

## Shapes

- Icon: sharp rectangles inside the system squircle mask. Horizontals tilt 8°.
- App chrome: controls 6, cards 10, island 18, compact panel 14. Pills only for small controls.

## Components

- **App icon**: `brand-red`, white キ (stem 112×656, bars 512×104 and 608×104 at 8°). Master 1024. The implemented legacy `.icns` carries transparent rounded corners matching the approved preview; source and provenance are in `Resources/Brand/README.md`.
- **Menu-bar glyph** (18 pt template, single color + alpha): idle キ 45 %; starting stem 100 % / bars 35 %; running 100 %; paused two vertical bars; translation paused キ + dot top-right.
- **Island** (designed 2026-09-15): idle pill 212×36 ink 100 %, radius 18, 朱 live dot 8 pt at x 16 + three level bars centered. Expanded 720×132 (compact) / 720×220 (full), ink 94 %, radius 22, padding 16, dot 6 pt + bars at top-left. Translation 24 Medium white, previous sentence 45–60 %, source 13 Regular 68 %, unfinished source italic 45 %. Banners: 34 pt tall, radius 10, 16 % tint of system yellow / orange / blue, white text 13, 16 % white action chip 22 pt, close glyph 70 %. Pause divider: 1 pt white 20 % rules + 11 pt label 50 %. Hover toolbar: 92×26 capsule white 14 % top-right inset 8, three 12 pt glyphs. Motion: spring 0.48 / 0.86, width before height, text fades after ~200 ms; Reduce Motion = crossfade.
- **Menu-bar popover** (designed 2026-09-15): 264 wide, padding 14, gap 10, radius 12, material `#F3F3F5` + 0.5 pt 12 % stroke, shadow 0/8/24 at 22 %. Status block at top (radius 10, padding 12/10): idle = 5 % black card, grey dot, title 13 Medium, sub 11 secondary; running = ink `#0F0F0F`, 朱 dot (orange when silent/stalled), three white bars, 3 pt level line green/orange on 15 % white track, device row white 60 % + 「切换 ⌵」85 %. Primary 34 pt radius 9: blue start / 朱-red stop, 13 Semibold white; secondary pause 26 pt 6 % black. Hotkey + account on one 11 pt line (orange when warning). Dividers 1 pt 10 %. Quick settings: popup chip 6 % black radius 5, switch 26×15, segmented 22 pt with white selected tab, text field 24 pt white + 12 % stroke. Menu items 13 pt, padding 4/6, shortcut 12 tertiary.
- **Main window shell** (designed 2026-09-15): sidebar `#F6F7F9` 209 wide, padding 9, brand row (18 pt red squircle キ + Kikishima 13 Semibold), nav rows 32/radius 6/selection `#2962D9`. Quota card radius 10 padding 12 in three states: not logged in = 5 % black card + blue 登录; free = white card 8 % stroke, remaining minutes 26 Bold, full-width 朱 升级 Pro, 10 pt price, blue invite link, truncating email + mini 退出登录; Pro = ink `#0F0F0F` card, red dot + Pro, white 60/45 % lines, 12 % white chip.
- **Captions home** (designed 2026-09-15): title 28 Bold + 13 status line; hero = island preview (slate `#3E4A5A` radius 12, 18 pt camera line, 120 notch, ink island 400 wide radius 16 bottom, preview text 14 Medium); controls row wraps: primary 184×39 + caption chips (switch, 219×23 segmented); language inline row (popups 150/120, arrow, link); calendar card 15 Semibold + 12 meta + secondary button; recent list 13 pt rows.
- **Records + summary** (designed 2026-09-15): header 24 Bold + 22 pt buttons (danger text 朱, disabled 40 %); search 320×24; list 196 wide on 3 % black, rows radius 6, selection `#2962D9`, name 12 / date 10; detail title 20 Bold, meta 12 secondary + link, status line 13 Medium with green check or orange pause + blue 重试; sections 15 Semibold, body 13, 4 pt ink bullets, 来源 chips 11 pt on 10 % blue; empty state 36 pt glyph + 15 Semibold + 12 secondary.
- **Onboarding** (designed 2026-09-15): 540×460, body padding 32/24, footer 52 pt on 3 % black; welcome = 96 pt キ squircle + 30 Bold wordmark; language tiles 150×56 (selected solid blue); meeting-language chips 153×36 (10 % blue + stroke when on, green check when downloaded, 40 pt progress); permission rows white radius 10 with 必需 tag 朱 12 %; sign-in tiles 476×44 white + 10 % stroke; ready page reuses the island preview.
- **Settings** (designed 2026-09-15): content `#F5F5F7`, form padding 24/20, group gap 18; group title 13 Semibold + white card radius 10 / 8 % stroke; rows 12/9 with 13 label + 11 secondary sub-copy + 8 % separators; system switch 26×15, segmented 22 pt, slider 4 pt track + 16 pt knob, secondary buttons 22 pt 6 % black; toolbar 48 pt translucent + hairline. Brand only as the red dot next to Pro.
- **Primary button**: system Prominent; do not recolor to brand red. Exception: 停止字幕 uses 朱 as the destructive-live color.

- **Icon set** (26 icons): 16 pt grid, 1.5 pt round stroke, currentColor. captions / history / glossary / languages / settings / help / calendar / doc / play / pause / stop / toggle-form / check / check-circle / chevron-updown / chevron-down / search / plus / sidebar / trash / folder / waveform / link-arrow / x / warning / info. Replaces SF Symbols in nav, section labels, buttons, banners, toolbar across all pages.
- **Core components** (bound to `macOS Semantic` variables): Button (kind primary/brand/secondary/danger × size regular 22/large 39, hug width), Switch (on/off), Segmented Item (selected/normal, hug), Sidebar Nav Item (selected/normal, icon slot), Live Dot (live 朱 / silent orange / idle 30 %), Chip/来源. New variables: `brand/red`, `island/bg`, `surface/slate`, `fill/secondaryButton`, `label/onAccent`.
- **Reference library**: Apple's official **macOS 26** Figma kit is available to this file; use it for native controls we did not redraw (sliders, popovers, alerts, window chrome) instead of inventing skins.

## Do's and Don'ts

- Do keep one brand color per surface. Don't add a second hue.
- Do draw icons as geometry. Don't set the キ as a typed character or use SF Symbols in the Dock icon.
- Don't paint the main window red or dark; the island is the only ink surface in a meeting.
- Don't add gradients, glass, or shadows to the icon or island.

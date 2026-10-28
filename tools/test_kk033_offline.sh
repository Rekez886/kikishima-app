#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
python3 tests/kk033_offline/r13_checks.py
python3 tests/kk033_offline/prepare_source.py "$KK_TEST_TMP_ROOT"
swiftc -parse-as-library Sources/Kikishima/CaptionPreviewText.swift "$KK_TEST_TMP_ROOT/SourceMatrix.swift" -o "$KK_TEST_TMP_ROOT/source-matrix"
"$KK_TEST_TMP_ROOT/source-matrix"
python3 tests/kk033_offline/prepare_priority.py "$KK_TEST_TMP_ROOT"
swiftc -parse-as-library Sources/Kikishima/CaptionStatusPriority.swift Sources/Kikishima/CaptionErrorStatus.swift Sources/Kikishima/TranslationConnectivityPolicy.swift \
  "$KK_TEST_TMP_ROOT/PriorityWiring.swift" tests/kk033_offline/priority.swift -o "$KK_TEST_TMP_ROOT/priority"
python3 tests/kk033_offline/prepare_one_status.py "$KK_TEST_TMP_ROOT"
swiftc -parse-as-library Sources/Kikishima/CaptionStatusPriority.swift Sources/Kikishima/CaptionErrorStatus.swift Sources/Kikishima/TranslationConnectivityPolicy.swift "$KK_TEST_TMP_ROOT/OneStatusWiring.swift" "$KK_TEST_TMP_ROOT/OneStatus.swift" -o "$KK_TEST_TMP_ROOT/one-status"
"$KK_TEST_TMP_ROOT/one-status" "$KK_TEST_TMP_ROOT/one-status-cases.json"
"$KK_TEST_TMP_ROOT/priority"
for mode in release DEBUG SHOOT; do
  flags=(-parse-as-library -emit-library)
  if [[ "$mode" != release ]]; then flags+=("-D$mode"); fi
  swiftc "${flags[@]}" "$KK_TEST_TMP_ROOT/LevelLog.swift" -o "$KK_TEST_TMP_ROOT/level-$mode.dylib"
  strings "$KK_TEST_TMP_ROOT/level-$mode.dylib" > "$KK_TEST_TMP_ROOT/level-$mode.strings"
  if [[ "$mode" == release ]]; then
    if rg 'KIKISHIMA_LEVEL_LOG|CaptionLevelLog' "$KK_TEST_TMP_ROOT/level-$mode.strings"; then exit 1; fi
  else
    rg -q KIKISHIMA_LEVEL_LOG "$KK_TEST_TMP_ROOT/level-$mode.strings"
  fi
done
echo 'PASS level log: release code/trigger absent, DEBUG and SHOOT trigger present'
swiftc -parse-as-library -DDEBUG "$KK_TEST_TMP_ROOT/LevelLogRuntime.swift" -o "$KK_TEST_TMP_ROOT/level-runtime"
env -u KIKISHIMA_LEVEL_LOG "$KK_TEST_TMP_ROOT/level-runtime" "$KK_TEST_TMP_ROOT/unset.log"
KIKISHIMA_LEVEL_LOG="$KK_TEST_TMP_ROOT/level.log" "$KK_TEST_TMP_ROOT/level-runtime" "$KK_TEST_TMP_ROOT/level.log"
KIKISHIMA_LEVEL_LOG="$KK_TEST_TMP_ROOT" "$KK_TEST_TMP_ROOT/level-runtime" "$KK_TEST_TMP_ROOT" unwritable
python3 tests/kk033_offline/prepare_isolation.py "$KK_TEST_TMP_ROOT"
swiftc -parse-as-library -DDEBUG "$KK_TEST_TMP_ROOT/MeterLog.swift" tests/kk033_offline/meter_log.swift -o "$KK_TEST_TMP_ROOT/meter-log"
KIKISHIMA_LEVEL_LOG="$KK_TEST_TMP_ROOT/meter.log" "$KK_TEST_TMP_ROOT/meter-log"
for mode in release DEBUG SHOOT; do
  flags=(-parse-as-library)
  if [[ "$mode" != release ]]; then flags+=("-D$mode"); fi
  swiftc "${flags[@]}" "$KK_TEST_TMP_ROOT/RecordsWiring.swift" "$KK_TEST_TMP_ROOT/LevelLog.swift" \
    Sources/Kikishima/TranscriptWriter.swift \
    tests/kk033_offline/records.swift \
    -o "$KK_TEST_TMP_ROOT/records-$mode"
  python3 tests/kk033_offline/make_records_fixture.py "$KK_TEST_TMP_ROOT/records-$mode-dir"
  KIKISHIMA_RECORDS_DIR="$KK_TEST_TMP_ROOT/records-$mode-dir" "$KK_TEST_TMP_ROOT/records-$mode"
  strings "$KK_TEST_TMP_ROOT/records-$mode" > "$KK_TEST_TMP_ROOT/records-$mode.strings"
  if [[ "$mode" == release ]]; then
    if rg 'KIKISHIMA_RECORDS_DIR|KIKISHIMA_LEVEL_LOG' "$KK_TEST_TMP_ROOT/records-$mode.strings"; then exit 1; fi
  fi
done
echo 'PASS production release isolation: records and level trigger strings absent'
python3 tests/kk033_offline/prepare.py "$KK_TEST_TMP_ROOT"
swiftc -parse-as-library Sources/Kikishima/TranslationConnectivityPolicy.swift \
  Sources/Kikishima/CaptionErrorStatus.swift Sources/Kikishima/CaptionStatusPriority.swift \
  "$KK_TEST_TMP_ROOT/Production.swift" \
  tests/kk033_offline/main.swift -o "$KK_TEST_TMP_ROOT/offline"
"$KK_TEST_TMP_ROOT/offline"
python3 tests/kk033_offline/prepare_surfaces.py "$KK_TEST_TMP_ROOT"
swiftc -parse-as-library Sources/Kikishima/CaptionStatusPriority.swift Sources/Kikishima/CaptionErrorStatus.swift Sources/Kikishima/CaptionIsland.swift "$KK_TEST_TMP_ROOT/SurfaceLayout.swift" tests/kk033_offline/surface_layout.swift -o "$KK_TEST_TMP_ROOT/surface-layout"
"$KK_TEST_TMP_ROOT/surface-layout" "$KK_TEST_TMP_ROOT/status-cases.json"
swiftc -parse-as-library Sources/Kikishima/CaptionIsland.swift "$KK_TEST_TMP_ROOT/CollapseWiring.swift" tests/kk033_offline/collapse.swift -o "$KK_TEST_TMP_ROOT/collapse"
"$KK_TEST_TMP_ROOT/collapse"
swiftc -parse-as-library "$KK_TEST_TMP_ROOT/AudioOnlyWiring.swift" tests/kk033_offline/audio_only.swift -o "$KK_TEST_TMP_ROOT/audio-only"
KIKISHIMA_SHOOT_AUDIO_ONLY=1 "$KK_TEST_TMP_ROOT/audio-only"
python3 tests/kk033_offline/prepare_widths.py "$KK_TEST_TMP_ROOT"
swiftc -parse-as-library Sources/Kikishima/CaptionStatusPriority.swift Sources/Kikishima/CaptionErrorStatus.swift Sources/Kikishima/TranslationConnectivityPolicy.swift "$KK_TEST_TMP_ROOT/WidthWiring.swift" tests/kk033_offline/measure_copy.swift -o "$KK_TEST_TMP_ROOT/measure-copy"
width_exit=0
"$KK_TEST_TMP_ROOT/measure-copy" tests/kk033_offline/status_copy.json "$KK_TEST_TMP_ROOT/rendered-widths.json" || width_exit=$?
python3 tests/kk033_offline/report_widths.py "$KK_TEST_TMP_ROOT/rendered-widths.json" "$KK_TEST_TMP_ROOT"
python3 tests/kk033_offline/prepare_menu_widths.py "$KK_TEST_TMP_ROOT"
swiftc -parse-as-library Sources/Kikishima/CaptionStatusPriority.swift Sources/Kikishima/CaptionErrorStatus.swift Sources/Kikishima/TranslationConnectivityPolicy.swift "$KK_TEST_TMP_ROOT/WidthWiring.swift" "$KK_TEST_TMP_ROOT/WidthProbes.swift" "$KK_TEST_TMP_ROOT/MenuWidthWiring.swift" tests/kk033_offline/measure_menu.swift -o "$KK_TEST_TMP_ROOT/measure-menu"
"$KK_TEST_TMP_ROOT/measure-menu" "$KK_TEST_TMP_ROOT/menu-widths.json" || width_exit=$?
if [[ "$width_exit" != 0 ]]; then exit "$width_exit"; fi
# Independent diagnostic regressions supplied beside the original wrapper inputs.
python3 tests/kk033_offline/r17_checks.py
for mode in DEBUG SHOOT; do
  swiftc -parse-as-library -D"$mode" Sources/Kikishima/ShootMenuState.swift \
    Sources/Kikishima/ShootMenuPlacement.swift Sources/Kikishima/ShootDiagnosticLog.swift \
    tests/kk033_offline/r17_runtime.swift -o "$KK_TEST_TMP_ROOT/r17-$mode"
  mkdir "$KK_TEST_TMP_ROOT/r17-$mode-dir"
  "$KK_TEST_TMP_ROOT/r17-$mode" "$KK_TEST_TMP_ROOT/r17-$mode-dir"
done
echo 'PASS KK-033: local connectivity and status priority, source display, isolated logs and records, offscreen geometry, five-language status widths, preview selector and diagnostic state machine'

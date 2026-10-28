#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
python3 tests/notch_fixture/check_wiring.py
vendor=Vendor/DynamicNotchKit/Sources/DynamicNotchKit/Utility/NSScreen+Extensions.swift
for mode in release DEBUG SHOOT; do
    flags=(-parse-as-library)
    if [[ "$mode" != release ]]; then flags+=("-D$mode"); fi
    mkdir -p "$test_dir/$mode"
    swiftc "${flags[@]}" -swift-version 6 -emit-library -emit-module -module-name DynamicNotchKit \
        -emit-module-path "$test_dir/$mode/DynamicNotchKit.swiftmodule" \
        "$vendor" -o "$test_dir/$mode/libDynamicNotchKit.dylib"
    if [[ "$mode" != SHOOT ]]; then
        swiftc "${flags[@]}" -emit-library Sources/Kikishima/ShootNotch.swift \
            Sources/Kikishima/CaptionIslandScreen.swift Sources/Kikishima/CaptionScreenPolicy.swift \
            -o "$test_dir/$mode/host.dylib"
        for artifact in "$test_dir/$mode/host.dylib" "$test_dir/$mode/libDynamicNotchKit.dylib"; do
            if strings "$artifact" | rg 'KIKISHIMA_SHOOT_NOTCH|KikishimaShootNotch|ShootNotch'; then exit 1; fi
        done
    fi
done
# Use the real argument helper without constructing app state or launching any app.
python3 - "$test_dir/Argument.swift" <<'PY'
from pathlib import Path
import sys
s = Path('Sources/Kikishima/ShootSimulation.swift').read_text()
a = s.index('    nonisolated static func argument(')
b = s.index('    nonisolated static func selectedInterfaceLanguage', a)
Path(sys.argv[1]).write_text('import Foundation\nenum ShootSimulation {\n' + s[a:b] + '}\n')
PY
swiftc -DSHOOT -swift-version 5 -parse-as-library -I "$test_dir/SHOOT" -L "$test_dir/SHOOT" \
    -lDynamicNotchKit -Xlinker -rpath -Xlinker "$test_dir/SHOOT" \
    "$test_dir/Argument.swift" Sources/Kikishima/ShootNotch.swift \
    Sources/Kikishima/CaptionIslandScreen.swift Sources/Kikishima/CaptionScreenPolicy.swift \
    Sources/Kikishima/CaptionIsland.swift tests/notch_fixture/NotchMeasurement.swift tests/notch_fixture/shoot.swift -o "$test_dir/notch-runtime"
"$test_dir/notch-runtime"
strings "$test_dir/notch-runtime" > "$test_dir/shoot.strings"
for required in KIKISHIMA_SHOOT_NOTCH KikishimaShootNotch ShootNotchConfiguration ShootNotchMask; do
    rg -q "$required" "$test_dir/shoot.strings"
done
strings "$test_dir/SHOOT/libDynamicNotchKit.dylib" > "$test_dir/vendor.strings"
rg -q ShootNotchInjection "$test_dir/vendor.strings"
if "$test_dir/notch-runtime" --validate -KikishimaShootNotch 'invalid' 2> "$test_dir/error.log"; then exit 1; fi
[[ "$(wc -l < "$test_dir/error.log" | tr -d ' ')" == 1 ]]
rg '^Invalid KikishimaShootNotch' "$test_dir/error.log"
echo 'PASS release/DEBUG isolation and SHOOT host/Vendor linking (no app launched)'

# Compile the actual entry in all three modes. Only unrelated app startup is
# stubbed: executing this harness never constructs or starts KikishimaApp.
cat > "$test_dir/EntryHelpers.swift" <<'SWIFT'
import Foundation
#if SHOOT || DEBUG
@MainActor enum ShootOpenMenu {
    static let shared = ShootOpenMenuHandle()
}
@MainActor final class ShootOpenMenuHandle { func start(openMenu: Bool = true) {} }
@MainActor enum ShootWindowLog { static func start() {} }
#endif
extension ShootSimulation {
    static var requestedOpenMenu: Bool { false }
    static func runIfRequested() -> Bool { print("SIMULATION_ENTRY"); return false }
}
enum AppLanguagePreference {
    static var processLanguage: String { print("LANGUAGE_ENTRY"); return "" }
    static func synchronizeSavedLanguage() -> String? { nil }
    static func requiresRelaunch(for language: String) -> Bool { false }
}
enum AppRelauncher { static func launchNewInstance() -> Bool { false } }
enum KikishimaApp { static func main() { print("APP_ENTRY_STUB") } }
SWIFT
for mode in release DEBUG SHOOT; do
    flags=(-swift-version 5)
    if [[ "$mode" != release ]]; then flags+=("-D$mode"); fi
    swiftc "${flags[@]}" -I "$test_dir/$mode" -L "$test_dir/$mode" \
        -lDynamicNotchKit -Xlinker -rpath -Xlinker "$test_dir/$mode" \
        Sources/Kikishima/main.swift Sources/Kikishima/ShootNotch.swift Sources/Kikishima/ShootDiagnosticLog.swift \
        "$test_dir/Argument.swift" "$test_dir/EntryHelpers.swift" -o "$test_dir/entry-$mode"
    strings "$test_dir/entry-$mode" > "$test_dir/entry-$mode.strings"
    nm "$test_dir/entry-$mode" > "$test_dir/entry-$mode.symbols"
    if [[ "$mode" != SHOOT ]]; then
        if rg 'KIKISHIMA_SHOOT_NOTCH|KikishimaShootNotch|ShootNotch' \
            "$test_dir/entry-$mode.strings" "$test_dir/entry-$mode.symbols"; then exit 1; fi
    else
        for required in KIKISHIMA_SHOOT_NOTCH KikishimaShootNotch ShootNotch; do
            rg -q "$required" "$test_dir/entry-$mode.strings"
        done
    fi
done
# A malformed CLI option must fail before simulation, language or app startup.
if "$test_dir/entry-SHOOT" -KikishimaShootNotch invalid \
    > "$test_dir/entry.stdout" 2> "$test_dir/entry.stderr"; then exit 1; else status=$?; fi
[[ "$status" == 1 && ! -s "$test_dir/entry.stdout" ]]
[[ "$(wc -l < "$test_dir/entry.stderr" | tr -d ' ')" == 1 ]]
rg '^Invalid KikishimaShootNotch' "$test_dir/entry.stderr"
# The environment trigger has the same early failure behavior.
if KIKISHIMA_SHOOT_NOTCH=invalid "$test_dir/entry-SHOOT" \
    > "$test_dir/entry.stdout" 2> "$test_dir/entry.stderr"; then exit 1; else status=$?; fi
[[ "$status" == 1 && ! -s "$test_dir/entry.stdout" ]]
[[ "$(wc -l < "$test_dir/entry.stderr" | tr -d ' ')" == 1 ]]
rg '^Invalid KikishimaShootNotch' "$test_dir/entry.stderr"
# Also cover the explicit option with no value.
if "$test_dir/entry-SHOOT" -KikishimaShootNotch \
    > "$test_dir/entry.stdout" 2> "$test_dir/entry.stderr"; then exit 1; else status=$?; fi
[[ "$status" == 1 && ! -s "$test_dir/entry.stdout" ]]
[[ "$(wc -l < "$test_dir/entry.stderr" | tr -d ' ')" == 1 ]]
rg '^Invalid KikishimaShootNotch' "$test_dir/entry.stderr"
env -u KIKISHIMA_SHOOT_NOTCH "$test_dir/entry-SHOOT" > "$test_dir/entry.stdout"
python3 - "$test_dir/entry.stdout" <<'PYTEST'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_text().splitlines() == ["SIMULATION_ENTRY", "LANGUAGE_ENTRY", "APP_ENTRY_STUB"]
PYTEST
echo 'PASS actual main.swift: release/DEBUG strings and symbols absent; SHOOT validates before startup (app stub only)'

# r16b: native menu placement, pure geometry only (no NSWindow/app constructed).
for mode in DEBUG SHOOT; do
    swiftc -parse-as-library -D"$mode" Sources/Kikishima/ShootMenuPlacement.swift \
        tests/kk033_offline/r16_menu_placement.swift -o "$test_dir/menu-placement-$mode"
    "$test_dir/menu-placement-$mode"
done
swiftc -parse-as-library -emit-library Sources/Kikishima/ShootMenuPlacement.swift -o "$test_dir/menu-placement-release.dylib"
if strings "$test_dir/menu-placement-release.dylib" | rg 'ShootMenuPlacement'; then exit 1; fi
echo 'PASS menu placement release isolation'

#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
export KK_NOTCH_TEST_PREFIX="kikishima-notch-default-test-${test_dir##*.}-"
export KK_TEST_NOTCH_ROOT="$test_dir"
mkdir "$test_dir/suites"
cleanup_notch_preferences() {
    python3 - <<'PY_CLEANUP'
from pathlib import Path
import os
import re
import stat
import subprocess

prefix = os.environ['KK_NOTCH_TEST_PREFIX']
if not re.fullmatch(r'kikishima-notch-default-test-[A-Za-z0-9]{6}-', prefix):
    raise RuntimeError('Unsafe run prefix')
preferences = Path.home() / 'Library/Preferences'
registered = {p.name for p in (Path(os.environ['KK_TEST_NOTCH_ROOT']) / 'suites').iterdir()}
pattern = re.compile(re.escape(prefix) + r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}')
# Inspect only this run. An unexpected name or symlink is an error, never adopted.
files = list(preferences.glob(prefix + '*.plist'))
for file in files:
    if file.name[:-6] not in registered:
        raise RuntimeError(f'Unregistered preference file: {file.name}')
for name in sorted(registered):
    if not pattern.fullmatch(name):
        raise RuntimeError(f'Unsafe suite name: {name}')
    file = preferences / (name + '.plist')
    def inspect():
        try:
            info = file.lstat()
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(info.st_mode):
            raise RuntimeError(f'Refusing non-regular preference file: {file.name}')
        return info
    inspect()
    # The domain may be cached even when no plist exists yet.
    result = subprocess.run(['/usr/bin/defaults', 'delete', name], capture_output=True, text=True)
    if result.returncode and 'not found' not in result.stderr and 'does not exist' not in result.stderr:
        raise RuntimeError(f'Cannot clear own preference domain: {name}: {result.stderr}')
    after = inspect()
    if after is not None:
        # defaults/cfprefsd may atomically rewrite the plist while deleting its
        # domain. That new inode is still this registered, run-specific suite.
        # Check identity only across our final inspection/unlink, not across
        # the operation which legitimately replaces the file.
        current = inspect()
        if current is None:
            continue
        if (after.st_dev, after.st_ino) != (current.st_dev, current.st_ino):
            raise RuntimeError(f'Preference file replaced after domain cleanup: {file.name}')
        file.unlink()
PY_CLEANUP
}
kk_test_add_cleanup cleanup_notch_preferences
python3 tests/notch_default/check_wiring.py
# Hygiene cases prepare once outside their signal-ready deadline. The caller's
# explicit output lives in its guarded workspace; this run still owns its suites.
mode="${1:-run}"
case "$mode" in
    run) binary="$test_dir/notch-default" ;;
    --prepare|--run-prepared)
        [[ $# == 2 && -n "$2" ]] || { echo "Expected binary path" >&2; exit 2; }
        binary="$2"
        ;;
    *) echo "Unknown notch test mode: $mode" >&2; exit 2 ;;
esac
if [[ "$mode" == --prepare && ( -e "$binary" || -L "$binary" ) ]]; then
    echo "Refusing to overwrite prepared binary: $binary" >&2
    exit 2
fi
if [[ "$mode" != --run-prepared ]]; then
    swiftc -module-cache-path "$test_dir/module-cache" \
    Sources/Kikishima/CaptionSurfacePreference.swift Sources/Kikishima/CaptionScreenPolicy.swift \
    Sources/Kikishima/CaptionIslandScreen.swift \
    Vendor/DynamicNotchKit/Sources/DynamicNotchKit/Utility/NSScreen+Extensions.swift \
    tests/notch_default/main.swift -o "$binary"
fi
if [[ "$mode" != --prepare ]]; then
    "$binary"
fi
if [[ "$mode" == run ]]; then
    swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
        Sources/Kikishima/CaptionIsland.swift Sources/Kikishima/CaptionScreenPolicy.swift \
        tests/notch_default/geometry.swift -o "$test_dir/capsule-geometry"
    "$test_dir/capsule-geometry"
fi

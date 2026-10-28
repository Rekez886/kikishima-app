#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
python3 tests/video_follow/check_wiring.py "$test_dir/Routing.swift"
swiftc -module-cache-path "$test_dir/module-cache" \
    Sources/Kikishima/CaptionSurfacePreference.swift \
    "$test_dir/Routing.swift" tests/video_follow/main.swift -o "$test_dir/video-follow"
"$test_dir/video-follow"

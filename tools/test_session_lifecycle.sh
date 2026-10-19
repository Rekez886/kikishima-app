#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."

test_dir="$KK_TEST_TMP_ROOT"
swiftc Sources/Kikishima/SessionLifecycle.swift Sources/Kikishima/CaptionIsland.swift tests/session_lifecycle/main.swift -o "$test_dir/session-lifecycle"
"$test_dir/session-lifecycle"

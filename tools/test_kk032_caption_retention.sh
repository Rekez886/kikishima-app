#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
if ! grep -q 'struct DesktopQueue' Sources/Kikishima/CaptionReadingPolicy.swift; then
    cat > "$KK_TEST_TMP_ROOT/main.swift" <<'SWIFT'
import Foundation
let visible = CaptionReadingPolicy.retainedIndices(readable: [true,false,false,false,false], recentLimit: 3)
if !visible.contains(1) { print("FAIL Boss: unfinished B was evicted"); exit(1) }
SWIFT
    swiftc Sources/Kikishima/CaptionReadingPolicy.swift "$KK_TEST_TMP_ROOT/main.swift" -o "$KK_TEST_TMP_ROOT/before"
    "$KK_TEST_TMP_ROOT/before"
    echo 'FAIL KK-032: desktop queue is missing' >&2
    exit 1
fi
python3 tests/kk032_caption_retention/prepare_history_limit.py "$KK_TEST_TMP_ROOT"
swiftc Sources/Kikishima/CaptionReadingPolicy.swift "$KK_TEST_TMP_ROOT/hierarchy.swift" tests/kk032_caption_retention/main.swift -o "$KK_TEST_TMP_ROOT/test"
"$KK_TEST_TMP_ROOT/test"
python3 tests/kk032_caption_retention/check_wiring.py
swiftc "$KK_TEST_TMP_ROOT/hierarchy.swift" "$KK_TEST_TMP_ROOT/history_limit/main.swift" -o "$KK_TEST_TMP_ROOT/history-limit"
"$KK_TEST_TMP_ROOT/history-limit" > "$KK_TEST_TMP_ROOT/history_limit.actual"
if ! diff -u tests/kk032_caption_retention/history_limit.golden "$KK_TEST_TMP_ROOT/history_limit.actual"; then
    echo 'FAIL KK-032: island historyLimit differs from the golden 864-input matrix' >&2
    exit 1
fi
printf 'PASS island historyLimit matches golden: 864 inputs, maximumHistory 3\n'
printf 'PASS KK-032 caption retention\n'

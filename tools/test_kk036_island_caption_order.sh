#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
result=0
python3 tests/kk036_island_caption_order/check_wiring.py || result=1
python3 tests/kk036_island_caption_order/prepare.py "$KK_TEST_TMP_ROOT/hierarchy.swift"
adapter=tests/kk036_island_caption_order/adapter.swift
if [[ "${KK036_ADAPTER:-}" == baseline ]]; then adapter=tests/kk036_island_caption_order/baseline_adapter.swift; fi
swiftc Sources/Kikishima/CaptionReadingPolicy.swift "$KK_TEST_TMP_ROOT/hierarchy.swift" "$adapter" tests/kk036_island_caption_order/main.swift -o "$KK_TEST_TMP_ROOT/island"
"$KK_TEST_TMP_ROOT/island" tests/kk036_island_caption_order/baseline.json || result=1
if [[ "$result" != 0 ]]; then exit "$result"; fi
printf 'PASS KK-036 island caption order\n'

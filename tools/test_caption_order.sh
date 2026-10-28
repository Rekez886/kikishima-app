#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
python3 tests/caption_order/check_wiring.py "$test_dir/Visibility.swift"
swiftc -module-cache-path "$test_dir/module-cache" "$test_dir/Visibility.swift" -o "$test_dir/visibility"
"$test_dir/visibility"
swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
    Sources/Kikishima/DesignTokens.swift tests/caption_order/main.swift -o "$test_dir/colors"
"$test_dir/colors"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/l10n_check.sh"
kk_l10n_check

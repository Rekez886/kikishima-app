#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
python3 tests/walkthrough_r7/check_wiring.py "$test_dir"
swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
    "$test_dir/Runtime.swift" -o "$test_dir/r7"
"$test_dir/r7"
swiftc -typecheck -module-cache-path "$test_dir/module-cache" "$test_dir/Helpers.swift"
swiftc -typecheck -module-cache-path "$test_dir/module-cache" \
    Sources/Kikishima/DesignTokens.swift Sources/Kikishima/HomeCaptionPreview.swift \
    "$test_dir/Views.swift"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/l10n_check.sh"
kk_l10n_check

#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
python3 tests/upgrade_entry/check_wiring.py "$test_dir/Visibility.swift"
swiftc -module-cache-path "$test_dir/module-cache" "$test_dir/Visibility.swift" -o "$test_dir/visibility"
"$test_dir/visibility"
python3 Resources/l10n/gen.py --check

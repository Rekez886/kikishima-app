#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."

python3 tests/app_language/check_wiring.py
swiftc -parse-as-library Sources/Kikishima/AppLanguage.swift \
    tests/app_language/main.swift -o "$KK_TEST_TMP_ROOT/app-language"
"$KK_TEST_TMP_ROOT/app-language"

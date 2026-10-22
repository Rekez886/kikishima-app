#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
python3 tests/billing/check_wiring.py "$KK_TEST_TMP_ROOT/BillingHarness.swift"
swiftc -parse-as-library -module-cache-path "$KK_TEST_TMP_ROOT/module-cache" \
  Sources/Kikishima/AuthResponsePolicy.swift Sources/Kikishima/PlanQuotaPolicy.swift \
  Sources/Kikishima/BillingPolicy.swift "$KK_TEST_TMP_ROOT/BillingHarness.swift" \
  tests/billing/main.swift -o "$KK_TEST_TMP_ROOT/billing"
"$KK_TEST_TMP_ROOT/billing"
node --test tests/billing/extension.mjs

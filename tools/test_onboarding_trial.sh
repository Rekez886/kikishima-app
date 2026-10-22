#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
swiftc Sources/Kikishima/CaptionReadingPolicy.swift Sources/Kikishima/OnboardingTrial.swift \
    tests/onboarding_trial/main.swift -o "$KK_TEST_TMP_ROOT/trial"
"$KK_TEST_TMP_ROOT/trial"

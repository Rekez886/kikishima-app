#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
python3 tests/accent_scope/check_wiring.py
test_dir="$KK_TEST_TMP_ROOT"
swiftc -typecheck -module-cache-path "$test_dir/module-cache" \
    Sources/Kikishima/DesignTokens.swift Sources/Kikishima/BrandIcons.swift \
    Sources/Kikishima/HomeCaptionPreview.swift Sources/Kikishima/OnboardingComponents.swift \
    tests/accent_scope/Fixtures.swift

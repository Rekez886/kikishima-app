#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
swiftc -parse-as-library Sources/Kikishima/SessionLifecycle.swift Sources/Kikishima/Translate.swift \
  Sources/Kikishima/HTTPFailurePolicy.swift Sources/Kikishima/TranslationRules.swift \
  tests/translation_deadline/main.swift -o "$KK_TEST_TMP_ROOT/translation-deadline"
"$KK_TEST_TMP_ROOT/translation-deadline"
node --test tests/translation_deadline/extension.mjs

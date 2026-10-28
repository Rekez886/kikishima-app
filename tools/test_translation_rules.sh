#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
swiftc Sources/Kikishima/SessionLifecycle.swift Sources/Kikishima/Translate.swift \
  Sources/Kikishima/HTTPFailurePolicy.swift Sources/Kikishima/TranslationRules.swift \
  Sources/Kikishima/ChunkDispatch.swift Sources/Kikishima/TranslationEnginePolicy.swift \
  Sources/Kikishima/LocalTranslate.swift tests/support/MLXModelControllerStub.swift \
  tests/translation_rules/main.swift -o "$test_dir/rules"
"$test_dir/rules"

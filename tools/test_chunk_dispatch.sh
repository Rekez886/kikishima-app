#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
swiftc Sources/Kikishima/SessionLifecycle.swift Sources/Kikishima/Translate.swift Sources/Kikishima/HTTPFailurePolicy.swift Sources/Kikishima/TranslationRules.swift Sources/Kikishima/PendingTextClock.swift \
  Sources/Kikishima/TranslationEnginePolicy.swift Sources/Kikishima/LocalTranslate.swift \
  tests/support/MLXModelControllerStub.swift Sources/Kikishima/ChunkDispatch.swift tests/chunk_dispatch/main.swift -o "$test_dir/dispatch"
"$test_dir/dispatch"

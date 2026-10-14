#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/kikishima-chunk-tests.XXXXXX)
swiftc Sources/Kikishima/Translate.swift Sources/Kikishima/TranslationRules.swift Sources/Kikishima/PendingTextClock.swift \
  Sources/Kikishima/ChunkDispatch.swift tests/chunk_dispatch/main.swift -o "$test_dir/dispatch"
"$test_dir/dispatch"
swiftc Sources/Kikishima/TranslationTiming.swift tests/translation_timing/main.swift -o "$test_dir/timing"
"$test_dir/timing"

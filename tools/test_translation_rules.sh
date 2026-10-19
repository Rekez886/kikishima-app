#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
server_pid=""
cleanup() { if [[ -n "$server_pid" ]]; then ps -p "$server_pid" -o pid=,command= >&2 || true; kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; }
kk_test_add_cleanup cleanup
swiftc Sources/Kikishima/Translate.swift Sources/Kikishima/HTTPFailurePolicy.swift Sources/Kikishima/TranslationRules.swift Sources/Kikishima/ChunkDispatch.swift tests/translation_rules/main.swift -o "$test_dir/rules"
"$test_dir/rules"
swiftc -parse-as-library Sources/Kikishima/Translate.swift Sources/Kikishima/HTTPFailurePolicy.swift Sources/Kikishima/TranslationRules.swift tests/translation_rules/network.swift -o "$test_dir/network"
python3 tests/translation_rules/server.py "$test_dir/port" &
server_pid=$!
for ((i=0; i<50; i++)); do [[ -s "$test_dir/port" ]] && break; sleep 0.1; done
"$test_dir/network" "$(cat "$test_dir/port")"

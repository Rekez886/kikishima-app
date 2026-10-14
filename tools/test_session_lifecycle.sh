#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d /tmp/kikishima-session-lifecycle.XXXXXX)
swiftc Sources/Kikishima/SessionLifecycle.swift Sources/Kikishima/CaptionIsland.swift tests/session_lifecycle/main.swift -o "$test_dir/session-lifecycle"
"$test_dir/session-lifecycle"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d /tmp/kikishima-history-test.XXXXXX)
swiftc Sources/Kikishima/HistoryPreview.swift tests/history_selection/main.swift -o "$test_dir/history-test"
"$test_dir/history-test"

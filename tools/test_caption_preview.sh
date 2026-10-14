#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc Sources/Kikishima/CaptionPreviewText.swift tests/caption_preview/main.swift -o "$test_dir/preview"
"$test_dir/preview"

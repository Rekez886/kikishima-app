#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
swiftc Sources/Kikishima/CaptionPreviewText.swift tests/caption_preview/main.swift -o "$test_dir/preview"
"$test_dir/preview"

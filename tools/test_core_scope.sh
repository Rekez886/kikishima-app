#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."

fail=0

check_absent() {
  local pattern="$1"
  local file="$2"
  if rg -n "$pattern" "$file" >"$KK_TEST_TMP_ROOT/kikishima-core-scope-hit.txt"; then
    cat "$KK_TEST_TMP_ROOT/kikishima-core-scope-hit.txt"
    fail=1
  fi
}

check_absent '浏览器扩展|下载扩展|chrome://extensions|openChromeExtensions|看网页视频' Sources/Kikishima/MainWindow.swift
check_absent '气泡模式（实验）|bubbleMode' Sources/Kikishima/MainWindow.swift
check_absent 'youtubeActive|浏览器扩展正在这个网页上显示字幕|NativeHost\.installManifest|launchedForExtension' Sources/Kikishima/App.swift
check_absent 'chrome-extension://|--native-host|NativeHost\.run' Sources/Kikishima/main.swift

if [[ "$fail" -ne 0 ]]; then
  echo "App still exposes video/extension/bubble entry points."
  exit 1
fi

echo "Core app scope is meeting-only."

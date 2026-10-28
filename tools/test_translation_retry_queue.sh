#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
swiftc Sources/Kikishima/TranslationRetryQueue.swift tests/translation_retry_queue/main.swift -o "$KK_TEST_TMP_ROOT/translation-retry-queue"
"$KK_TEST_TMP_ROOT/translation-retry-queue"

#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
python3 tests/mlx_warmup/check_wiring.py
swiftc -parse-as-library Sources/Kikishima/MLXWarmup.swift \
  tests/support/MLXModelControllerStub.swift tests/mlx_warmup/main.swift \
  -o "$test_dir/mlx-warmup"
"$test_dir/mlx-warmup"

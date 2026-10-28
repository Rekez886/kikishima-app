#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
# Stage A: missing production policy deliberately causes a named swiftc error.
# Stage B: extract into the path below AND wire real call sites to this policy.
sources=(tests/audit17/main.swift)
if [[ -f "Sources/Kikishima/AudioPermissionPolicy.swift" ]]; then sources+=("Sources/Kikishima/AudioPermissionPolicy.swift"); fi
swiftc -module-cache-path "$test_dir/module-cache" "${sources[@]}" -o "$test_dir/audit17"
"$test_dir/audit17"

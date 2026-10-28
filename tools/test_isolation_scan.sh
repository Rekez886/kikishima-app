#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."

python3 tests/isolation_scan/check_isolation.py --self-test
python3 tests/isolation_scan/check_isolation.py

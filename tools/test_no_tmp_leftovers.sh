#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
# A background loop can inherit ignored SIGINT. Restore it before creating the
# fixture children: Bash cannot install a trap for a signal ignored at exec.
python3 - "$KK_TEST_TMP_ROOT" <<'PY'
import runpy
import signal
import sys
signal.signal(signal.SIGINT, signal.default_int_handler)
sys.argv = ["tests/test_temp_hygiene.py", sys.argv[1]]
runpy.run_path(sys.argv[0], run_name="__main__")
PY

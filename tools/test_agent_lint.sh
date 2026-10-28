#!/usr/bin/env bash
# Report only: lint findings or execution failures must not block other work.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0

python3 tools/agent_lint/lint_agent_rules.py Sources || true
exit 0

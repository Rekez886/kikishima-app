#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

scripts=()
while IFS= read -r script; do
    scripts+=("$script")
done < <(
    for script in tools/test_*.sh; do
        if [[ -f "$script" && "$script" != tools/test_all.sh ]]; then
            printf '%s\n' "$script"
        fi
    done | LC_ALL=C sort
)

# Validate the entire requested subset before running any tests.
for requested in "$@"; do
    found=0
    for ((i = 0; i < ${#scripts[@]}; i++)); do
        name="${scripts[i]#tools/test_}"
        name="${name%.sh}"
        if [[ "$requested" == "$name" ]]; then found=1; break; fi
    done
    if [[ "$found" == 0 ]]; then
        printf 'Unknown test: %s\n' "$requested" >&2
        exit 2
    fi
done

passed=0
failed=0
for ((i = 0; i < ${#scripts[@]}; i++)); do
    script="${scripts[i]}"
    name="${script#tools/test_}"
    name="${name%.sh}"
    if [[ "$#" != 0 ]]; then
        selected=0
        for requested in "$@"; do
            if [[ "$requested" == "$name" ]]; then selected=1; break; fi
        done
        if [[ "$selected" == 0 ]]; then continue; fi
    fi
    log="$KK_TEST_TMP_ROOT/$name.log"
    started=$SECONDS
    if bash "$script" </dev/null >"$log" 2>&1; then
        passed=$((passed + 1))
        printf 'PASS %s (%ss)\n' "$name" "$((SECONDS - started))"
    else
        status=$?
        failed=$((failed + 1))
        printf 'FAIL %s (exit %s)\n' "$name" "$status"
        tail -n 40 "$log" >&2
    fi
done

total=$((passed + failed))
printf 'SUMMARY: PASS=%s FAIL=%s TOTAL=%s\n' "$passed" "$failed" "$total"
if [[ "$failed" != 0 || "$total" == 0 ]]; then exit 1; fi
exit 0

# Run after kk_test_init. Generate only inside this test's temporary workspace.
kk_l10n_check() (
    local repo mirror name status result=0
    if [[ -z "${KK_TEST_TMP_ROOT:-}" || ! -d "$KK_TEST_TMP_ROOT" ]]; then
        printf 'l10n check: call kk_test_init before kk_l10n_check\n' >&2
        return 1
    fi
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    mirror="$KK_TEST_TMP_ROOT/l10n-mirror"
    mkdir "$mirror" || { printf 'l10n check: cannot create fresh mirror\n' >&2; return 1; }
    mkdir -p "$mirror/Resources/l10n" "$mirror/tools" || return 1
    cp -p "$repo/Resources/l10n/gen.py" "$mirror/Resources/l10n/gen.py" || return 1
    ln -s "$repo/Sources" "$mirror/Sources" || return 1
    ln -s "$repo/tools/lib" "$mirror/tools/lib" || return 1
    cd "$mirror" || return 1
    if python3 "$mirror/Resources/l10n/gen.py"; then
        :
    else
        status=$?
        printf 'l10n check: generator failed (exit %s)\n' "$status" >&2
        return "$status"
    fi
    for name in en.json ja.json ko.json zh-Hant.json; do
        if ! cmp -s "$mirror/Resources/l10n/$name" "$repo/Resources/l10n/$name"; then
            printf 'l10n check: committed table stale or missing: Resources/l10n/%s (regenerated output differs)\n' "$name" >&2
            result=1
        fi
    done
    return "$result"
)

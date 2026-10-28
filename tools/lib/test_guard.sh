# Source from Bash test entry points, then call kk_test_init SCRIPT.
KK_GUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kk_test_cleanup() {
    local status="${1:-0}" callback
    trap - EXIT INT TERM
    for callback in "${KK_TEST_CLEANUP_CALLBACKS[@]}"; do
        "$callback" || status=1
    done
    # Script-created temporary paths are removed directly, not
    # sent to Trash. Exact mktemp result only; explicit output stays preserved.
    if [[ -n "${KK_TEST_TMP_ROOT:-}" && ! -L "$KK_TEST_TMP_ROOT" ]]; then
        case "$KK_TEST_TMP_ROOT" in
            /tmp/kikishima-test.*|/private/tmp/kikishima-test.*)
                if [[ "${KK_TEST_TMP_ROOT%/*}" == /tmp || "${KK_TEST_TMP_ROOT%/*}" == /private/tmp ]]; then
                    rm -rf -- "$KK_TEST_TMP_ROOT" || status=1
                else
                    printf '拒绝清理不安全路径：%s\n' "$KK_TEST_TMP_ROOT" >&2; status=1
                fi ;;
            *) printf '拒绝清理非本次临时目录：%s\n' "$KK_TEST_TMP_ROOT" >&2; status=1 ;;
        esac
    fi
    exit "$status"
}

kk_test_add_cleanup() { KK_TEST_CLEANUP_CALLBACKS+=("$1"); }

kk_test_init() {
    export PYTHONDONTWRITEBYTECODE=1
    python3 "$KK_GUARD_LIB_DIR/test_guard.py" --check "$1" || exit "$?"
    KK_TEST_CLEANUP_CALLBACKS=(:)
    # Do not allocate scratch space until the disk gate has passed.
    KK_TEST_TMP_ROOT="$(mktemp -d /tmp/kikishima-test.XXXXXX)" || exit 1
    readonly KK_TEST_TMP_ROOT
    trap 'kk_test_cleanup "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    export TMPDIR="$KK_TEST_TMP_ROOT/"
    export CLANG_MODULE_CACHE_PATH="$KK_TEST_TMP_ROOT/clang-cache"
}

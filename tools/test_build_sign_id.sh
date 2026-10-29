#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p "$KK_TEST_TMP_ROOT/fakebin" "$KK_TEST_TMP_ROOT/project/build"
cp build.sh "$KK_TEST_TMP_ROOT/project/build.sh"
cat > "$KK_TEST_TMP_ROOT/fakebin/security" <<'FAKE'
#!/bin/bash
printf 'called\n' > "$KK_TEST_TMP_ROOT/security-called"
printf '  1) ABC123 "Developer ID Application: Example (TEAM123)"\n'
FAKE
cat > "$KK_TEST_TMP_ROOT/fakebin/swift" <<'FAKE'
#!/bin/bash
printf 'called\n' > "$KK_TEST_TMP_ROOT/swift-called"
exit 1
FAKE
chmod +x "$KK_TEST_TMP_ROOT/fakebin/security" "$KK_TEST_TMP_ROOT/fakebin/swift"
export KK_TEST_TMP_ROOT
export PATH="$KK_TEST_TMP_ROOT/fakebin:$PATH"
printf 'sentinel\n' > "$KK_TEST_TMP_ROOT/project/build/sentinel"
missing='Missing Identity For Test'
if SIGN_ID="$missing" bash "$KK_TEST_TMP_ROOT/project/build.sh" >"$KK_TEST_TMP_ROOT/a.out" 2>"$KK_TEST_TMP_ROOT/a.err"; then
    echo 'FAIL: missing identity succeeded' >&2; exit 1
fi
grep -F 'ERROR' "$KK_TEST_TMP_ROOT/a.err" >/dev/null
if grep -F -- "$missing" "$KK_TEST_TMP_ROOT/a.out" "$KK_TEST_TMP_ROOT/a.err" >/dev/null; then
    echo 'FAIL: missing identity appeared in output' >&2; exit 1
fi
[ ! -e "$KK_TEST_TMP_ROOT/swift-called" ]
[ -f "$KK_TEST_TMP_ROOT/project/build/sentinel" ]
if grep -F 'SIGNED: ad-hoc' "$KK_TEST_TMP_ROOT/a.out" "$KK_TEST_TMP_ROOT/a.err" >/dev/null; then
    echo 'FAIL: missing identity fell back to ad-hoc' >&2; exit 1
fi

if SIGN_ID='Developer ID Application: Example (TEAM123)' bash "$KK_TEST_TMP_ROOT/project/build.sh" >"$KK_TEST_TMP_ROOT/b.out" 2>"$KK_TEST_TMP_ROOT/b.err"; then
    echo 'FAIL: fake swift unexpectedly succeeded' >&2; exit 1
fi
[ -f "$KK_TEST_TMP_ROOT/swift-called" ]
if grep -F 'ERROR' "$KK_TEST_TMP_ROOT/b.err" >/dev/null; then
    echo 'FAIL: valid identity reported a preflight error' >&2; exit 1
fi

# Isolate invocation markers for the no-SIGN_ID case without deleting files.
mv "$KK_TEST_TMP_ROOT/swift-called" "$KK_TEST_TMP_ROOT/swift-called-b"
mv "$KK_TEST_TMP_ROOT/security-called" "$KK_TEST_TMP_ROOT/security-called-b"
if env -u SIGN_ID bash "$KK_TEST_TMP_ROOT/project/build.sh" >"$KK_TEST_TMP_ROOT/c.out" 2>"$KK_TEST_TMP_ROOT/c.err"; then
    echo 'FAIL: fake swift unexpectedly succeeded' >&2; exit 1
fi
[ -f "$KK_TEST_TMP_ROOT/swift-called" ]
[ ! -e "$KK_TEST_TMP_ROOT/security-called" ]
grep -F 'WARNING' "$KK_TEST_TMP_ROOT/c.err" >/dev/null
echo 'PASS build SIGN_ID preflight'

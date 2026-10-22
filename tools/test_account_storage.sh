#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_guard.sh"
kk_test_init "${BASH_SOURCE[0]}"
cd "$(dirname "$0")/.."
test_dir="$KK_TEST_TMP_ROOT"
sources=(Sources/Kikishima/SessionLifecycle.swift Sources/Kikishima/Translate.swift
    Sources/Kikishima/HTTPFailurePolicy.swift Sources/Kikishima/TranslationRules.swift
    tests/account_storage/main.swift)
for build in release DEBUG SHOOT; do
    if [[ "$build" == release ]]; then
        swiftc "${sources[@]}" -o "$test_dir/$build"
    else
        swiftc "-D$build" "${sources[@]}" -o "$test_dir/$build"
    fi
    "$test_dir/$build"
    for bundle in com.kikishima.mac com.kikishima.mac.r11test; do
        fixture="$test_dir/$build-$bundle.app/Contents"
        mkdir -p "$fixture/MacOS"
        cp "$test_dir/$build" "$fixture/MacOS/AccountStorageTest"
        cat > "$fixture/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle</string>
<key>CFBundleExecutable</key><string>AccountStorageTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
        "$fixture/MacOS/AccountStorageTest" "$bundle"
    done
done
# Check real account-state call sites, without constructing the app singleton.
python3 - <<'PY'
from pathlib import Path
import re
state = Path("Sources/Kikishima/CaptionState.swift").read_text()
for key in ["plan", "planExpires", "accountEmail", "installID", "activationId"]:
    assert f'AccountPreferences.string(forKey: "{key}")' in state, key
    assert re.search(rf'AccountPreferences.set\([^\n]*forKey: "{key}"', state), key
    assert not re.search(rf'UserDefaults.standard[^\n]*forKey: "{key}"', state), key
assert 'var sessionToken: String = SessionTokenStore.load()' in state
assert 'SessionTokenStore.save(sessionToken)' in state
assert 'sessionToken: { SessionTokenStore.load() }' in state
print("PASS: real login, summary client, metadata and license binding use isolated storage")
PY

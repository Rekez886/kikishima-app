#!/bin/bash
# KK-055 release verification for Kikishima.
#
# Usage: scripts/verify-release.sh <dmg> <version> [evidence dir]
#
# Read-only checks on a finished dmg. Every item writes evidence to the
# evidence directory; summary.txt and result.json collect the results.
# Default evidence directory: dist/verify-<version>-<UTC timestamp>.
# Exit codes: 0 all required items pass, 1 at least one required item fails,
# 2 usage error (bad arguments, missing dmg, unusable evidence directory).
#
# The quarantine item is informational only. The app staple check is
# informational too: only the dmg is notarized and stapled (KK-055 PM decision).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PLISTBUDDY=/usr/libexec/PlistBuddy
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-526RV9TVKZ}"

usage() {
  printf 'usage: %s <dmg> <version> [evidence dir]\n' "$0" >&2
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage
  exit 2
fi
DMG="$1"
VERSION="$2"
EV_ARG="${3:-}"

case "$VERSION" in
  *[!0-9A-Za-z._-]*|"")
    printf 'ERROR: invalid version: %s\n' "$VERSION" >&2
    exit 2
    ;;
esac

# Validate the input before creating anything on disk.
if [ ! -f "$DMG" ]; then
  printf 'ERROR: dmg not found or not a regular file: %s\n' "$DMG" >&2
  exit 2
fi
if [ ! -r "$DMG" ]; then
  printf 'ERROR: dmg is not readable: %s\n' "$DMG" >&2
  exit 2
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [ -z "$EV_ARG" ]; then
  EV="$ROOT/dist/verify-$VERSION-$STAMP"
  if [ -e "$EV" ]; then
    printf 'ERROR: default evidence directory already exists: %s\n' "$EV" >&2
    exit 2
  fi
  if ! mkdir -p "$EV"; then
    printf 'ERROR: cannot create evidence directory: %s\n' "$EV" >&2
    exit 2
  fi
else
  EV="$EV_ARG"
  if [ -e "$EV" ]; then
    if [ ! -d "$EV" ]; then
      printf 'ERROR: evidence path exists and is not a directory: %s\n' "$EV" >&2
      exit 2
    fi
    if [ -n "$(ls -A "$EV")" ]; then
      printf 'ERROR: evidence directory is not empty: %s\n' "$EV" >&2
      exit 2
    fi
  else
    if ! mkdir -p "$EV"; then
      printf 'ERROR: cannot create evidence directory: %s\n' "$EV" >&2
      exit 2
    fi
  fi
fi

# --- item bookkeeping -------------------------------------------------------
R_NAMES=("")
R_RESULTS=("")
R_MEASURED=("")
R_CRIT=("")
IDX=0
OVERALL=0
SHA256=""

begin_item() {
  ITEM_FILE="$EV/$1-$2.txt"
  ITEM_NAME="$3"
  ITEM_CMD="$4"
  ITEM_PASS="$5"
  ITEM_CRIT="$6"
  ITEM_MEASURED=""
  ITEM_RESULT="fail"
  : > "$ITEM_FILE"
  printf 'ITEM: %s (%s)\nCOMMAND: %s\nPASS CRITERIA: %s\n\n' "$1" "$3" "$4" "$5" >> "$ITEM_FILE"
}

rec() {
  printf '%s\n' "$*" >> "$ITEM_FILE"
}

measured() {
  ITEM_MEASURED="$1"
}

set_result() {
  ITEM_RESULT="$1"
}

end_item() {
  printf '\nMEASURED: %s\nRESULT: %s\n' "$ITEM_MEASURED" "$ITEM_RESULT" >> "$ITEM_FILE"
  IDX=$((IDX + 1))
  R_NAMES[$IDX]="$ITEM_NAME"
  R_RESULTS[$IDX]="$ITEM_RESULT"
  R_MEASURED[$IDX]="$ITEM_MEASURED"
  R_CRIT[$IDX]="$ITEM_CRIT"
  if [ "$ITEM_CRIT" = "1" ] && [ "$ITEM_RESULT" != "pass" ]; then
    OVERALL=1
  fi
}

as_count() {
  case "$1" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

MOUNTED=0
MNT=""

cleanup() {
  RC=$?
  trap - EXIT HUP INT TERM
  if [ "$MOUNTED" -eq 1 ]; then
    if hdiutil detach "$MNT" >/dev/null 2>&1; then
      printf 'DETACHED: %s\n' "$MNT"
    elif hdiutil detach "$MNT" -force >/dev/null 2>&1; then
      printf 'DETACHED (force): %s\n' "$MNT"
    else
      printf 'WARNING: still mounted at %s; detach manually if needed\n' "$MNT" >&2
    fi
  fi
  exit "$RC"
}

printf 'DMG: %s\nVERSION: %s\nEVIDENCE: %s\n' "$DMG" "$VERSION" "$EV"

# --- 1. sha256 --------------------------------------------------------------
begin_item 01 sha256 "dmg sha256" "shasum -a 256 <dmg>" "exit 0 and 64 lowercase hex chars" 1
if OUT="$(shasum -a 256 "$DMG" 2>&1)"; then
  RC=0
else
  RC=$?
fi
rec "exit=$RC"
rec "$OUT"
OK=0
if [ "$RC" -ne 0 ]; then
  OK=1
else
  SHA256="$(printf '%s\n' "$OUT" | sed -n 's/ .*//p')"
  SHA256="${SHA256%%$'\n'*}"
  case "$SHA256" in
    *[!0-9a-f]*) OK=1 ;;
    *)
      if [ "${#SHA256}" -ne 64 ]; then
        OK=1
      fi
      ;;
  esac
fi
measured "sha256=$SHA256"
if [ "$OK" -eq 0 ]; then
  set_result pass
fi
end_item

# --- 2. dmg signature -------------------------------------------------------
begin_item 02 dmg-signature "dmg signature" "codesign --verify --verbose=2 <dmg>; codesign -dvv <dmg>" "verify exit 0; leaf Authority starts with 'Developer ID Application:'; TeamIdentifier=$EXPECTED_TEAM_ID; Timestamp present" 1
OK=0
if OUT="$(codesign --verify --verbose=2 "$DMG" 2>&1)"; then
  RC=0
else
  RC=$?
fi
rec "codesign --verify: exit=$RC"
rec "$OUT"
if [ "$RC" -ne 0 ]; then
  OK=1
fi
SIGINFO="$(codesign -dvv "$DMG" 2>&1 || true)"
rec "codesign -dvv:"
rec "$SIGINFO"
LEAF="$(printf '%s\n' "$SIGINFO" | sed -n 's/^Authority=//p')"
LEAF="${LEAF%%$'\n'*}"
TEAM="$(printf '%s\n' "$SIGINFO" | sed -n 's/^TeamIdentifier=//p')"
TEAM="${TEAM%%$'\n'*}"
case "$LEAF" in
  "Developer ID Application:"*) ;;
  *) OK=1 ;;
esac
if [ "$TEAM" != "$EXPECTED_TEAM_ID" ]; then
  OK=1
fi
case "$SIGINFO" in
  *"Timestamp="*) ;;
  *) OK=1 ;;
esac
measured "authority=$LEAF; team=$TEAM"
if [ "$OK" -eq 0 ]; then
  set_result pass
fi
end_item

# --- 3. dmg gatekeeper ------------------------------------------------------
begin_item 03 dmg-gatekeeper "dmg gatekeeper" "spctl -a -vv -t open --context context:primary-signature <dmg>" "exit 0, output has 'accepted' and 'source=Notarized Developer ID'" 1
if OUT="$(spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1)"; then
  RC=0
else
  RC=$?
fi
rec "exit=$RC"
rec "$OUT"
OK=0
if [ "$RC" -ne 0 ]; then
  OK=1
fi
case "$OUT" in
  *accepted*) ;;
  *) OK=1 ;;
esac
case "$OUT" in
  *"source=Notarized Developer ID"*) ;;
  *) OK=1 ;;
esac
measured "exit=$RC"
if [ "$OK" -eq 0 ]; then
  set_result pass
fi
end_item

# --- 4. dmg staple and integrity -------------------------------------------
begin_item 04 dmg-integrity "dmg staple and integrity" "xcrun stapler validate <dmg>; hdiutil verify <dmg>" "both exit 0" 1
OK=0
if OUT="$(xcrun stapler validate "$DMG" 2>&1)"; then
  RC=0
else
  RC=$?
fi
ST_RC="$RC"
rec "stapler validate: exit=$RC"
rec "$OUT"
if [ "$RC" -ne 0 ]; then
  OK=1
fi
if OUT="$(hdiutil verify "$DMG" 2>&1)"; then
  RC=0
else
  RC=$?
fi
HD_RC="$RC"
rec "hdiutil verify: exit=$RC"
rec "$OUT"
if [ "$RC" -ne 0 ]; then
  OK=1
fi
measured "stapler=$ST_RC; verify=$HD_RC"
if [ "$OK" -eq 0 ]; then
  set_result pass
fi
end_item

# --- 5. mount contents ------------------------------------------------------
begin_item 05 mount "mounted volume contents" "hdiutil attach -nobrowse -readonly -mountpoint <tmp> <dmg>; ls -A; readlink Applications" "attach exit 0; entries are Kikishima.app and Applications (OS metadata ignored); Applications links to /Applications" 1
MNT="$(mktemp -d "${TMPDIR:-/tmp}/kikishima-verify.XXXXXX")"
trap cleanup EXIT HUP INT TERM
rec "mountpoint=$MNT"
if OUT="$(hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" 2>&1)"; then
  RC=0
else
  RC=$?
fi
rec "attach exit=$RC"
rec "$OUT"
APP="$MNT/Kikishima.app"
if [ "$RC" -eq 0 ]; then
  MOUNTED=1
  ENTRIES="$(ls -A "$MNT" 2>&1 || true)"
  rec "ls -A:"
  rec "$ENTRIES"
  APP_PRESENT=0
  APPS_LINK=0
  EXTRA=""
  while IFS= read -r entry; do
    case "$entry" in
      "") ;;
      Kikishima.app) APP_PRESENT=1 ;;
      Applications) ;;
      .fseventsd|.Trashes|.DS_Store|.VolumeIcon.icns) ;;
      *) EXTRA="$EXTRA $entry" ;;
    esac
  done <<EOF
$ENTRIES
EOF
  if [ -L "$MNT/Applications" ]; then
    TARGET="$(readlink "$MNT/Applications")"
    rec "Applications -> $TARGET"
    if [ "$TARGET" = "/Applications" ]; then
      APPS_LINK=1
    fi
  else
    rec "Applications is missing or not a symlink"
  fi
  measured "extra=${EXTRA:-none}; app=$APP_PRESENT; link=$APPS_LINK"
  if [ "$APP_PRESENT" -eq 1 ] && [ "$APPS_LINK" -eq 1 ] && [ -z "$EXTRA" ]; then
    set_result pass
  fi
else
  measured "mount failed"
fi
end_item

# --- 6. app signature, notarization, staple (staple info only) -------------
begin_item 06 app-signature "app signature and notarization" "codesign --verify --deep --strict <app>; codesign -dvv <app>; spctl -a -vv -t exec <app>; xcrun stapler validate <app>" "verify exit 0; flags include runtime; leaf Authority starts with 'Developer ID Application:'; TeamIdentifier=$EXPECTED_TEAM_ID; spctl accepted with source=Notarized Developer ID; app staple is informational" 1
if [ "$MOUNTED" -ne 1 ]; then
  rec "skipped: the dmg is not mounted"
  measured "mount unavailable"
else
  OK=0
  if OUT="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)"; then
    RC=0
  else
    RC=$?
  fi
  rec "codesign --verify: exit=$RC"
  rec "$OUT"
  if [ "$RC" -ne 0 ]; then
    OK=1
  fi
  SIGINFO="$(codesign -dvv "$APP" 2>&1 || true)"
  rec "codesign -dvv:"
  rec "$SIGINFO"
  LEAF="$(printf '%s\n' "$SIGINFO" | sed -n 's/^Authority=//p')"
  LEAF="${LEAF%%$'\n'*}"
  TEAM="$(printf '%s\n' "$SIGINFO" | sed -n 's/^TeamIdentifier=//p')"
  TEAM="${TEAM%%$'\n'*}"
  FLAGS="$(printf '%s\n' "$SIGINFO" | sed -n 's/^flags=//p')"
  FLAGS="${FLAGS%%$'\n'*}"
  case "$LEAF" in
    "Developer ID Application:"*) ;;
    *) OK=1 ;;
  esac
  if [ "$TEAM" != "$EXPECTED_TEAM_ID" ]; then
    OK=1
  fi
  case "$FLAGS" in
    *runtime*) ;;
    *) OK=1 ;;
  esac
  if OUT="$(spctl -a -vv -t exec "$APP" 2>&1)"; then
    RC=0
  else
    RC=$?
  fi
  rec "spctl exec: exit=$RC"
  rec "$OUT"
  if [ "$RC" -ne 0 ]; then
    OK=1
  fi
  case "$OUT" in
    *accepted*) ;;
    *) OK=1 ;;
  esac
  case "$OUT" in
    *"source=Notarized Developer ID"*) ;;
    *) OK=1 ;;
  esac
  if OUT="$(xcrun stapler validate "$APP" 2>&1)"; then
    RC=0
  else
    RC=$?
  fi
  rec "app stapler validate (info only): exit=$RC"
  rec "$OUT"
  measured "authority=$LEAF; team=$TEAM; flags=$FLAGS"
  if [ "$OK" -eq 0 ]; then
    set_result pass
  fi
fi
end_item

# --- 7. app contents --------------------------------------------------------
begin_item 07 app-contents "app contents" "PlistBuddy CFBundleShortVersionString; autoupdate key scan; Sparkle framework and bundle checks; codesign verification of mlx.metallib" "version matches argument; no autoupdate key; no Sparkle framework; no Pow_Pow.bundle or swift-crypto_Crypto.bundle; mlx.metallib present and signed by Developer ID (verify exit 0, leaf Authority starts with 'Developer ID Application:', TeamIdentifier=$EXPECTED_TEAM_ID, Timestamp present)" 1
if [ "$MOUNTED" -ne 1 ]; then
  rec "skipped: the dmg is not mounted"
  measured "mount unavailable"
else
  OK=0
  V_PLIST="$APP/Contents/Info.plist"
  SHORT="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$V_PLIST" 2>/dev/null || true)"
  rec "CFBundleShortVersionString=$SHORT"
  if [ "$SHORT" != "$VERSION" ]; then
    OK=1
  fi
  if grep -q '<key>SU' "$V_PLIST"; then
    rec "autoupdate key present"
    OK=1
  else
    rec "autoupdate key absent"
  fi
  if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    rec "Sparkle.framework present"
    OK=1
  else
    rec "Sparkle.framework absent"
  fi
  if [ -e "$APP/Pow_Pow.bundle" ]; then
    rec "Pow_Pow.bundle present"
    OK=1
  else
    rec "Pow_Pow.bundle absent"
  fi
  if [ -e "$APP/swift-crypto_Crypto.bundle" ]; then
    rec "swift-crypto_Crypto.bundle present"
    OK=1
  else
    rec "swift-crypto_Crypto.bundle absent"
  fi
  if [ -f "$APP/Contents/MacOS/mlx.metallib" ]; then
    rec "mlx.metallib present ($(stat -f%z "$APP/Contents/MacOS/mlx.metallib") bytes)"
    ML_PATH="$APP/Contents/MacOS/mlx.metallib"
    if ML_OUT="$(codesign --verify --strict --verbose=2 "$ML_PATH" 2>&1)"; then
      ML_RC=0
    else
      ML_RC=$?
    fi
    rec "metallib codesign --verify: exit=$ML_RC"
    rec "$ML_OUT"
    if [ "$ML_RC" -ne 0 ]; then
      OK=1
    fi
    ML_SIGINFO="$(codesign -dvv "$ML_PATH" 2>&1 || true)"
    rec "metallib codesign -dvv:"
    rec "$ML_SIGINFO"
    ML_LEAF="$(printf '%s\n' "$ML_SIGINFO" | sed -n 's/^Authority=//p')"
    ML_LEAF="${ML_LEAF%%$'\n'*}"
    ML_TEAM="$(printf '%s\n' "$ML_SIGINFO" | sed -n 's/^TeamIdentifier=//p')"
    ML_TEAM="${ML_TEAM%%$'\n'*}"
    case "$ML_LEAF" in
      "Developer ID Application:"*) ;;
      *) OK=1 ;;
    esac
    if [ "$ML_TEAM" != "$EXPECTED_TEAM_ID" ]; then
      OK=1
    fi
    case "$ML_SIGINFO" in
      *"Timestamp="*) ;;
      *) OK=1 ;;
    esac
  else
    rec "mlx.metallib missing"
    OK=1
  fi
  measured "version=$SHORT; metallib_authority=${ML_LEAF:-none}; metallib_team=${ML_TEAM:-none}"
  if [ "$OK" -eq 0 ]; then
    set_result pass
  fi
fi
end_item

# --- 8. entitlements --------------------------------------------------------
begin_item 08 entitlements "signature entitlements" "codesign -d --entitlements :- <app>" "exactly com.apple.security.device.audio-input and com.apple.security.personal-information.calendars, both true" 1
if [ "$MOUNTED" -ne 1 ]; then
  rec "skipped: the dmg is not mounted"
  measured "mount unavailable"
else
  OUT="$(codesign -d --entitlements :- "$APP" 2>&1 || true)"
  rec "codesign --entitlements:"
  rec "$OUT"
  NORM="$(printf '%s\n' "$OUT" | awk '{ gsub(/></, ">\n<"); print }')"
  KEYS="$(printf '%s\n' "$NORM" | sed -n 's/.*<key>\([^<]*\)<\/key>.*/\1/p' | sort)"
  KEY_COUNT="$(as_count "$(printf '%s\n' "$KEYS" | grep -c . || true)")"
  TRUE_COUNT="$(as_count "$(printf '%s\n' "$NORM" | awk '{ n += gsub(/<true\/>/, "") } END { print n + 0 }')")"
  EXPECTED_KEYS="com.apple.security.device.audio-input
com.apple.security.personal-information.calendars"
  rec "keys=$KEYS"
  rec "key_count=$KEY_COUNT true_count=$TRUE_COUNT"
  measured "keys=$KEY_COUNT true=$TRUE_COUNT"
  if [ "$KEYS" = "$EXPECTED_KEYS" ] && [ "$KEY_COUNT" -eq 2 ] && [ "$TRUE_COUNT" -eq 2 ]; then
    set_result pass
  fi
fi
end_item

# --- 9. main executable path strings ---------------------------------------
begin_item 09 paths "main executable path strings" "strings -a <app>/Contents/MacOS/Kikishima and scans for user paths and release keywords" "current user path 0 hits; other user path 0 hits (build machine tokenizer path recorded only); release keywords 0 hits" 1
if [ "$MOUNTED" -ne 1 ]; then
  rec "skipped: the dmg is not mounted"
  measured "mount unavailable"
else
  CURRENT_USER="$(id -un)"
  STRFILE="$(mktemp "${TMPDIR:-/tmp}/kikishima-strings.XXXXXX")"
  rec "strings file: $STRFILE"
  strings -a "$APP/Contents/MacOS/Kikishima" > "$STRFILE" 2>/dev/null || true
  ME_HITS="$(awk -v me="/Users/$CURRENT_USER" '
    {
      s = $0
      while ((p = index(s, me)) > 0) {
        after = substr(s, p + length(me), 1)
        if (after == "" || after == "/") n++
        s = substr(s, p + length(me))
      }
    }
    END { print n + 0 }
  ' "$STRFILE")"
  ME_HITS="$(as_count "$ME_HITS")"
  rec "current user path hits=$ME_HITS"
  OTHER="$(awk -v rc="/Users/runner/.cargo" -v mk="/Users/" '
    {
      s = $0
      out = ""
      while ((p = index(s, rc)) > 0) {
        out = out substr(s, 1, p - 1)
        s = substr(s, p + length(rc))
      }
      line = out s
      if (index(line, mk) > 0) {
        n++
        if (n <= 20) print NR ": " $0
      }
    }
    END { print "other_user_hits=" (n + 0) }
  ' "$STRFILE")"
  OTHER_HITS="$(printf '%s\n' "$OTHER" | sed -n 's/^other_user_hits=//p')"
  OTHER_HITS="$(as_count "$OTHER_HITS")"
  rec "$OTHER"
  KW_HITS="$(as_count "$(grep -E -i -c 'sparkle|appcast|SUFeed|downloads\.kikishima\.com' "$STRFILE" || true)")"
  rec "release keyword hits=$KW_HITS"
  RUNNER_HITS="$(as_count "$(grep -F -c '/Users/runner/.cargo' "$STRFILE" || true)")"
  rec "build machine tokenizer path hits=$RUNNER_HITS (recorded only)"
  TMP_HITS="$(as_count "$(grep -F -c '/private/tmp/' "$STRFILE" || true)")"
  rec "build directory path hits=$TMP_HITS (recorded only)"
  measured "user=$ME_HITS other=$OTHER_HITS keywords=$KW_HITS runner_cargo=$RUNNER_HITS tmp=$TMP_HITS"
  if [ "$ME_HITS" -eq 0 ] && [ "$OTHER_HITS" -eq 0 ] && [ "$KW_HITS" -eq 0 ]; then
    set_result pass
  fi
fi
end_item

# --- 10. recursive user path scan in the app -------------------------------
begin_item 10 app-userpath "recursive user path scan" "grep -r -a -F <app>" "current user path 0 hits" 1
if [ "$MOUNTED" -ne 1 ]; then
  rec "skipped: the dmg is not mounted"
  measured "mount unavailable"
else
  CURRENT_USER="$(id -un)"
  USER_RE="$(printf '%s' "$CURRENT_USER" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  GTMP="$(mktemp "${TMPDIR:-/tmp}/kikishima-userpath.XXXXXX")"
  rec "hits file: $GTMP"
  grep -r -a -F "/Users/$CURRENT_USER/" "$APP" > "$GTMP" 2>/dev/null || true
  grep -r -a -F "/Users/$CURRENT_USER" "$APP" 2>/dev/null | grep -E "/Users/${USER_RE}\$" >> "$GTMP" || true
  HIT_COUNT="$(as_count "$(sort -u "$GTMP" | wc -l | tr -d ' ')")"
  rec "current user path hits=$HIT_COUNT"
  if [ "$HIT_COUNT" -gt 0 ]; then
    sed -n '1,20p' "$GTMP" >> "$ITEM_FILE"
  fi
  measured "hits=$HIT_COUNT"
  if [ "$HIT_COUNT" -eq 0 ]; then
    set_result pass
  fi
fi
end_item

# --- 11. quarantine simulation (informational) -----------------------------
begin_item 11 quarantine "quarantine simulation" "ditto copy of the dmg; xattr -w com.apple.quarantine; spctl again" "informational only: not a real download and the app is not started" 0
QTMP="$(mktemp -d "${TMPDIR:-/tmp}/kikishima-quarantine.XXXXXX")"
QCOPY="$QTMP/Kikishima-$VERSION.dmg"
rec "copy: $QCOPY"
if ditto "$DMG" "$QCOPY" 2>>"$ITEM_FILE"; then
  xattr -w com.apple.quarantine "0081;$(date +%s);Safari;" "$QCOPY" 2>>"$ITEM_FILE" || true
  if OUT="$(spctl -a -vv -t open --context context:primary-signature "$QCOPY" 2>&1)"; then
    RC=0
  else
    RC=$?
  fi
  rec "spctl quarantined copy: exit=$RC"
  rec "$OUT"
  measured "exit=$RC"
else
  rec "copy failed"
  measured "copy failed"
fi
set_result info
end_item

# --- summary ----------------------------------------------------------------
FINAL="pass"
if [ "$OVERALL" -ne 0 ]; then
  FINAL="fail"
fi

{
  printf 'KK-055 verify summary\n'
  printf 'dmg: %s\n' "$DMG"
  printf 'version: %s\n' "$VERSION"
  printf 'sha256: %s\n' "$SHA256"
  printf 'expected_team_id: %s\n' "$EXPECTED_TEAM_ID"
  printf 'result: %s\n\n' "$FINAL"
  printf '%-3s %-24s %-6s %s\n' "NO" "ITEM" "RESULT" "MEASURED"
  i=1
  while [ "$i" -le "$IDX" ]; do
    printf '%-3d %-24s %-6s %s\n' "$i" "${R_NAMES[$i]}" "${R_RESULTS[$i]}" "${R_MEASURED[$i]}"
    i=$((i + 1))
  done
} > "$EV/summary.txt"

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r\t' '   '
}

{
  printf '{\n'
  printf '  "dmg": "%s",\n' "$(json_escape "$DMG")"
  printf '  "version": "%s",\n' "$(json_escape "$VERSION")"
  printf '  "sha256": "%s",\n' "$(json_escape "$SHA256")"
  printf '  "expected_team_id": "%s",\n' "$(json_escape "$EXPECTED_TEAM_ID")"
  printf '  "items": [\n'
  i=1
  while [ "$i" -le "$IDX" ]; do
    if [ "$i" -gt 1 ]; then
      printf ',\n'
    fi
    printf '    {"item": %d, "name": "%s", "result": "%s", "measured": "%s"}' \
      "$i" "$(json_escape "${R_NAMES[$i]}")" "$(json_escape "${R_RESULTS[$i]}")" "$(json_escape "${R_MEASURED[$i]}")"
    i=$((i + 1))
  done
  printf '\n  ],\n'
  printf '  "result": "%s"\n' "$FINAL"
  printf '}\n'
} > "$EV/result.json"

cat "$EV/summary.txt"
printf 'RESULT: %s\nEVIDENCE: %s\n' "$FINAL" "$EV"
if [ "$OVERALL" -ne 0 ]; then
  exit 1
fi
exit 0

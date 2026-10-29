#!/bin/bash
# KK-055 release packaging for Kikishima.
#
# Usage: scripts/make-dmg.sh [--dry-run] <version>
#
# A real run needs SIGN_ID (a "Developer ID Application" identity) in the
# environment and must happen inside a clean clone under /tmp. NOTARY_PROFILE
# defaults to kikishima-notary. EXPECTED_TEAM_ID defaults to 526RV9TVKZ.
#
# Steps: build.sh -> check the app signature -> create the dmg -> sign the dmg
# -> notarize the dmg -> staple the dmg -> write dist/build-info.txt.
#
# Network: build.sh may fetch SwiftPM dependencies; codesign --timestamp,
# notarytool and stapler talk to Apple. Keychain: the signing identity and the
# notarization profile. Output stays in the clone's dist/ and in $TMPDIR.
#
# Exit codes: 0 ok, 1 usage/version/SIGN_ID/identity, 2 run guard,
# 3 build, 4 app signature, 5 dmg or dmg signing, 6 notarization, 7 staple.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PLIST="$ROOT/Resources/Info.plist"
PLISTBUDDY=/usr/libexec/PlistBuddy
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-526RV9TVKZ}"
NOTARY_PROFILE="${NOTARY_PROFILE:-kikishima-notary}"
DRY_RUN=0
VERSION=""

usage() {
  printf 'usage: %s [--dry-run] <version>\n' "$0" >&2
}

# Single choke point for external commands. In dry-run mode nothing is run,
# only the planned command is printed.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 1
      ;;
    -*)
      usage
      exit 1
      ;;
    *)
      if [ -n "$VERSION" ]; then
        usage
        exit 1
      fi
      VERSION="$arg"
      ;;
  esac
done
if [ -z "$VERSION" ]; then
  usage
  exit 1
fi
case "$VERSION" in
  *[!0-9A-Za-z._-]*)
    printf 'ERROR: invalid version: %s\n' "$VERSION" >&2
    exit 1
    ;;
esac

# --- read-only version checks (also done for --dry-run) ---------------------
if [ ! -f "$PLIST" ]; then
  printf 'ERROR: missing %s\n' "$PLIST" >&2
  exit 1
fi
SHORT="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
BUILD_NUM="$("$PLISTBUDDY" -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
if [ "$SHORT" != "$VERSION" ]; then
  printf 'ERROR: version %s does not match CFBundleShortVersionString %s\n' "$VERSION" "$SHORT" >&2
  exit 1
fi
case "$BUILD_NUM" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *)
    printf 'ERROR: CFBundleVersion %s is not 12 digits\n' "$BUILD_NUM" >&2
    exit 1
    ;;
esac
if [ "$((10#$BUILD_NUM))" -le 202610260217 ]; then
  printf 'ERROR: CFBundleVersion %s must be greater than 202610260217\n' "$BUILD_NUM" >&2
  exit 1
fi
if grep -q '<key>SU' "$PLIST"; then
  printf 'ERROR: Info.plist still has an autoupdate key\n' >&2
  exit 1
fi

printf 'VERSION(arg)=%s\n' "$VERSION"
printf 'CFBundleShortVersionString=%s\n' "$SHORT"
printf 'CFBundleVersion=%s\n' "$BUILD_NUM"

TAG="v$VERSION"
HEAD_SHA="$(git -C "$ROOT" rev-parse -q --verify HEAD 2>/dev/null || true)"
TAG_SHA="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null || true)"
if [ -z "$TAG_SHA" ]; then
  printf 'TAG=%s absent (not required; this script never creates tags)\n' "$TAG"
elif [ "$TAG_SHA" = "$HEAD_SHA" ]; then
  printf 'TAG=%s %s (HEAD)\n' "$TAG" "$TAG_SHA"
else
  printf 'TAG=%s %s (NOT HEAD %s)\n' "$TAG" "$TAG_SHA" "$HEAD_SHA"
fi

DMG="$ROOT/dist/Kikishima-$VERSION.dmg"
APP="$ROOT/build/Kikishima.app"

# --- dry run: print the plan, touch nothing ---------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY-RUN: no command below is executed and no file is written.\n'
  run security find-identity -v -p codesigning
  run mkdir -p "$ROOT/dist"
  run env "SIGN_ID=<SIGN_ID>" bash "$ROOT/build.sh"
  run codesign --verify --deep --strict --verbose=2 "$APP"
  run codesign -dvvv "$APP"
  run mktemp -d "${TMPDIR:-/tmp}/kikishima-dmg.XXXXXX"
  run ditto "$APP" "${TMPDIR:-/tmp}/kikishima-dmg.XXXXXX/Kikishima.app"
  run ln -s /Applications "${TMPDIR:-/tmp}/kikishima-dmg.XXXXXX/Applications"
  run hdiutil create -volname Kikishima -srcfolder "${TMPDIR:-/tmp}/kikishima-dmg.XXXXXX" -ov -format UDZO "$DMG"
  run codesign --force --timestamp --sign "<SIGN_ID>" "$DMG"
  run mkdir -p "$ROOT/dist/notary"
  run xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json
  run xcrun stapler staple "$DMG"
  run xcrun stapler validate "$DMG"
  run shasum -a 256 "$DMG"
  printf 'DRY-RUN: write %s\n' "$ROOT/dist/build-info.txt"
  exit 0
fi

# --- real run guards --------------------------------------------------------
SIGN_ID_VALUE="${SIGN_ID:-}"
if [ -z "$SIGN_ID_VALUE" ]; then
  printf 'ERROR: SIGN_ID is not set; a real run needs a Developer ID Application identity\n' >&2
  exit 1
fi

case "$ROOT/" in
  /tmp/*|/private/tmp/*) ;;
  *)
    printf 'ERROR: real runs are only allowed inside a clone under /tmp; this checkout is %s\n' "$ROOT" >&2
    exit 2
    ;;
esac

TOP="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
TOP_PHYS=""
if [ -n "$TOP" ]; then
  TOP_PHYS="$(cd "$TOP" && pwd -P)"
fi
if [ "$TOP_PHYS" != "$ROOT" ]; then
  printf 'ERROR: %s is not the top level of a git clone\n' "$ROOT" >&2
  exit 2
fi
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  printf 'ERROR: the git working tree is not clean; commit or revert changes first\n' >&2
  git -C "$ROOT" status --short >&2 || true
  exit 2
fi
printf 'HEAD=%s\n' "$HEAD_SHA"

# dist/ is ignored by git, so the clean check above cannot see leftovers from an
# earlier run. Refuse to overwrite them instead of mixing two runs' artifacts.
EXISTING=""
for candidate in "$ROOT/dist/Kikishima-$VERSION.dmg" "$ROOT/dist/build-info.txt" "$ROOT/dist/notary"; do
  if [ -e "$candidate" ]; then
    printf 'ERROR: previous output already exists: %s\n' "$candidate" >&2
    EXISTING=1
  fi
done
if [ -n "$EXISTING" ]; then
  printf 'ERROR: move the previous dist artifacts away before starting a new run\n' >&2
  exit 2
fi

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
case "$IDENTITIES" in
  *"$SIGN_ID_VALUE"*) ;;
  *)
    printf 'ERROR: SIGN_ID was not found among the local codesigning identities\n' >&2
    exit 1
    ;;
esac

# --- build ------------------------------------------------------------------
run mkdir -p "$ROOT/dist"
if ! run env "SIGN_ID=$SIGN_ID_VALUE" bash "$ROOT/build.sh"; then
  printf 'ERROR: build.sh failed\n' >&2
  exit 3
fi
if [ ! -d "$APP" ]; then
  printf 'ERROR: %s was not produced\n' "$APP" >&2
  exit 3
fi
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
  printf 'ERROR: tracked files changed during the build\n' >&2
  git -C "$ROOT" diff --stat >&2 || true
  exit 3
fi

# --- app signature (reject a silent ad-hoc fallback) ------------------------
if ! SIGVERIFY="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)"; then
  printf 'ERROR: codesign --verify failed for the app\n%s\n' "$SIGVERIFY" >&2
  exit 4
fi
SIGINFO="$(codesign -dvvv "$APP" 2>&1 || true)"
case "$SIGINFO" in
  *"Signature=adhoc"*)
    printf 'ERROR: build.sh fell back to an ad-hoc signature\n' >&2
    exit 4
    ;;
esac
LEAF_AUTH="$(printf '%s\n' "$SIGINFO" | sed -n 's/^Authority=//p')"
LEAF_AUTH="${LEAF_AUTH%%$'\n'*}"
case "$LEAF_AUTH" in
  "Developer ID Application:"*) ;;
  *)
    printf 'ERROR: the app leaf authority is not Developer ID Application: %s\n' "${LEAF_AUTH:-none}" >&2
    exit 4
    ;;
esac
TEAM="$(printf '%s\n' "$SIGINFO" | sed -n 's/^TeamIdentifier=//p')"
TEAM="${TEAM%%$'\n'*}"
if [ "$TEAM" != "$EXPECTED_TEAM_ID" ]; then
  printf 'ERROR: TeamIdentifier %s does not match expected %s\n' "${TEAM:-none}" "$EXPECTED_TEAM_ID" >&2
  exit 4
fi
FLAGS="$(printf '%s\n' "$SIGINFO" | sed -n 's/^flags=//p')"
FLAGS="${FLAGS%%$'\n'*}"
case "$FLAGS" in
  *runtime*) ;;
  *)
    printf 'ERROR: the hardened runtime flag is missing from the app signature\n' >&2
    exit 4
    ;;
esac
case "$SIGINFO" in
  *"Timestamp="*) ;;
  *)
    printf 'ERROR: the app signature has no secure timestamp\n' >&2
    exit 4
    ;;
esac
printf 'APP-SIGNATURE: authority=%s team=%s flags=%s\n' "$LEAF_AUTH" "$TEAM" "$FLAGS"

# --- dmg --------------------------------------------------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kikishima-dmg.XXXXXX")"
printf 'STAGE: %s\n' "$STAGE"
run ditto "$APP" "$STAGE/Kikishima.app"
run ln -s /Applications "$STAGE/Applications"
if ! run hdiutil create -volname "Kikishima" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null; then
  printf 'ERROR: hdiutil create failed\n' >&2
  exit 5
fi
if ! run codesign --force --timestamp --sign "$SIGN_ID_VALUE" "$DMG"; then
  printf 'ERROR: signing the dmg failed\n' >&2
  exit 5
fi
printf 'DMG: %s\n' "$DMG"

# --- notarization -----------------------------------------------------------
mkdir -p "$ROOT/dist/notary"
SUBMIT_JSON="$ROOT/dist/notary/submit.json"
SUB_ID=""
STATUS=""
NOTARY_RC=0
if ! run xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$SUBMIT_JSON" 2>&1; then
  NOTARY_RC=1
fi

parse_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8", errors="replace") as handle:
        data = json.load(handle)
except Exception:
    print("")
    raise SystemExit(0)
value = data.get(field, "") if isinstance(data, dict) else ""
print(value if isinstance(value, str) else "")
PY
}

STATUS="$(parse_field "$SUBMIT_JSON" status)"
SUB_ID="$(parse_field "$SUBMIT_JSON" id)"
printf 'NOTARY: status=%s id=%s\n' "${STATUS:-unknown}" "${SUB_ID:-none}"

if [ "$NOTARY_RC" -ne 0 ] || [ "$STATUS" != "Accepted" ]; then
  if [ -n "$SUB_ID" ]; then
    run xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" "$ROOT/dist/notary/log.json" >/dev/null 2>&1 || true
    printf 'ERROR: notarization was not accepted; see %s/dist/notary/log.json\n' "$ROOT" >&2
  else
    printf 'ERROR: notarytool submit returned no submission id; see %s/dist/notary/submit.json\n' "$ROOT" >&2
  fi
  exit 6
fi

# --- staple -----------------------------------------------------------------
if ! run xcrun stapler staple "$DMG"; then
  printf 'ERROR: stapler staple failed\n' >&2
  exit 7
fi
if ! run xcrun stapler validate "$DMG"; then
  printf 'ERROR: stapler validate failed\n' >&2
  exit 7
fi

# --- report -----------------------------------------------------------------
SHA="$(shasum -a 256 "$DMG" | sed -n 's/ .*//p')"
BYTES="$(stat -f%z "$DMG")"
UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
cat > "$ROOT/dist/build-info.txt" <<EOF
version=$VERSION
cfbundleversion=$BUILD_NUM
commit=$COMMIT
built_utc=$UTC
dmg=Kikishima-$VERSION.dmg
sha256=$SHA
bytes=$BYTES
notarization=dmg-only
notary_submission=${SUB_ID:-none}
EOF
printf 'SHA256: %s\n' "$SHA"
printf 'BYTES: %s\n' "$BYTES"
printf 'INFO: %s/dist/build-info.txt\n' "$ROOT"

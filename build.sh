#!/bin/bash
# 编译 + 打包 Kikishima.app
# 签名：设置 SIGN_ID 时用本机 Developer ID；没有证书时用 ad-hoc 签名方便本机开发。
set -euo pipefail
cd "$(dirname "$0")"
SANDBOX=false
case "$#:$*" in
  0:) ;;
  1:--sandbox) SANDBOX=true ;;
  *) echo "Usage: $0 [--sandbox]" >&2; exit 2 ;;
esac
APP=build/Kikishima.app
BUILD_DIR=build
SCRATCH=.build
if $SANDBOX; then
  APP=build-sandbox/KikishimaSandbox.app
  BUILD_DIR=build-sandbox
  SCRATCH=.build-sandbox
fi
DEV_ID="${SIGN_ID:-}"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if $SANDBOX; then
  swift build -c release --arch arm64 --build-system native --scratch-path "$SCRATCH" -Xswiftc -DSANDBOX
else
  swift build -c release --arch arm64 --build-system native
fi
BIN="$SCRATCH/arm64-apple-macosx/release/Kikishima"
[ -x "$BIN" ] || BIN="$SCRATCH/release/Kikishima"
[ -x "$BIN" ] || { echo "swift build failed"; exit 1; }
cp "$BIN" "$APP/Contents/MacOS/Kikishima"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if $SANDBOX; then
  PLIST="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.kikishima.mac.sandbox' "$PLIST"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Kikishima Sandbox' "$PLIST"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Kikishima Sandbox' "$PLIST"
fi
# Versioned icon assets; regenerate from BrandIcons.swift with tools/generate_icons.sh.
cp Resources/Brand/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/ThirdPartyNotices"
cp Vendor/DynamicNotchKit/LICENSE "$APP/Contents/Resources/ThirdPartyNotices/DynamicNotchKit-LICENSE.txt"
# Fixed verbatim copies from the locked SwiftPM checkouts; independent of build cache layout.
for dependency in Pow MacControlCenterUI MenuBarExtraAccess; do
  cp "Vendor/ThirdPartyLicenses/$dependency-LICENSE.txt" "$APP/Contents/Resources/ThirdPartyNotices/$dependency-LICENSE.txt"
done
cp NOTICE.md "$APP/Contents/Resources/ThirdPartyNotices/NOTICE.md"
# 五语表：先对账（源码里每个 tr() key 四张表都得有，缺一个就停），再拷；四张 JSON 缺任何一张也停
python3 Resources/l10n/gen.py --check
for L in zh-Hant ja en ko; do [ -s "Resources/l10n/$L.json" ] || { echo "missing l10n table: $L.json"; exit 1; }; done
mkdir -p "$APP/Contents/Resources/l10n" && cp Resources/l10n/*.json "$APP/Contents/Resources/l10n/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"   # InfoPlist.strings：系统权限弹窗文案跟随系统语言
if [ -n "$DEV_ID" ] && security find-identity -v -p codesigning | grep -qF "$DEV_ID"; then
  # Maintainers can pass SIGN_ID to use their own Developer ID certificate.
  codesign --force --options runtime --timestamp --entitlements Resources/Kikishima.entitlements --sign "$DEV_ID" "$APP"
  echo "SIGNED: Developer ID"
else
  # No local certificate: ad-hoc sign so the app can run for development.
  codesign --force --deep --sign - "$APP"
  echo "SIGNED: ad-hoc"
fi
echo "BUILT: $APP"

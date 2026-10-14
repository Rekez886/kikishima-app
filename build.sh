#!/bin/bash
# 编译 + 打包 Kikishima.app
# 签名：优先 Developer ID（正式分发，公证前提）；没装证书的机器回落自签 MeetingCaptionsDev（本机开发）
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Kikishima.app
DEV_ID="${SIGN_ID:-Developer ID Application: Lingjie Yang (526RV9TVKZ)}"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# SwiftPM 编译（三方包：DynamicNotchKit / Pow / MacControlCenterUI 见 Package.swift）；Sparkle 仍是 Vendor 里的 framework
# Swift 6.4 默认的 swiftbuild 扫不到 Vendor/Sparkle.framework，import Sparkle 会失败。native 会把 -F Vendor 传给编译器。
# --build-system native 已标记弃用；换构建系统后要再确认 Sparkle 还能被扫到。
swift build -c release --arch arm64 --build-system native
BIN=".build/arm64-apple-macosx/release/Kikishima"
[ -x "$BIN" ] || BIN=".build/release/Kikishima"
[ -x "$BIN" ] || { echo "swift build failed"; exit 1; }
cp "$BIN" "$APP/Contents/MacOS/Kikishima"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Versioned icon assets; regenerate from BrandIcons.swift with tools/generate_icons.sh.
cp Resources/Brand/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/ThirdPartyNotices"
cp Vendor/DynamicNotchKit/LICENSE "$APP/Contents/Resources/ThirdPartyNotices/DynamicNotchKit-LICENSE.txt"
# 五语表：先对账（源码里每个 tr() key 四张表都得有，缺一个就停），再拷；四张 JSON 缺任何一张也停
python3 Resources/l10n/gen.py --check
for L in zh-Hant ja en ko; do [ -s "Resources/l10n/$L.json" ] || { echo "missing l10n table: $L.json"; exit 1; }; done
mkdir -p "$APP/Contents/Resources/l10n" && cp Resources/l10n/*.json "$APP/Contents/Resources/l10n/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"   # InfoPlist.strings：系统权限弹窗文案跟随系统语言
mkdir -p "$APP/Contents/Frameworks" && cp -R Vendor/Sparkle.framework "$APP/Contents/Frameworks/"   # 自动更新
if security find-identity -v -p codesigning | grep -q "$DEV_ID"; then
  # --timestamp：公证要求安全时间戳（需联网）；--options runtime：Hardened Runtime
  # Sparkle 内嵌的 XPC / Autoupdate / Updater.app 必须先用我们的证书重签，公证才会过
  SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  codesign --force --options runtime --timestamp --sign "$DEV_ID" "$SP/XPCServices/Installer.xpc"
  codesign --force --options runtime --timestamp --sign "$DEV_ID" "$SP/XPCServices/Downloader.xpc"
  codesign --force --options runtime --timestamp --sign "$DEV_ID" "$SP/Updater.app"
  codesign --force --options runtime --timestamp --sign "$DEV_ID" "$SP/Autoupdate"
  codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP/Contents/Frameworks/Sparkle.framework"
  # 描述文件带 Sign in with Apple 权利时才内嵌（否则 Apple 登录按钮不显示，签名也不声明该权利）
  ENT=Resources/Kikishima.entitlements
  if [ -f Resources/Kikishima.provisionprofile ] && security cms -D -i Resources/Kikishima.provisionprofile 2>/dev/null | grep -q "com.apple.developer.applesignin"; then
    cp Resources/Kikishima.provisionprofile "$APP/Contents/embedded.provisionprofile"
    ENT=Resources/Kikishima-applesignin.entitlements
    echo "EMBEDDED: provisioning profile (Sign in with Apple)"
  fi
  codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$DEV_ID" "$APP"
  echo "SIGNED: Developer ID"
else
  codesign --force --options runtime --sign "MeetingCaptionsDev" "$APP" 2>/dev/null || codesign --force --sign "MeetingCaptionsDev" "$APP"
  echo "SIGNED: dev cert (MeetingCaptionsDev)"
fi
echo "BUILT: $APP"

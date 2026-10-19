#!/bin/bash
# 编译 + 打包 Kikishima.app
# 签名：只做 ad-hoc 签名（本机运行用）。正式分发的签名和公证需要你自己的 Apple Developer ID，不在本脚本里。
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Kikishima.app
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
# Fixed verbatim copies from the locked SwiftPM checkouts; independent of build cache layout.
for dependency in Pow MacControlCenterUI MenuBarExtraAccess; do
  cp "Vendor/ThirdPartyLicenses/$dependency-LICENSE.txt" "$APP/Contents/Resources/ThirdPartyNotices/$dependency-LICENSE.txt"
done
cp Vendor/Sparkle-LICENSE.txt "$APP/Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE.txt"
cp NOTICE.md "$APP/Contents/Resources/ThirdPartyNotices/NOTICE.md"
# 五语表：先对账（源码里每个 tr() key 四张表都得有，缺一个就停），再拷；四张 JSON 缺任何一张也停
python3 Resources/l10n/gen.py --check
for L in zh-Hant ja en ko; do [ -s "Resources/l10n/$L.json" ] || { echo "missing l10n table: $L.json"; exit 1; }; done
mkdir -p "$APP/Contents/Resources/l10n" && cp Resources/l10n/*.json "$APP/Contents/Resources/l10n/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"   # InfoPlist.strings：系统权限弹窗文案跟随系统语言
mkdir -p "$APP/Contents/Frameworks" && cp -R Vendor/Sparkle.framework "$APP/Contents/Frameworks/"   # 自动更新
codesign --force --deep --sign - --entitlements Resources/Kikishima.entitlements "$APP"
echo "SIGNED: ad-hoc"
echo "BUILT: $APP"

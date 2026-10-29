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
# MLX GPU shaders. SwiftPM cannot build Metal shaders (mlx-swift README), and the
# MLX runtime looks for mlx.metallib next to the executable, i.e. Contents/MacOS.
# Compiled here, before the codesign step below, so the app signature covers it.
# Requires Apple's Metal Toolchain: xcodebuild -downloadComponent MetalToolchain
MIN_MACOS="$(sed -n 's/.*platforms: \[\.macOS("\([0-9][0-9.]*\)")\].*/\1/p' Package.swift | head -n 1)"
[ -n "$MIN_MACOS" ] || { echo "cannot read the deployment target from Package.swift"; exit 1; }
MLX_GEN="$SCRATCH/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
[ -d "$MLX_GEN" ] || { echo "mlx-swift kernels not found: $MLX_GEN"; exit 1; }
xcrun -sdk macosx --find metal >/dev/null 2>&1 && xcrun -sdk macosx --find metallib >/dev/null 2>&1 \
  || { echo "Metal Toolchain missing: run 'xcodebuild -downloadComponent MetalToolchain'"; exit 1; }

build_mlx_metallib() {
  local gen="$1" out="$2" min_version="$3"
  # Subshell: the cleanup trap stays local, the parent shell's trap table is untouched.
  (
    set -euo pipefail
    local tmp k air=()
    local kernels=(arg_reduce conv dot layer_norm random rms_norm rope
                   scaled_dot_product_attention searchsorted steel/attn/kernels/steel_attention)
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/kikishima-metal.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    for k in "${kernels[@]}"; do
      [ -f "$gen/$k.metal" ] || { echo "missing MLX kernel: $gen/$k.metal" >&2; exit 1; }
      xcrun -sdk macosx metal -x metal -Wall -Wextra -fno-fast-math \
        -Wno-c++17-extensions -Wno-c++20-extensions -Wmetal-addr-spaces \
        -mmacosx-version-min="$min_version" -I "$gen" \
        -c "$gen/$k.metal" -o "$tmp/$(basename "$k").air"
      air+=("$tmp/$(basename "$k").air")
    done
    [ "${#air[@]}" -eq "${#kernels[@]}" ] || { echo "MLX air file count mismatch" >&2; exit 1; }
    xcrun -sdk macosx metallib "${air[@]}" -o "$out"
  )
}
build_mlx_metallib "$MLX_GEN" "$APP/Contents/MacOS/mlx.metallib" "$MIN_MACOS"
echo "METALLIB: $APP/Contents/MacOS/mlx.metallib"
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
  # mlx.metallib is a non-Mach-O file in Contents/MacOS; codesign requires nested items to be signed first.
  if [ -f "$APP/Contents/MacOS/mlx.metallib" ]; then
    codesign --force --timestamp --sign "$DEV_ID" "$APP/Contents/MacOS/mlx.metallib"
  fi
  codesign --force --options runtime --timestamp --entitlements Resources/Kikishima.entitlements --sign "$DEV_ID" "$APP"
  echo "SIGNED: Developer ID"
else
  # No local certificate: ad-hoc sign so the app can run for development.
  codesign --force --deep --sign - "$APP"
  echo "SIGNED: ad-hoc"
fi
echo "BUILT: $APP"

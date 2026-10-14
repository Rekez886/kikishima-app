#!/bin/bash
# 出正式版：编译签名 → 打 DMG → Apple 公证 → 盖章 → 验收
# 用法：./release.sh 0.3            （版本号写进 Info.plist 后再构建）
# 前提：钥匙串已有 Developer ID 证书；公证凭证已存：
#   xcrun notarytool store-credentials kikishima-notary --apple-id <Apple ID 邮箱> --team-id 526RV9TVKZ --password <App 专用密码>
set -euo pipefail
cd "$(dirname "$0")"
VER="${1:?用法: ./release.sh <版本号，如 0.3>}"
PROFILE="${NOTARY_PROFILE:-kikishima-notary}"
APP=build/Kikishima.app
DMG="dist/Kikishima-$VER.dmg"

# 1) 版本号
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" Resources/Info.plist
BUILD_NO=$(date +%Y%m%d%H%M)   # 构建号 = 时间戳，单调递增且不依赖旧值格式
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NO" Resources/Info.plist

# 2) 构建 + 签名（build.sh 检测到 Developer ID 会用它）+ 归档 dSYM（崩溃日志符号化用）
BUILD_LOG=$(./build.sh)   # pipefail 下失败即停；签名必须是 Developer ID，否则公证必败
echo "$BUILD_LOG" | tail -2
echo "$BUILD_LOG" | grep -q "SIGNED: Developer ID" || { echo "未用 Developer ID 签名，停止发布"; exit 1; }
mkdir -p dist
(dsymutil "$APP/Contents/MacOS/Kikishima" -o "dist/Kikishima-$VER.dSYM" >/dev/null 2>&1 && cd dist && rm -f "Kikishima-$VER.dSYM.zip" && zip -qr "Kikishima-$VER.dSYM.zip" "Kikishima-$VER.dSYM" && rm -rf "Kikishima-$VER.dSYM" && echo "dSYM: dist/Kikishima-$VER.dSYM.zip") || echo "dSYM 归档失败（不影响发布）"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

# 3) DMG：临时目录放 app + Applications 快捷方式
rm -rf dist/stage && mkdir -p dist/stage
cp -R "$APP" dist/stage/
ln -s /Applications dist/stage/Applications
rm -f "$DMG"
hdiutil create -volname "Kikishima $VER" -srcfolder dist/stage -ov -format UDZO "$DMG" >/dev/null
rm -rf dist/stage
codesign --force --timestamp --sign "${SIGN_ID:-Developer ID Application: Lingjie Yang (526RV9TVKZ)}" "$DMG"   # 与 build.sh 同一身份

# 4) 公证（同步等结果，通常 1~5 分钟）
echo "== 提交公证 $DMG"
NOTARY_OUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1) || { echo "$NOTARY_OUT" | tail -5; echo "公证提交失败"; exit 1; }
echo "$NOTARY_OUT" | tail -5
echo "$NOTARY_OUT" | grep -q "status: Accepted" || { echo "公证未通过（不是 Accepted），停止发布"; exit 1; }

# 5) 盖章（离线也能被 Gatekeeper 认）+ 验收
xcrun stapler staple "$DMG" | tail -1
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | tail -1 || { echo "Gatekeeper 验收失败"; exit 1; }

# 6) Sparkle：用钥匙串里的 EdDSA 私钥签 DMG，写 appcast.xml（发布 = 把 DMG + appcast.xml 上传到 downloads.kikishima.com）
NOTES_FILE="dist/notes-$VER.md"
[ -f "$NOTES_FILE" ] || echo "- 修复与改进" > "$NOTES_FILE"
SIG=$(Vendor/bin/sign_update "$DMG" 2>/dev/null)        # 输出形如 sparkle:edSignature="..." length="..."
case "$SIG" in *edSignature=*) ;; *) echo "sign_update 没给出 EdDSA 签名（钥匙串里的 Sparkle 私钥不可用？），停止发布"; exit 1;; esac
# appcast 以线上为基准追加（dist/ 不进 git，换机器或清过 dist 会把历史条目丢掉）
if [ -s "$HOME/Library/Application Support/Kikishima/r2.env" ]; then
  python3 tools/pull_appcast.py https://downloads.kikishima.com/appcast.xml dist/appcast.xml || true
fi
python3 - "$VER" "$BUILD_NO" "$DMG" "$SIG" "$NOTES_FILE" <<'PY'
import sys, html, datetime, os
ver, build, dmg, sig, notes = sys.argv[1:6]
name = os.path.basename(dmg)
body = open(notes, encoding='utf-8').read().replace(']]>', ']]]]><![CDATA[>')   # CDATA 里不再 html.escape（会双重转义）；只防 ]]> 截断
item = f"""    <item>
      <title>Kikishima {ver}</title>
      <pubDate>{datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{ver}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<pre style="font-family:-apple-system;white-space:pre-wrap">{body}</pre>]]></description>
      <enclosure url="https://downloads.kikishima.com/{name}" {sig} type="application/octet-stream" />
    </item>
"""
path = 'dist/appcast.xml'
if os.path.exists(path):
    xml = open(path, encoding='utf-8').read()
    xml = xml.replace('  </channel>', item + '  </channel>', 1)
else:
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Kikishima</title>
    <link>https://kikishima.com</link>
{item}  </channel>
</rss>
"""
open(path, 'w', encoding='utf-8').write(xml)
print('appcast:', path)
PY
# 7) 上传到 R2（downloads.kikishima.com）：先 DMG 再 appcast，用户端只有在 appcast 更新后才看到新版
#    更新说明：纯修复版 notes-<ver>.md 写「修复了一些问题」即可；带功能的版本写 dist/notes-<ver>.<lang>.md 五语，列用户看得见的变化
if [ -s "$HOME/Library/Application Support/Kikishima/r2.env" ]; then
  python3 tools/r2_upload.py kikishima-downloads "$DMG" "$(basename "$DMG")"
  python3 tools/r2_upload.py kikishima-downloads dist/appcast.xml appcast.xml --type application/xml
  python3 tools/publish_notes.py "$VER"   # 有 notes-<ver>.<lang>.md 就按语言发布并回写 appcast
  echo "PUBLISHED: https://downloads.kikishima.com/$(basename "$DMG")"
else
  echo "SKIP upload: 没有 r2.env"
fi
echo "DONE: $DMG  (build $BUILD_NO)"

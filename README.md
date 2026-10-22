# Kikishima

Kikishima (聞き島) is a macOS menu-bar app that turns the meeting audio already playing on your Mac into live translated captions. It does not join the call as a bot, and it does not depend on the host turning captions on.

- Audio stays on the Mac: a Core Audio tap feeds Apple SpeechAnalyzer for on-device speech recognition. Only transcript text is sent for translation.
- A floating caption panel is designed to sit just under the MacBook camera, so reading captions looks like looking at the lens.
- Local transcripts, in-meeting and final summaries, and an optional attendee glossary from a macOS Calendar event you pick.
- UI in Simplified Chinese, Traditional Chinese, Japanese, English and Korean.

Translation and accounts go through the Kikishima service (`api.kikishima.com`); signing in is required.

## Download

Latest signed and notarized build: [Kikishima-0.43.1.dmg](https://downloads.kikishima.com/Kikishima-0.43.1.dmg). The app updates itself via Sparkle.

## Requirements

- macOS 26 or later, Apple Silicon (arm64)
- Swift 6 toolchain (Package.swift uses `swift-tools-version: 6.0`) with the macOS 26 SDK

## Build from source

There is no Xcode project. SwiftPM builds the executable; `build.sh` assembles and signs `build/Kikishima.app`.

```bash
./build.sh
```

Notes:

- `build.sh` runs `python3 Resources/l10n/gen.py --check`, so Python 3 is required.
- Sparkle ships as a prebuilt framework in `Vendor/`. The `-F Vendor` flag in Package.swift is relative; if `swift build` can't find Sparkle, pass absolute paths:
  ```bash
  swift build -c release --arch arm64 \
    -Xswiftc -F -Xswiftc "$PWD/Vendor" \
    -Xlinker -F -Xlinker "$PWD/Vendor"
  ```
- Signing: `build.sh` only ad-hoc signs the app so it runs on your own Mac. Distribution, notarization and Sparkle update signing require your own Apple Developer ID, notary credentials and Sparkle keys, and are not part of this repository.
- Sign in with Apple only works with a provisioning profile for your own team (see `Resources/Kikishima-applesignin.entitlements`).

## Chrome extension

`chrome-extension/` contains a companion extension that shows bilingual captions under web videos (currently YouTube), using the video's own caption track. It holds no keys and does not sign in; translation is passed to the local Kikishima app over Chrome native messaging. See [chrome-extension/README.md](chrome-extension/README.md).

## License

MIT — see [LICENSE](LICENSE).

Third-party code (see [NOTICE.md](NOTICE.md)):

- [Sparkle](https://sparkle-project.org) — MIT, `Vendor/Sparkle-LICENSE.txt`
- [DynamicNotchKit](Vendor/DynamicNotchKit) — MIT (vendored with local changes, see `LOCAL_CHANGES.md`)
- Portions adapted from [AudioCap](https://github.com/insidegui/AudioCap) (BSD-style) and [PermissionFlow](https://github.com/jaywcjlove/PermissionFlow) (MIT)
- SwiftPM dependencies: Pow, MacControlCenterUI, MenuBarExtraAccess (under their own licenses)

---

## 日本語

Kikishima（聞き島）は、Mac で再生中の会議音声をリアルタイムで翻訳字幕にする macOS メニューバーアプリです。ボットとして会議に参加せず、主催者が字幕をオンにしていなくても使えます。

- 音声は Mac の外に出ません。Core Audio タップで取り込み、Apple SpeechAnalyzer で端末内で文字起こしします。翻訳に送るのはテキストだけです。
- 字幕パネルは MacBook のカメラ直下に置く想定なので、字幕を読んでいてもカメラを見ているように映ります。
- 文字起こしのローカル保存、会議中・会議後の要約、選んだ macOS カレンダー予定から作る参加者用語集。
- UI は簡体字中国語・繁体字中国語・日本語・英語・韓国語に対応。

翻訳とアカウントは Kikishima のサービス（`api.kikishima.com`）を使うため、ログインが必要です。

### ダウンロード

署名・公証済みの最新ビルド：[Kikishima-0.43.1.dmg](https://downloads.kikishima.com/Kikishima-0.43.1.dmg)。アプリは Sparkle で自動アップデートされます。

### 動作環境

- macOS 26 以降、Apple Silicon（arm64）
- Swift 6 ツールチェーンと macOS 26 SDK

### ソースからビルド

Xcode プロジェクトはありません。`./build.sh` で `build/Kikishima.app` を生成し、ad-hoc 署名します。

- `build.sh` 内で Python 3 を使います。
- Sparkle は `Vendor/` 内のビルド済みフレームワークです。`swift build` が Sparkle を見つけられない場合は、上記の英語セクションにあるとおり `Vendor` を絶対パスで `-F` に渡してください。
- 署名：`build.sh` は自分の Mac で動かすための ad-hoc 署名だけを行います。配布・公証・Sparkle 署名には、ご自身の Apple Developer ID・公証用認証情報・Sparkle 鍵が必要で、このリポジトリには含まれません。

### Chrome 拡張機能

`chrome-extension/` は、Web 動画（現在は YouTube）の字幕トラックを使って動画下に二言語字幕を表示する拡張機能です。鍵を持たず、ログインもしません。翻訳はネイティブメッセージングでローカルの Kikishima アプリに渡します。

### ライセンス

MIT（[LICENSE](LICENSE)）。サードパーティ（Sparkle、DynamicNotchKit、AudioCap、PermissionFlow など）は [NOTICE.md](NOTICE.md) を参照してください。

---

## 简体中文

Kikishima（聞き島）是一款 macOS 菜单栏应用，把 Mac 上正在播放的会议声音实时变成翻译字幕。它不会以机器人身份进会，也不需要主持人打开字幕。

- 音频不离开 Mac：通过 Core Audio tap 采集，用 Apple SpeechAnalyzer 在本机识别，只把转写文字发去翻译。
- 字幕面板设计成放在 MacBook 摄像头正下方，看字幕时就像在看镜头。
- 本地保存转写记录、会中和会后总结，可从你选的 macOS 日历事件生成参会人术语表。
- 界面支持简体中文、繁体中文、日语、英语、韩语。

翻译和账号依赖 Kikishima 服务（`api.kikishima.com`），需要登录。

### 下载

已签名、已公证的最新版本：[Kikishima-0.43.1.dmg](https://downloads.kikishima.com/Kikishima-0.43.1.dmg)。应用会通过 Sparkle 自动更新。

### 系统要求

- macOS 26 及以上，Apple Silicon（arm64）
- Swift 6 工具链和 macOS 26 SDK

### 从源码构建

没有 Xcode 工程。运行 `./build.sh` 生成 `build/Kikishima.app` 并做 ad-hoc 签名。

- `build.sh` 会用到 Python 3。
- Sparkle 是 `Vendor/` 里预编译的 framework。如果 `swift build` 找不到 Sparkle，按英文部分的示例用绝对路径给 `-F` 传 `Vendor`。
- 签名：`build.sh` 只做 ad-hoc 签名，供本机运行。分发、公证和 Sparkle 更新签名需要你自己的 Apple Developer ID、公证凭证和 Sparkle 密钥，不在本仓库里。

### Chrome 扩展

`chrome-extension/` 是配套扩展：读取网页视频（目前是 YouTube）自带的字幕轨，在视频下方显示双语字幕。扩展不存密钥、不登录，翻译通过 Chrome 原生消息交给本机 Kikishima app 处理。

### 许可证

MIT（见 [LICENSE](LICENSE)）。第三方代码（Sparkle、DynamicNotchKit、AudioCap、PermissionFlow 等）见 [NOTICE.md](NOTICE.md)。

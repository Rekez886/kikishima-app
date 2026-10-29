# Kikishima

Local-first meeting captions and translation for macOS.

Kikishima listens to system audio, transcribes it on-device with Apple's Speech
framework, and translates the result without sending meeting text to a
Kikishima server. It can also generate meeting summaries locally with
Apple Foundation Models when available on your Mac (requires Apple Intelligence).
See Privacy for when text is sent to OpenAI.

This repository is the open-source, payment-free edition. There is no account,
no subscription or quota, and the app does not contact any Kikishima server.
Some unused leftover code from the paid edition remains in the source tree,
including the old API address constant in `Sources/Kikishima/SessionLifecycle.swift`
and the network path in `Sources/Kikishima/NativeHost.swift`, which app startup
does not call.

## Features

- On-device speech recognition with Apple `SpeechAnalyzer`.
- Menu bar captions, a floating desktop caption window, and a notch/island mode.
- Translation engines:
  - **Apple Translation** (default): on-device, fast; macOS may ask to download a
    language pack the first time you use a language pair.
  - **MLX TranslateGemma** (optional): higher quality, downloads a local model.
  - **Your own OpenAI key** (optional): best quality, direct from your Mac to
    OpenAI.
- Meeting summaries locally with Apple Foundation Models, or through your own
  OpenAI key.
- Meeting records are stored on your Mac; summaries stay on your Mac unless
  OpenAI is used (see Privacy).

## Requirements

- macOS 26 or later is the declared minimum; macOS 26 has not been verified.
  The project has only been built and run on macOS 27.0.1 with Xcode 27.1
  (Swift 6.4) on Apple Silicon.
- Apple Silicon.
- Xcode 27.1 was used for building; older versions are not verified.
- Apple Intelligence enabled for local meeting summaries.
- Optional: a Hugging Face download for the MLX model (about 2.3 GB on 16 GB
  Macs, about 6.6 GB on 24 GB or larger Macs).
- Optional: an OpenAI API key.

## Download

Download the latest release from
[GitHub Releases](https://github.com/Rekez886/kikishima-app/releases/latest).
The DMG and the app inside are signed with Developer ID and notarized by Apple,
so they can be opened normally. The First launch steps below apply only to
self-built versions.

Checksums (SHA-256) are listed on the Release page.

```bash
shasum -a 256 Kikishima-<version>.dmg
spctl -a -t open --context context:primary-signature -v Kikishima-<version>.dmg
```

The `spctl` command should report `accepted` and
`source=Notarized Developer ID`.

New versions are available from GitHub Releases; the app does not update
automatically.

## Build

```bash
./build.sh
open build/Kikishima.app
```

The first dependency download may hang waiting for a macOS keychain prompt
for GitHub credentials; the cause has not been confirmed. If it stops at
"Downloading binary artifact", run `swift package --disable-keychain resolve`
first, then `./build.sh`.

### Signing your own build

`build.sh` compiles the Swift package, copies resources, and signs the app:

- **Without `SIGN_ID`** it signs ad-hoc and prints a warning. This is meant for
  local development; the result is not notarized and Gatekeeper blocks it on
  first open.
- **With `SIGN_ID`** it signs with that Developer ID Application identity using
  hardened runtime and a secure timestamp. If the identity is not found in your
  keychain, the build stops with an error instead of falling back to ad-hoc.

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

The build script does not notarize the app. A Developer ID signed build that has
not been notarized is still rejected by Gatekeeper (`spctl` reports `rejected`
and `source=Unnotarized Developer ID`). The GitHub Release DMG is notarized.

### First launch of an ad-hoc build

After the failed open attempt, follow [Apple's instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac):
System Settings > Privacy & Security > Security > Open Anyway (available for
about an hour after the attempt), then enter your login password.
Apple's page does not name a macOS version, and this project has not checked
the exact dialogs on macOS 27 or 26. Only open software you trust.

## Translation engines

The default engine is Apple Translation. It uses the system Translation
framework and may ask macOS to download a language pack the first time you use
a language pair.

The optional MLX engine uses `mlx-community/translategemma-12b-it-4bit` on Macs
with 24 GB or more memory and `mlx-community/translategemma-4b-it-4bit` on
smaller Macs. The model files are downloaded on demand from huggingface.co
(the Hugging Face hub) and cached locally. They are not bundled with the app.
Apple's frameworks may also download Translation language packs and Speech
recognition assets on first use; macOS makes these downloads, not the app's
own network code.

The OpenAI engine stores the key in the macOS Keychain. Caption text is sent
directly from your Mac to OpenAI: each chunk is sent with the previous source
fragment for context, when available, and any glossary terms. These include
your glossary and the selected calendar meeting's title and attendee names
when present. It never passes through a Kikishima server.

## Privacy

- Audio is transcribed on-device and is never uploaded.
- Translating with Apple Translation or MLX does not send caption text off the Mac.
- With Apple Foundation Models, meeting summaries are generated on-device.
- With the OpenAI engine selected, the live transcript is sent to OpenAI in
  chunks as it is translated, with the previous source fragment for context
  and glossary terms (including selected calendar meeting title and attendee
  names when present); enabled meeting summaries are generated by OpenAI.
- If Apple Foundation Models is unavailable on your Mac (for example, Apple
  Intelligence is off) and an OpenAI key is stored, enabled meeting summaries
  automatically send text to OpenAI, even with Apple Translation or MLX selected.
  Each request includes up to 12,000 characters of formatted transcript
  segments (IDs, timestamps in seconds from meeting start, and text), the
  previous summary (up to 6,000 characters), your name aliases and the target
  language. To avoid this fallback with Apple Translation or MLX, do not store
  an OpenAI key (or remove it), or keep Apple Intelligence and Foundation
  Models available.
- With default settings (Apple Translation, no stored OpenAI key), the app's
  own code makes no network requests. macOS frameworks may download language
  packs and speech assets; the MLX engine downloads from huggingface.co, and
  OpenAI translation or summaries talk to api.openai.com.
- Meeting records and summaries are stored on your Mac.

Run the repository privacy gate before publishing:

```bash
python3 tools/privacy_audit.py
```

It checks tracked files for local user paths, private keys, common API tokens,
cloud worker subdomains and provisioning-profile file types. It is a baseline,
not a substitute for reviewing the final tree and git history.

## Model and framework licenses

- Apple frameworks are provided by macOS and are subject to Apple's terms.
- TranslateGemma is subject to the Gemma Terms of Use. The model is downloaded
  separately and is not distributed in this repository.
- MLX and MLX Swift are subject to their own licenses.
- Third-party Swift packages retain their original licenses; see `NOTICE.md`
  and `Vendor/ThirdPartyLicenses` (copied into the app as Resources/ThirdPartyNotices).
  Swift Package Manager dependency licenses are in their package checkouts;
  they are not all copied into this repository.

## Trademarks

The MIT license covers the source code. It does not grant permission to use the
Kikishima name, logo, app icon or other brand assets to identify a fork or a
redistribution. See `TRADEMARKS.md`.

## License

MIT. See `LICENSE`.

Copyright (c) 2026 Lingjie Yang, released under the MIT License (see LICENSE).

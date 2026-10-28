# Kikishima

Local-first meeting captions and translation for macOS.

Kikishima listens to system audio, transcribes it on-device with Apple's Speech
framework, and translates the result without sending meeting text to a
Kikishima server. It can also generate meeting summaries locally.

This repository is the open-source, payment-free edition. There is no account,
no subscription, no quota and no Kikishima API dependency.

## Features

- On-device speech recognition with Apple `SpeechAnalyzer`.
- Menu bar captions, a floating desktop caption window, and a notch/island mode.
- Translation engines:
  - **Apple Translation** (default): on-device, no model download, fast.
  - **MLX TranslateGemma** (optional): higher quality, downloads a local model.
  - **Your own OpenAI key** (optional): best quality, direct from your Mac to
    OpenAI.
- Meeting summaries locally with Apple Foundation Models, or through your own
  OpenAI key.
- Meeting records and summaries stay on your Mac.

## Requirements

- macOS 26 or later.
- Apple Silicon.
- Xcode 26 command line tools for building.
- Apple Intelligence enabled for local meeting summaries.
- Optional: a Hugging Face download for the MLX model (about 2.3 GB on 16 GB
  Macs, about 6.6 GB on 24 GB or larger Macs).
- Optional: an OpenAI API key.

## Build

```bash
./build.sh
open build/Kikishima.app
```

`build.sh` compiles the Swift package, copies resources, and ad-hoc signs the
app by default. To sign with your own Developer ID certificate, pass it
explicitly:

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

## Translation engines

The default engine is Apple Translation. It uses the system Translation
framework and may ask macOS to download a language pack the first time you use
a language pair.

The optional MLX engine uses `mlx-community/translategemma-12b-it-4bit` on Macs
with 24 GB or more memory and `mlx-community/translategemma-4b-it-4bit` on
smaller Macs. The model is downloaded on demand from Hugging Face and cached
locally. It is not bundled with the app.

The OpenAI engine stores the key in the macOS Keychain. Caption text is sent
directly from your Mac to OpenAI. It never passes through a Kikishima server.

## Privacy

- Audio is transcribed on-device and is never uploaded.
- With Apple Translation or MLX, caption text does not leave the Mac.
- With Apple Foundation Models, meeting summaries are generated on-device.
- With an OpenAI key, only the text you choose to translate or summarize is sent
  to OpenAI.
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
- Third-party Swift packages retain their original licenses; see
  `Vendor/ThirdPartyNotices` and the package checkouts.

## Trademarks

The MIT license covers the source code. It does not grant permission to use the
Kikishima name, logo, app icon or other brand assets to identify a fork or a
redistribution. See `TRADEMARKS.md`.

## License

MIT. See `LICENSE`.

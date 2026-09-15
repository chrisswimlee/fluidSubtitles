# fluidSubtitles

<p align="center">
  <img src="docs/screenshots/app-icon.png" width="96" alt="fluidSubtitles icon">
</p>

**Captions after each sentence. Korean, English, Thai, and Japanese.**

fluidSubtitles is a live translation and captioning app for macOS. It works among **Korean, English, Thai, and Japanese** in either direction, including same-language captions (English → English, Korean → Korean, Thai → Thai, Japanese → Japanese). Speak one of those languages. After each finished sentence, see a translation or a caption on screen, or type it into the app you are using. It is lectern captions, not word-by-word interpretation. Best with one speaker and a close mic.

![Translate home](docs/screenshots/translate-home.png)

Open **Theater** in the sidebar, pick Korean, English, Thai, or Japanese on each side, then press **Open Theater** and **Listen**. I speak and Show as can also be changed on that window. A new Listen starts with an empty board. Closing Theater hides the window; it does not keep the last talk for the next Listen. A separate shortcut types the current translation into another app. Translation uses Apple’s on-device Translation framework.

![Theater captions](docs/screenshots/theater.png)

**fluidSubtitles is by [Chris Swim Lee](https://chrisswimlee.com), a branch of [FluidVoice](https://github.com/altic-dev/FluidVoice) by altic-dev.** Speech recognition, live engines, and the core macOS app are theirs. This branch adds live translation and Theater captions. Licensed under GPLv3 — please star and support the original project.

---

## Theater captions

1. Use **macOS 15** or later on Apple Silicon. First run uses Apple Speech (Analyzer on macOS 26). Same-language captions need no translation pack.
2. Open **Theater** and pick **Voice** or **Translate**. **Voice Engine** sharpens speech into text. **Translation Engine** is Apple Translation on this Mac (not a chat model). Download the pack only for Translate with two languages.
3. Allow the microphone. **Listen** stays off until Voice Engine and (for Translate) the pack are green.
4. Speak one sentence. **Type into app** unlocks after that first caption. **Copy** always takes everything on screen. **Clear** wipes the board and the session archive; Listen can keep going.

Accessibility permission is only required if you want a translation typed into other apps. Theater captions on your screen do not need it.

---

## How Theater works

Theater is a measured on-device pipeline, not a cloud caption API.

1. **Capture** — The microphone is a first-party Core Audio HAL path, not `AVAudioEngine` on the live path. Voice and Translate both use it.
2. **Speech edges** — Live PCM stays in a 30-second ring. The first ASR tick is immediate. After 400 ms of RMS silence, later ticks are skipped so a long pause does not keep the Neural Engine hot. There is no neural VAD in front of first words.
3. **Commit, then translate** — The current spoken line can type while you talk. A finished sentence or a natural pause starts the Show-as title. Apple Translation runs on commit (`TranslationSession.preferredStrategy = .lowLatency` on macOS 26.4). Same-language pairs skip the pack. Korean, Japanese, and Thai send the last 4 source clauses from this Listen, then peel the new caption. A clause-boundary approximation may prefetch Apple Translation.
4. **Stage window** — A nonactivating panel over Keynote. Hide from Zoom and screen share with `NSWindow.sharingType`. The Show-as title sits above a smaller spoken undertone. Wrap fills left to right. YouTube boilerplate is dropped before print.
5. **Bounded memory** — 30 s of 16 kHz float, the newest 2,400 transcript characters, 200 visible lines, and JSONL overflow for a 3-hour keynote.
6. **Measured clock** — Theater shows `mic · e2e · ASR · MT` from Core Audio host time. Those values come from a real Listen. Hosted CI cannot prove a live Theater listen.

The systems write-up is [docs/APPLE_SILICON_STREAMING.md](docs/APPLE_SILICON_STREAMING.md). Latency budgets and the HUD are in [docs/LIVE_TRANSLATION_LATENCY.md](docs/LIVE_TRANSLATION_LATENCY.md).

---

## Features

- **Korean, English, Thai, and Japanese** — any pair, either direction, including same-language captions without a translation pack. Listen uses a Voice Engine that can hear I speak (Apple Speech, Cohere, or Whisper for Korean and Japanese; Apple Speech or Whisper for Thai; Parakeet Flash is English-only)
- **Theater captions** — a floating window you turn on, edit, and close. Use **Pop-up** for a solid board or **Transparent** so slides show through. On-screen `mic · e2e · ASR · MT` clock. Hide it from screen share. Pause keeps the session warm. Minimize shrinks to a pill. Clear wipes the board and the session archive. A line prints after the sentence, usually a few seconds later.
- **Voice / Translate** — Voice Engine sharpens speech into text. Translate uses Apple Translation on this Mac for Korean, English, Thai, and Japanese captions. Press the mode control to switch. Both use the microphone.
- **Translate into an app** — a separate shortcut from dictation; types this listen’s translation into the app you clicked. Korean, Japanese, and Thai depend on that app’s input method. Accessibility is required.
- **On-device translation** — Apple Translation language packs, processed locally
- **Multiple speech models** — Nemotron, Parakeet, Cohere, Apple Speech, and Whisper
- **Local-first** — voice and text stay on your Mac unless you opt in to a cloud AI provider
- **Menu bar access** — start, stop, and open settings from the menu bar

---

## Supported Models

fluidSubtitles only hears and captions **Korean, English, Thai, and Japanese**. The Voice Engine picker matches that. Upstream weights may have been trained on more languages; this app does not expose them.

| Model | Best for | Hears here | Download size | Hardware |
| --- | --- | --- | --- | --- |
| Nemotron Speech 3.5 — Ultra Fast Low Latency | Streaming Korean, English, Thai, or Japanese | Korean, English, Thai, Japanese (Thai experimental) | ~670 MB | Apple Silicon |
| Nemotron 3.5 Multilingual | Higher-accuracy Korean, English, Thai, or Japanese | Korean, English, Thai, Japanese (Thai experimental) | ~530 MB | Apple Silicon |
| [Parakeet Flash (Beta)](https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1) | Lowest-latency live English. Korean, Japanese, and Thai Listen need another Voice Engine. | English | ~250 MB | Apple Silicon |
| Parakeet TDT v3 | Fast English. Korean, Japanese, and Thai Listen need another Voice Engine. | English | ~500 MB | Apple Silicon |
| Parakeet TDT v2 | Fastest English-only | English | ~500 MB | Apple Silicon |
| Cohere Transcribe | High-accuracy English, Korean, and Japanese | English, Korean, Japanese | ~1.4 GB | Apple Silicon |
| Apple Speech | Zero-download native macOS speech | Korean, English, Thai, Japanese | Built-in | Apple Silicon + Intel |
| Whisper Tiny / Base / Small / Medium / Large | Broad compatibility, including Intel Macs | Korean, English, Thai, Japanese | ~75 MB to ~2.9 GB | Apple Silicon + Intel |

---

## Install

This is a **Developer ID zip**, not TestFlight and not the Mac App Store. The app is unsandboxed (Hardened Runtime on). Theater needs microphone access. Insert-into-another-app needs Accessibility. Voice models and Apple Translation packs download on first use; they are not inside the zip.

1. Download `fluidsubtitles-{version}.zip` from [GitHub Releases](https://github.com/chrisswimlee/fluidSubtitles/releases).
2. Open the app. A notarized zip should stay quiet in Gatekeeper.
3. Open **Theater**, allow the microphone, pick **Voice** or **Translate**, and press **Listen**.

`./build.sh release` writes `dist/fluidsubtitles-{version}.zip` and `dist/SHA256SUMS`. Set `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD` to notarize. A GitHub tag `v*` runs `.github/workflows/release.yml`. Hosted CI cannot sign unless a Developer ID certificate is imported. After that first Developer ID zip, add the team ID to `FluidProduct.allowedUpdateTeamIDs` — the set is empty today, so updates reject every build. Hosted CI cannot prove a live Theater listen.

---

## Requirements

- macOS 15.0 (Sequoia) or later. Theater Listen, Voice, Translate, and language swap work on 15. Apple Speech Analyzer needs macOS 26.
- Apple Silicon Mac for Theater streaming (Parakeet, Nemotron, Cohere). Whisper and Apple Speech can run on Intel for dictation; that is not the Theater path
- ~1 GB disk space for a voice model
- Microphone access for Theater and dictation
- Accessibility permissions if you want a translation typed into other apps
- Download the Apple Translation pack once before a cross-language Listen. Same-language captions do not need a pack.

---

## Building from Source

```bash
open fluidSubtitles.xcodeproj
```

Build and run in Xcode. All dependencies are managed via Swift Package Manager and pinned in `Package.resolved`.

For local signing, copy the example xcconfig and set your Apple team ID (a free Personal Team is enough):

```bash
cp xcconfig/Local.xcconfig.example xcconfig/Local.xcconfig
```

Then run a signed Debug build:

```bash
./build.sh
```

The signed build is written to `DerivedData/Build/Products/Debug/fluidSubtitles Debug.app`.
Keep launching that product after each rebuild so macOS can preserve its Accessibility
authorization.

For CI or contributors who do not have a signing identity, use the unsigned fallback:

```bash
./build.sh unsigned
```

Unsigned builds are tied to a specific executable version and may require Accessibility
permission to be removed and granted again after rebuilding.

Architecture notes live in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Latency budgets and the Theater HUD are in [docs/LIVE_TRANSLATION_LATENCY.md](docs/LIVE_TRANSLATION_LATENCY.md). Score a recorded talk with [docs/STAGE_SCORE.md](docs/STAGE_SCORE.md). Signing and notarization are in [docs/SIGNING.md](docs/SIGNING.md). The systems write-up is [docs/APPLE_SILICON_STREAMING.md](docs/APPLE_SILICON_STREAMING.md).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the first hour (Release zip or signed `./build.sh`, Apple Speech, Theater on macOS 15+, `./scripts/format-and-lint.sh`, tests minus UITests). Please read the [code of conduct](CODE_OF_CONDUCT.md) and [security policy](SECURITY.md) before opening an issue or pull request.

When a change belongs in the upstream dictation engine rather than translation or captions, file it on [FluidVoice](https://github.com/altic-dev/FluidVoice). Starter tickets are listed in [.github/GOOD_FIRST_ISSUES.md](.github/GOOD_FIRST_ISSUES.md).

---

## Run Integration Tests

```bash
xcodebuild test -project fluidSubtitles.xcodeproj -scheme fluidSubtitles -destination 'platform=macOS'
```

CI uses unsigned builds:

```bash
xcodebuild test -project fluidSubtitles.xcodeproj -scheme fluidSubtitles -destination 'platform=macOS' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

---

## Privacy

fluidSubtitles is **local-first**. Your voice, audio, and transcribed text never leave your machine unless you explicitly opt in to a cloud AI provider.

This release does not send analytics, feedback, or update checks to FluidVoice or to a third-party analytics host.

**Not collected:**

- Voice, raw audio, or transcribed text
- Selected text, prompts, or AI responses
- Terminal commands, window titles, file paths, clipboard, or typed content

---

## License

From 2026-02-23 onward, this project is licensed under the [GNU General Public License, Version 3.0 (GPLv3)](LICENSE).

Versions published before this date were licensed under Apache License 2.0.

Third-party notices for models, frameworks, and logos are in [NOTICE](NOTICE).

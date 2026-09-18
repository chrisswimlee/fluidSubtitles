# fluidSubtitles

<p align="center">
  <img src="docs/screenshots/app-icon.png" width="96" alt="fluidSubtitles icon">
</p>

**Captions that grow while you talk. Korean, English, Thai, and Japanese.**

fluidSubtitles is a live translation and captioning app for macOS. It works among **Korean, English, Thai, and Japanese** in either direction, including same-language captions (English → English, Korean → Korean, Thai → Thai, Japanese → Japanese). Speak one of those languages. A finished sentence plus more speech starts the next pair. A pause commits leftover speech. See a translation or a caption on screen, or type it into the app you are using. Best with one speaker and a close mic.

![Translate home](docs/screenshots/translate-home.png)

Open **Theater** in the sidebar, pick Korean, English, Thai, or Japanese on each side, then press **Open Theater** and **Listen**. I speak and Show as can also be changed on that window. A new Listen starts with an empty board. Closing Theater hides the window; it does not keep the last talk for the next Listen. A separate shortcut types the current translation into another app. Translation uses Apple’s on-device Translation framework.

![Theater captions](docs/screenshots/theater.png)

By [Chris Swim Lee](https://chrisswimlee.com). Licensed under GPLv3.

---

## Theater captions

1. Use **macOS 15** or later on Apple Silicon. First run uses Apple Speech (Analyzer on macOS 26). Same-language captions need no translation pack.
2. Open **Theater** and pick **Voice** or **Translate**. **Voice Engine** and **Translation Engine** are Setup tabs. Voice Engine sharpens speech into text. Translation Engine is Apple Translation on this Mac (not a chat model). An experimental local LLM can sharpen the first print. Download the Apple pack only for Translate with two languages.
3. Allow the microphone. **Listen** stays off until Voice Engine and (for Translate) the pack are green.
4. Optional: import notes or a deck on Theater Home for this talk. Names stay on this Mac. Speak one sentence. **Type into app** unlocks after that first caption. **Copy** always takes everything on screen. **Clear** wipes the board. Talk notes stay. Listen can keep going.

Accessibility permission is only required if you want a translation typed into other apps. Theater captions on your screen do not need it.

---

## How Theater works

Theater is a measured on-device pipeline, not a cloud caption API.

1. **Capture** — The microphone is a first-party Core Audio HAL path, not `AVAudioEngine` on the live path. Voice and Translate both use it.
2. **Speech edges** — Live PCM stays in a 30-second ring. The first ASR tick is immediate. After 400 ms of RMS silence, later ticks are skipped so a long pause does not keep the Neural Engine hot. There is no neural VAD in front of first words.
3. **Grow, then commit** — The live spoken line grows while you talk. End-of-utterance, silence, Pause, or Stop commits leftover speech and starts the next pair. Apple Translation runs on that commit. Same-language pairs skip the pack. Korean, Japanese, and Thai send the last 4 source clauses from this Listen, then peel the new caption. Prefetch may warm Apple Translation; it does not commit.
4. **Stage window** — A nonactivating panel over Keynote. Hide from Zoom and screen share with `NSWindow.sharingType`. The Show-as title sits above a smaller spoken undertone. Wrap fills left to right. YouTube boilerplate is dropped before print.
5. **Bounded memory** — 30 s of 16 kHz float, unread leftover speech, and the 3 on-screen captions. Off-screen lines are dropped.
6. **Measured clock** — Theater shows `mic · e2e · ASR · MT` from Core Audio host time. Those values come from a real Listen. Hosted CI cannot prove a live Theater listen.

The systems write-up is [docs/APPLE_SILICON_STREAMING.md](docs/APPLE_SILICON_STREAMING.md). Latency budgets and the HUD are in [docs/LIVE_TRANSLATION_LATENCY.md](docs/LIVE_TRANSLATION_LATENCY.md).

---

## Features

- **Korean, English, Thai, and Japanese** — any pair, either direction, including same-language captions without a translation pack. Listen uses a Voice Engine that can hear I speak (Apple Speech, Cohere, or Whisper for Korean and Japanese; Apple Speech or Whisper for Thai; Parakeet Flash is English-only)
- **Theater captions** — a floating window you turn on, edit, and close. Use **Pop-up** for a solid board or **Overlay** so only caption text sits on slides. Change Overlay font, size, and plate from the menu-bar Theater menu. On-screen `mic · e2e · ASR · MT` clock. Hide it from screen share. Pause keeps the session warm. Minimize hides Theater; Listen stays. Clear wipes the board. Talk notes stay. Off-screen captions are already gone. Translate shows Behind or Caught up so you do not outrun the caption. The live line grows while you talk; a pause starts the next pair.
- **Voice / Translate** — Voice Engine sharpens speech into text. Translate uses Apple Translation on this Mac for Korean, English, Thai, and Japanese captions. A Setup tab can add an experimental local LLM for first-print sharpening. Press the mode control to switch. Both use the microphone.
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

There is no signed download yet. Pick one:

**Preview zip (no Xcode).** Download `fluidsubtitles-{version}-preview-unsigned.zip` from the newest pre-release on [GitHub Releases](https://github.com/chrisswimlee/fluidSubtitles/releases). It is not signed with a Developer ID or notarized, so macOS blocks it the first time:

1. Unzip it and drag **fluidSubtitles** to Applications.
2. Open it. When macOS says it cannot verify the app, click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to fluidSubtitles. Confirm.
4. Open **Theater**, allow the microphone, pick **Voice** or **Translate**, and press **Listen**.

In-app updates are off for previews. Download each new preview by hand; macOS may ask for Microphone and Accessibility again.

**Build from source (Xcode).** Permissions stay across rebuilds. See [Building from Source](#building-from-source).

The app is unsandboxed (Hardened Runtime on). Theater needs microphone access. Insert-into-another-app needs Accessibility. Voice models and Apple Translation packs download on first use; they are not inside the zip.

Maintainers: push a tag like `preview-1.6.11-1` (`git tag preview-1.6.11-1 && git push origin preview-1.6.11-1`) and the Preview workflow publishes that commit as a pre-release (`./build.sh preview`). A signed release needs a Developer ID: `./build.sh release` with `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`, then a `v*` tag runs `.github/workflows/release.yml`. Hosted CI cannot prove a live Theater listen.

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

You need an Apple Silicon Mac on macOS 15 or later, **Xcode 26** (CI uses 26.3), and a free Apple Account. No paid developer membership.

1. **Get a free signing certificate** (once). In Xcode, open **Settings → Accounts**, add your Apple Account, select its **Personal Team**, click **Manage Certificates…**, then **+ → Apple Development**. Signing keeps Microphone and Accessibility granted across rebuilds.

2. **Clone and build:**

   ```bash
   git clone https://github.com/chrisswimlee/fluidSubtitles.git
   cd fluidSubtitles
   ./build.sh
   ```

   `./build.sh` finds your Apple Development certificate and its team. The first build resolves Swift packages and takes several minutes. With more than one team, pin one:

   ```bash
   cp xcconfig/Local.xcconfig.example xcconfig/Local.xcconfig
   # set DEVELOPMENT_TEAM to your 10-character team ID
   ```

3. **Launch** `DerivedData/Build/Products/Debug/fluidSubtitles Debug.app`. Always launch this same path after rebuilding so macOS keeps its permissions.

4. **First run.** Open **Theater**, allow the microphone, pick **Voice** or **Translate**, and press **Listen**. For Translate, download the Apple Translation pack when asked. Allow Accessibility only if you use Type into app.

5. **Update later:**

   ```bash
   git pull
   ./build.sh
   ```

No certificate? `./build.sh unsigned` builds without one, but macOS may ask for Accessibility again after each rebuild. You can also open `fluidSubtitles.xcodeproj` and run from Xcode. App Swift packages are pinned in `fluidSubtitles.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; root `Package.swift` only builds the C capture helper.

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

This release does not send analytics, feedback, or update checks to a third-party analytics host.

**Not collected:**

- Voice, raw audio, or transcribed text
- Selected text, prompts, or AI responses
- Terminal commands, window titles, file paths, clipboard, or typed content

---

## Credits

fluidSubtitles is built on [FluidVoice](https://github.com/altic-dev/FluidVoice) by altic-dev, which provides speech recognition, the live engines, and the core macOS app. Live translation and Theater captions are added here. If you find it useful, consider starring FluidVoice too.

---

## License

From 2026-02-23 onward, this project is licensed under the [GNU General Public License, Version 3.0 (GPLv3)](LICENSE).

Versions published before this date were licensed under Apache License 2.0.

Third-party notices for models, frameworks, and logos are in [NOTICE](NOTICE).

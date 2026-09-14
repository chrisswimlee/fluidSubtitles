# Architecture

fluidSubtitles is a FluidVoice branch. Speech recognition and the macOS app shell come from upstream. This document is the map of **this product**: Theater captions and dictation insert among Korean, English, and Thai.

```mermaid
flowchart LR
  mic[Microphone] --> asr[ASRService]
  watch[ScreenCaptureKit audio] --> asr
  asr --> stitcher[StreamingTranscriptStitcher]
  stitcher --> subscriber[LiveTranslationSubscriber]
  subscriber --> apple[Apple Translation]
  subscriber --> theater[Theater window]
  subscriber --> insert[Insert into frontmost app]
  subscriber -.-> mlx[Optional MLX polish]
```

## What to work on

| Area | Path | Role |
| --- | --- | --- |
| Live translation | `Sources/FluidSubtitles/Services/LiveTranslation/` | Clause split, Apple Translation, Theater archive, latency HUD, optional MLX. `LiveTranslationSubscriber` owns the session; `LiveTranslationCommitContext` and `LiveTranslationMT` are the commit / translate helpers; `TheaterStatus` is the status channel. |
| Theater UI | `Sources/FluidSubtitles/UI/LiveTranslation/` | Home, Theater window, presenter chrome |
| Speech engine | `ASRService.swift` plus `ASRService+*.swift` | Microphone → transcript. Keep this as the engine, not the product. |
| Dictation insert | `TypingService`, `GlobalHotkeyManager` | Types the current listen into the frontmost app |
| Overlay | `BottomOverlayView`, `NotchOverlayManager` | Dictation preview only |
| Settings | `SettingsStore.swift` plus `SettingsStore+*.swift` | Persist models, shortcuts, Theater options |
| App shell | `ContentView.swift` plus `ContentView+*.swift` | Window, dictation start, insert, onboarding |

New settings belong in a `SettingsStore+*.swift` file, not in the core store. New ContentView routing belongs in `ContentView+*.swift`.

## Live path

1. Theater requires macOS 26. On macOS 15 the sidebar still opens, Listen stays off, and dictation still works. `ASRService` produces partial and final transcripts from the selected Voice Engine. Lectern uses the microphone. Watch uses ScreenCaptureKit system audio (2×2 dummy video, 48 kHz stereo request, mono downmix, process exclusion) and does not need the mic. A howl gate after downmix drops packets that look like a delayed copy of the same capture (virtual/aggregate loopback). Home and Theater pick This Mac or one running app; Safari/Chrome/Firefox include helper processes. This Mac is the default. A silent app stays on that app and waits for audio; it does not flip to This Mac. Start fails on a real `SCShareableContent` check, not only `CGPreflight`. `SCStream` `didStopWithError` ends Listen immediately. **Check capture** starts a short tap and reports energy on the success / info / warning channel, not as a Listen failure. Hosted CI cannot prove Watch.
2. `LiveTranslationController` owns a caption or insert session. Critical thermal can swap this Listen to Apple Speech without writing the Voice Engine setting; the user engine returns on Stop.
3. `LiveTranslationSubscriber` segments clauses, then calls `AppleTranslationEngine` when a clause commits. The current unread clause can print while you talk. A cumulative ASR restitch peels already-printed sentences so the next line is only the new clause. Cross-language commits send the last **4** source clauses **from this Listen** so Korean/Thai keep prior context, then peel the new caption. A clause-boundary approximation can prefetch Apple Translation (`.live`) so the commit can swap in a cached caption. A restored board does not prime the next Listen.
4. Theater prints the spoken line first so both rooms can follow, then the translation finishes below when that setting is on. Overflow past 200 lines is `TheaterSession.jsonl` on a serial flush queue.
5. Insert types only the current listen. Copy takes the whole Theater board. Clear wipes the board and the session archive. Insert needs Accessibility. A Korean or Thai IME (or Show-as Korean/Thai after the first Theater caption) uses Reliable Paste instead of unicode keystrokes.

Apple Translation is on-device. Language packs download the first time a pair is used. Listen waits until the pack reports `.installed`. Theater shows a measured `mic · e2e · ASR · MT` clock. Hide from screen share uses `NSWindow.sharingType`. See [LIVE_TRANSLATION_LATENCY.md](LIVE_TRANSLATION_LATENCY.md) and [APPLE_SILICON_STREAMING.md](APPLE_SILICON_STREAMING.md).

Printed Theater lines stay. The current unread clause can sit on Theater while you talk; a new sentence starts on a new line. Pause and Stop may commit leftover speech; they do not rewrite a caption already on the board. Clear wipes the board and the session archive; Listen can keep going. Close Theater confirms if Listen is running. Undo removes only the last visible line. Korean and Thai wait for a confirm decode before the first print. Commit MT sends up to four prior source clauses, then peels. A running local MLX runner may translate that first print; Apple Translation is the fallback. Score a real talk with `docs/STAGE_SCORE.md`.

## What this product does not include

These FluidVoice surfaces were removed from this branch. Do not add them back without a product decision:

- Command Mode, terminal agent, and command chat history
- Rewrite / Edit Mode
- File Transcription / meetings
- Local HTTP API
- PostHog / analytics export

Dictation typing, Voice Engines, custom dictionary, History, and local Stats stay.

## Identity and data

`FluidProduct` holds the display name, bundle ID, GitHub home, and legacy FluidVoice / connectingCaptions keychain and Application Support names so existing local data still loads after the rename.

## Signing and sandbox

`project.pbxproj` does not contain an Apple team ID. Set `DEVELOPMENT_TEAM` in `xcconfig/Local.xcconfig` or pass `FLUIDSUBTITLES_DEVELOPMENT_TEAM` to `./build.sh`. CI builds unsigned. `./build.sh release` writes a Developer ID zip (`dist/fluidsubtitles-{version}.zip`) and notarizes when Apple credentials are set.

The app is unsandboxed. Lectern Theater and dictation need microphone access. Watch Theater needs Screen Recording. Insert-into-another-app needs Accessibility. Voice weights and Apple language packs stay user-downloaded. Hardened Runtime is on. Unused Xcode resource-access flags (Calendar, Camera, Contacts, Location, USB, Printing, Bluetooth) stay off. Incoming network stays off; the local HTTP API was removed.

`com.apple.security.cs.disable-library-validation` remains because `CTranscribe.framework` (the TranscribeCpp / Whisper dylib) can fail to load after Xcode flattens the XCFramework layout. `./build.sh release` restores the versioned framework layout and re-signs it with the same Developer ID. A Release build that still loads Whisper without the entitlement can drop it.

GitHub `release` jobs import a Developer ID `.p12`, notarize, run `codesign --verify --deep --strict`, `spctl --assess`, and `stapler validate`, then attach `SHA256SUMS`. Missing signing or notarization credentials fail the job instead of publishing an unsigned zip.

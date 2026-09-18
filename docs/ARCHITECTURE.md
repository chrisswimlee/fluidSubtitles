# Architecture

fluidSubtitles is a FluidVoice branch. Speech recognition and the macOS app shell come from upstream. This document is the map of **this product**: Theater captions and dictation insert among Korean, English, Thai, and Japanese.

```mermaid
flowchart LR
  mic[Microphone] --> asr[ASRService]
  asr --> stitcher[StreamingTranscriptStitcher]
  stitcher --> subscriber[LiveTranslationSubscriber]
  subscriber --> apple[Apple Translation]
  subscriber --> theater[Theater window]
  subscriber --> insert[Insert into frontmost app]
  subscriber -.-> mlx[Optional local LLM]
```

## What to work on

| Area | Path | Role |
| --- | --- | --- |
| Live translation | `Sources/FluidSubtitles/Services/LiveTranslation/` | Clause split, Apple Translation, on-screen Theater captions, this-talk notes, pace cue, latency HUD, optional MLX. `LiveTranslationSubscriber` owns the session; `LiveTranslationCommitContext` and `LiveTranslationMT` are the commit / translate helpers; `TheaterStatus` is the status channel. |
| Theater UI | `Sources/FluidSubtitles/UI/LiveTranslation/` | Home, Theater window, presenter chrome |
| Speech engine | `ASRService.swift` plus `ASRService+*.swift` | Microphone → transcript. Keep this as the engine, not the product. |
| Dictation insert | `TypingService`, `GlobalHotkeyManager` | Types the current listen into the frontmost app |
| Overlay | `BottomOverlayView`, `NotchOverlayManager` | Dictation preview only |
| Settings | `SettingsStore.swift` plus `SettingsStore+*.swift` | Persist models, shortcuts, Theater options |
| App shell | `ContentView.swift` plus `ContentView+*.swift` | Window, dictation start, insert, onboarding |

New settings belong in a `SettingsStore+*.swift` file, not in the core store. New ContentView routing belongs in `ContentView+*.swift`.

## Live path

1. Theater Listen, Voice, Translate, and I speak / Show as run on macOS 15 and later. Apple Speech Analyzer stays macOS 26+. `ASRService` produces partial and final transcripts from the selected Voice Engine. **I speak** owns the Voice Engine listening language; leftover Whisper / Apple Speech / Cohere / Nemotron locales are pinned to that language and ASR reloads so Translate cannot start on a stale locale. Translate is I speak → Show as. Speak-either-language of the pair is a later product. **Voice Engine** sharpens speech into text. **Translation Engine** is on-device Apple Translation, with an optional experimental local LLM for first-print sharpening. Both have a Setup tab. **Voice** writes that transcript. **Translate** is Korean, English, Thai, and Japanese captions. Both use the microphone. A button on Home and Theater chrome switches the two. Hosted CI cannot prove a live Theater listen.
2. `LiveTranslationController` owns a caption or insert session. Critical thermal can swap this Listen to Apple Speech without writing the Voice Engine setting; the user engine returns on Stop.
3. `LiveTranslationSubscriber` segments clauses, then calls `AppleTranslationEngine` when a clause commits. The current unread clause can print while you talk. A finished sentence with more speech after it commits mid-talk so each clause can pair Show-as without waiting for a pause. A lone period still waits; a restitch of that open clause stays on this caption and grows it. After a pause, leftover peel drops already-printed sentences so the next pair is only the new clause. Cross-language commits send the last **4** source clauses **from this Listen** so Korean/Japanese/Thai keep prior context, then peel the new caption. A clause-boundary approximation can prefetch Apple Translation (`.live`) so the commit can swap in a cached caption. A running local runner may sharpen that Apple draft before it prints. Theater starts empty on launch and on each new caption Listen. A previous talk or a crash leftover is not restored.
4. Theater stacks the Show-as title above a smaller, dimmer spoken line. The current title types through commit (Flow / Word). Flow walks one letter at a time and pauses at commas and periods. Same-language Voice / English→English has no spoken undertone, so leftover peel after a hard commit runs on the title. End-of-utterance, silence, or Stop commits leftover speech that is a real clause. The Pause button freezes capture and does not flush. Mid-talk, a finished sentence already followed by more speech starts the next spoken / Show-as pair. The last pair stays put. Wrap fills left to right and only starts a new visual line when the board is full. Show-as types first, then spoken. A mid-talk period with no unread speech after it stays on this caption. A narrower window rewraps so the first line is not clipped. The first paint still reserves title-line height so the spoken sentence is not sliced through the middle. **Show the spoken line** off means translation only. Print-in is Flow, Word, Fade, or Instant. **Captions only** keeps Listen and overlays languages on hover so the board does not jump. Transparent Light uses white captions and a dark halo so text stays visible on slides. The window uses the visible display so captions can span the board; a saved 1100×440 frame is upgraded. Off-screen captions are dropped. Minimize hides Theater; Listen stays. Theater is a live subtitle board, not a session archive. Translate can import local notes or a deck. Extracted names lock in `TranslationGlossary` and the optional local LLM prompt until you remove them. Clear leaves that pack. A presenter pace cue is Behind or Caught up; it uses the measured `e2e` clock and is not a score. Voice hides notes and the lamp. A long Korean or Japanese connective can print before the final verb. Settle helpers of 1.0 s / 6.0 s are unused. There is no Zoom virtual microphone and no spoken TTS.
5. Insert types only the current listen. Copy takes the whole Theater board. Clear wipes the board. Talk notes stay until you remove them. Insert needs Accessibility. A Korean, Japanese, or Thai IME (or Show-as Korean/Japanese/Thai after the first Theater caption) uses Reliable Paste instead of unicode keystrokes.

Apple Translation is on-device. Language packs download the first time a pair is used. Listen waits until the pack reports `.installed`. Theater asks Apple only for this Korean / English / Thai / Japanese pair and does not enumerate every system locale. Theater shows a measured `mic · e2e · ASR · MT` clock. Hide from screen share uses `NSWindow.sharingType`. See [LIVE_TRANSLATION_LATENCY.md](LIVE_TRANSLATION_LATENCY.md) and [APPLE_SILICON_STREAMING.md](APPLE_SILICON_STREAMING.md).

Printed Theater lines stay put for this Listen. The board only slides up slowly when a new line needs room on a full board. A new Listen or a new app start wipes the board. The current unread clause can sit on Theater while you talk. A restitch of the open clause grows this pair in place; it does not blank the row. A finished sentence plus more speech commits the finished pair and peels the live row to the new clause. After a pause, leftover peel drops already-printed sentences. Finished lines keep their size. The first words of a clause can print before it is ready to commit. A natural pause commits leftover speech that is a real clause. Pause and Stop do not rewrite a caption already on the board. Clear wipes the board. Talk notes stay; Listen can keep going. Close Theater confirms if Listen is running. Undo removes only the last visible line. Korean, Japanese, and Thai print from the live stitch; a fuller decode runs on silence and Stop leftover only. Commit MT sends up to four prior source clauses, then peels. Setup → Translation Engine can plug in an experimental local LLM; a running runner may sharpen that Apple first print, and Apple Translation is the fallback. Score a real talk with `docs/STAGE_SCORE.md`.

## What this product does not include

These FluidVoice surfaces were removed from this branch. Do not add them back without a product decision:

- Command Mode, terminal agent, and command chat history
- Rewrite / Edit Mode
- File Transcription / meetings
- Local HTTP API
- PostHog / analytics export
- A first-party Zoom / Teams virtual microphone or spoken English TTS driver. Theater stays captions. Play committed audio to a user-picked device is a later product.
- Either way: speak either language of the pair and flip Apple Translation. Translate stays I speak → Show as. The flip path stays in the tree for a later release.

Dictation typing, Voice Engines, custom dictionary, History, and local Stats stay.

## Identity and data

`FluidProduct` holds the display name, bundle ID, GitHub home, and legacy FluidVoice / connectingCaptions keychain and Application Support names so existing local data still loads after the rename.

## Signing and sandbox

`project.pbxproj` does not contain an Apple team ID. Set `DEVELOPMENT_TEAM` in `xcconfig/Local.xcconfig` or pass `FLUIDSUBTITLES_DEVELOPMENT_TEAM` to `./build.sh`. CI builds unsigned. `./build.sh release` writes a Developer ID zip (`dist/fluidsubtitles-{version}.zip`) and notarizes when Apple credentials are set.

The app is unsandboxed. Theater and dictation need microphone access. Insert-into-another-app needs Accessibility. Voice weights and Apple language packs stay user-downloaded. Hardened Runtime is on. Unused Xcode resource-access flags (Calendar, Camera, Contacts, Location, USB, Printing, Bluetooth) stay off. Incoming network stays off; the local HTTP API was removed.

`com.apple.security.cs.disable-library-validation` remains because `CTranscribe.framework` (the TranscribeCpp / Whisper dylib) can fail to load after Xcode flattens the XCFramework layout. `./build.sh release` restores the versioned framework layout and re-signs it with the same Developer ID. A Release build that still loads Whisper without the entitlement can drop it.

GitHub `release` jobs import a Developer ID `.p12`, notarize, run `codesign --verify --deep --strict`, `spctl --assess`, and `stapler validate`, then attach `SHA256SUMS`. Missing signing or notarization credentials fail the job instead of publishing an unsigned zip.

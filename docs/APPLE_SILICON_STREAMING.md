# Optimizing Local Streaming Translation on Apple Silicon: Speech Edges, Context Windows, and CoreAudio Latency

fluidSubtitles is a local Theater caption app for Korean, English, and Thai. Theater needs macOS 26. Speech recognition and the macOS shell come from [FluidVoice](https://github.com/altic-dev/FluidVoice). This branch adds clause-level Apple Translation, a measured latency clock, and a bounded 3-hour caption budget.

This note is the systems story, not a pitch. Numbers in the Theater HUD are measured. Numbers in tables below are budgets until you fill them from a recording.

## Pipeline

```mermaid
flowchart TD
  mic[Microphone HAL] --> ring[30s 16kHz ring]
  ring --> rms[RMS silence gate]
  rms --> asr[Timer ASR ticks]
  asr --> clause[Leftover-tail clauses]
  eou[Flash EOU English] --> clause
  clause --> mt[Apple Translation]
  mt --> hud[Theater HUD]
  thermal[thermalState readout] --> hud
  clause --> window[200-line window]
  window --> archive[JSONL overflow]
```

1. Direct Core Audio captures one input stream. Packets carry `inputHostTime`. Watch instead starts an `SCStream` with `capturesAudio`, 48 kHz / 2 ch, a 2×2 1 fps dummy video output, and PID exclusion of this process. App capture includes browser helpers (Safari → WebKit, Chrome helpers). Multi-channel float or int16 buffers are downmixed to mono. A howl gate then drops packets that look like a delayed copy of the same capture (virtual/aggregate loopback). It does not subtract the hardware output mix — that mix is the program. Then the same 16 kHz pipeline. Pause drops packets before `handle` and resets the sample-time anchor on resume so a hole does not look like silence. A dead stream calls `handleWatchCaptureStopped` and clears Listen. **Check capture** and the Watch probe test start a real stream when Screen Recording is granted.
2. PCM is resampled to 16 kHz and kept in a 30-second ring. Hours of audio are not retained.
3. ASR ticks on a timer (Parakeet Flash: 200 ms). The first tick is not gated. After 400 ms of RMS silence, later ticks are skipped.
4. The growing transcript is split into finished clauses plus an open tail. Already-committed prefixes are stripped so the whole talk is not re-translated. During Theater, the live stitch is capped to the newest ~2,400 characters so a long listen cannot feed hours of text into every tick. Dictation Stop still stitches the full listen.
5. Theater holds the open clause off screen. Apple Translation runs when a clause commits, then the translated sentence types out. Same-language pairs print the spoken sentence without a pack.
6. English, Thai, and Korean wait for a strong ending plus a language confirm (1.0 / 1.5 / 2.0 s). A long unpunctuated tail prints once it has about eight English words or 36 Korean/Thai characters. Thin starters like “It.” do not print. Korean/Thai 30-second confirm runs on Pause and Stop, not on each mid-talk line. Parakeet end-of-utterance does not dump the open tail.

## Why first words are not VAD-gated

A neural VAD in front of first words adds “did speech start?” delay and another Neural Engine client next to ASR and Translation. That is the wrong default for a keynote.

What we do instead:

- **RMS hold** using the existing capture `silenceThreshold`. First tick is immediate. After 400 ms below threshold, skip ASR ticks and start a new e2e measurement on the next voiced packet.
- **English Flash EOU** is already computed by `StreamingEouAsrManager`. A rising edge is a pause, not a commit. Theater holds 400 ms so the last ASR tick can land, then restarts settle. The clause still waits for a strong ending or the open-thought timeout.
- **Partial correction** is a fuller re-decode of the retained 30-second window. It runs on Stop and once per pause after the RMS hold, so a revised last sentence can replace the line already on the board. It does not run on every ASR tick.

Word-by-word Apple Translation stays out. The Neural Engine translates one finished clause at a time.

## Context windows

The live Apple path still has no prompt. On commit, Theater sends the last 4 source clauses from this Listen plus the new one, then peels the new caption. A clause-boundary approximation may prefetch that same payload so the print is already warm. Pronoun and zero-subject Korean can still drift. Do not describe this as a streaming context window on the Neural Engine.

## CoreAudio

Capture is a first-party HAL IO path (`DirectCoreAudioInput` + a C ring), not `AVAudioEngine` on the live path. `AVAudioEngine` remains as dead fallback because device changes could block or crash it.

Host time on every packet is the e2e clock. Theater needs microphone permission. Insert-into-another-app needs Accessibility. Those are separate.

Devices must expose **one** input stream. Virtual devices are allowed (liveness fails open; clamshell still accepts external/virtual). Multi-stream aggregates fail with a clear error.

The app is **not sandboxed**. Hardened Runtime is on. Language packs and voice weights are user-downloaded (Apple Translation packs, Hugging Face Core ML / GGUF). Nothing of substance is vendored in the zip.

## Memory for a 3-hour keynote

| Resource | Bound |
| --- | --- |
| Live PCM | 30 s @ 16 kHz float |
| Live Theater transcript | newest 2,400 characters |
| Theater SwiftUI board | 200 committed lines |
| Overflow | `TheaterSession.jsonl` under Application Support |
| UserDefaults snapshot | visible window only |

Theater status becomes `Showing last 200 of N` after overflow. Bilingual export reads the archive plus the window. SRT/VTT use commit times when every cue has a date; otherwise they fall back to 4-second slots.

## Quantization and weights

Voice engines (Parakeet, Nemotron, Cohere, Whisper) download at first use. Apple Translation downloads a language pack the first time a pair is used. Listen is gated until the pack reports `.installed`. Theater keeps the Voice Engine you picked, except on **critical** thermal: that Listen can fall back to Apple Speech without writing the setting, then restore the user engine on Stop. English-only Parakeet cannot hear Korean or Thai; Listen stays off until you switch engine. No API key is required for the live Theater path.

## Thermal

`thermalState` is shown on the HUD. On serious or critical thermal, Theater skips extra ASR ticks after the 400 ms silence hold. First words and voiced speech still run. Translation is not paused. Critical thermal may also swap this Listen to Apple Speech (session-only).

## 60-second demo shot list

Record raw. No deck.

1. Open Theater on Apple Silicon. Pair English → Korean or English → Thai.
2. Press Listen. No API key, no cloud indicator.
3. Speak a short clause. Show the HUD: `e2e · ASR · MT · thermal`.
4. Hide chrome. The compact `Nms` readout stays in the corner.
5. Pause, then speak again. The clock resets for the next clause.
6. Optional: let the board pass 200 lines in a longer take and show `Showing last 200 of N`.

Fill the HUD numbers from that recording into this note before you publish the repo.

## What this is not

- Not a general translator. Product languages are Korean, English, and Thai.
- Not TestFlight or the Mac App Store. Distribution is a Developer ID zip on GitHub Releases. See the README.
- Not a claim that classic VAD, CoreAudio p99 jitter, or thermal throttling are solved.

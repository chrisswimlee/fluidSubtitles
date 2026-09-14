# Good first issues

File these on the public GitHub repo with labels `good first issue` and `help wanted`. Each ticket stays inside Theater docs, `LiveTranslation/`, or a small test. Do not point first-time contributors at `ASRService` or FluidVoice grandparents.

Copy one block per issue.

Settings search already finds Watch, Check capture, and This Mac. The latency HUD tokens are in [docs/LIVE_TRANSLATION_LATENCY.md](../docs/LIVE_TRANSLATION_LATENCY.md). Stage-score JSONL layout is in [docs/STAGE_SCORE.md](../docs/STAGE_SCORE.md). Theater smoke looks for `theater.status` after Open Theater.

---

## Getting Started can open Screen Recording settings

**Labels:** `good first issue`, `enhancement`

**Problem:** Getting Started asks for Screen Recording and calls `ScreenRecordingAccess.request()`. If the user already denied the prompt, there is no “Open Settings” path like the microphone row.

**Where to edit:** `Sources/FluidSubtitles/UI/WelcomeView.swift` and `Sources/FluidSubtitles/Services/LiveTranslation/ScreenRecordingAccess.swift`.

**Done when:** A denied Watch grant can open System Settings the same way the microphone row does. No ASR changes.

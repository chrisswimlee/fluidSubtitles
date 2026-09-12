# Live translation latency

Theater shows a measured clock: `mic · e2e · ASR · MT · thermal`. Those HUD values come from a real Listen. They are not the budget table below.

`mic` is Listen start to the first Core Audio buffer. End-to-end is speech-start (Core Audio `inputHostTime` on the first packet above the RMS gate) to the matching committed translation. `MT` is Apple Translation only. Do not read MT as audience latency.

The HUD stays visible when chrome is hidden.

`TranslationSession.preferredStrategy = .lowLatency` is a **macOS 26.4** API. On 26.0–26.3 the same warm session is used without that flag. Theater translates a clause when it commits, not on every ASR partial.

Apple Translation is warmed when the language pair changes (swap or I-speak / caption pickers) and again on Listen. The first clause still includes pack-ready plus `TranslationSession.prepareTranslation()` if those have not finished. That setup cost is not the per-clause `MT` readout.

Serious and critical thermal thinning of the post-hold ASR silence-edge tick lives in `LiveTranslationSilenceGate`.

## Budgets (not measured HUD)

Planning budget for the default EN + Parakeet Flash path on one M-series machine. Not a p99 SLO. Do not copy these rows into the Theater clock. Fill HUD numbers from a recorded Listen.

Korean and Thai Listen must not use Flash or TDT v2. Theater switches those to Apple Speech or Whisper. Use the KO/TH confirm row below, not the Flash preview tick:

| Stage | Budget |
| --- | --- |
| Parakeet Flash preview tick | ~200 ms |
| Clause confirm (English / Thai / Korean) | 1.0 s / 1.5 s / 2.0 s after a strong ending |
| Open-thought fallback | 3.5 s / 4.0 s / 6.0 s of no new words |
| Apple Translation `lowLatency` (short clause) | typically 50–200 ms |
| Audience sees the caption | 3–8 s after the speaker finishes that sentence |

English mid-listen confirmation re-decode is skipped so preview ticks keep the Neural Engine. Korean and Thai confirm before the first print. A fuller pass still runs on Stop and on the first silence hold for leftover speech only. A caption already on the board stays.

Speech edges: the first ASR tick is immediate. After 400 ms of RMS silence, one last tick still runs, then later ticks are skipped so a long keynote pause does not keep the Neural Engine hot. Parakeet end-of-utterance restarts settle after a 400 ms hold; it does not commit an open tail. Theater waits for a strong ending plus the language confirm, or the longer open-thought timeout. Same-language pairs skip Apple Translation and print the spoken sentence. There is no neural VAD on this path.

Memory: live PCM is 30 seconds of 16 kHz float. The live Theater transcript keeps the newest 2,400 characters. Theater keeps a 200-line visible window. Overflow is JSONL under Application Support (`TheaterSession.jsonl`). Export bilingual text from the full archive. SRT/VTT use commit times when every cue has a date; otherwise they fall back to 4-second slots.

After a real Listen, Theater writes `LastListenLatency.json` under Application Support. Paste those numbers here. Do not invent HUD values. Score captions with [STAGE_SCORE.md](STAGE_SCORE.md).

See [APPLE_SILICON_STREAMING.md](APPLE_SILICON_STREAMING.md).

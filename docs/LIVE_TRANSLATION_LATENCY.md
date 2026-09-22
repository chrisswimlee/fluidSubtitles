# Live translation latency

Theater shows a measured clock: `mic · e2e · ASR · MT · thermal`. Those HUD values come from a real Listen. They are not the budget table below. Leftover Watch capture used `cap` for first audio; that is not first-hour product.

| Token | Meaning |
| --- | --- |
| `mic` | Lectern: Listen start to the first Core Audio buffer |
| `cap` | Leftover Watch capture only: Listen start to the first captured audio packet |
| `e2e` | Speech-start (Core Audio `inputHostTime` on the first packet above the RMS gate) to the matching committed translation |
| `ASR` | Speech engine time for that clause |
| `MT` | Apple Translation only. Do not read MT as audience latency. |
| `thermal` | Thermal state when the clock was written |

End-to-end is speech-start to the committed caption, which is the first time the audience sees that clause. `MT` is Apple Translation only.

The HUD stays visible when chrome is hidden.

Apple Translation uses a warm `TranslationSession`. Hosted CI builds with the Xcode 26.3 SDK, so the later `preferredStrategy` API is not linked. Theater translates a clause when it is accepted, not on every ASR partial. A speculative Apple-only prefetch may start at a clause-boundary approximation and stay off the board. The commit reuses that prefetch only when the unit is the same clause. The HUD `MT` value is the commit-path wait: 0 on an Apple cache hit that was not sharpened, otherwise Apple plus optional first-print polish. Prefetch does not use local MLX and must not starve a queued commit. A later commit submits as soon as its clause is known. A running experimental local LLM may sharpen the Apple line before it appears; a miss or timeout keeps the Apple line.

Apple Translation is warmed when the language pair changes (swap or I-speak / caption pickers) and again on Listen. The first clause still includes pack-ready plus `TranslationSession.prepareTranslation()` if those have not finished. That setup cost is not the per-clause `MT` readout.

Serious and critical thermal thinning of the post-hold ASR silence-edge tick lives in `LiveTranslationSilenceGate`. Critical thermal can also swap this Listen to Apple Speech (session-only; the user’s Voice Engine is restored on Stop). Serious stays on thinning only.

## Budgets (not measured HUD)

Planning budget for the default EN + Parakeet Flash path on one M-series machine. Not a p99 SLO. Do not copy these rows into the Theater clock. Fill HUD numbers from a recorded Listen.

Korean, Japanese, and Thai Listen must not use Flash or TDT v2. Theater refuses Listen until you pick an engine that hears that language. Use the KO/JA/TH confirm row below, not the Flash preview tick:

| Stage | Budget |
| --- | --- |
| Parakeet Flash preview tick | ~200 ms |
| Hard commit | End-of-utterance, RMS silence hold, or Stop. The Pause button does not flush. |
| Commit-time line split | 12 English words / 80 KO/JA/TH characters, only when leftover is flushed |
| Apple Translation `lowLatency` (short clause) | typically 50–200 ms |
| Audience sees the caption | 3–8 s after the speaker finishes that sentence |

English mid-listen confirmation re-decode is skipped so preview ticks keep the Neural Engine. Korean, Japanese, and Thai confirmation still runs on Stop and on the first silence hold, and only for leftover speech that is not yet painted. A caption already on the board stays.

Speech edges: the first ASR tick is immediate. After 400 ms of RMS silence, one last tick still runs, then later ticks are skipped so a long keynote pause does not keep the Neural Engine hot. Parakeet end-of-utterance holds 400 ms, then commits leftover speech that is a real clause. A mid-talk period commits only when more speech already follows that finished sentence. A twelve-word timer stays pause-only. Same-language pairs skip Apple Translation and print the spoken sentence. There is no neural VAD on this path.

Memory: live PCM is 30 seconds of 16 kHz float. The live Theater transcript keeps unread speech only. Theater keeps the 3 on-screen captions. Off-screen lines are dropped. Export bilingual text from the visible board. SRT/VTT use commit times when every cue has a date; otherwise they fall back to 4-second slots.

The presenter pace cue repeats the last measured `e2e` when the spoken line is still ahead of the printed caption. It is not a second score.

Korean and Japanese clause rules stay until a scored talk. Do not invent a new land.

After a real Listen, Theater writes `LastListenLatency.json` under Application Support. Paste those numbers here. Do not invent HUD values. Score captions with [STAGE_SCORE.md](STAGE_SCORE.md).

See [APPLE_SILICON_STREAMING.md](APPLE_SILICON_STREAMING.md).

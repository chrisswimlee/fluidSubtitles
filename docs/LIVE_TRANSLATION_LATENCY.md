# Live translation latency

fluidSubtitles keeps FluidVoice’s live ASR path and adds a 200 ms debounce before Apple Translation.

`TranslationSession.Strategy.lowLatency` is a **macOS 26.4** API. On 26.0–26.3 the same warm session is used without that flag.

Each draft logs `Live translation {src}->{dst} {ms}ms` and `Apple Translation finished in {ms}ms`. Duplicate in-flight drafts are dropped via `lastSubmittedSource` so ASR and Translation do not queue on the Neural Engine.

Budgets used for the default EN + Parakeet Flash path (M4 Pro / macOS 26):

| Stage | Budget |
| --- | --- |
| Parakeet Flash preview tick | ~200 ms |
| Draft debounce | 200 ms |
| Apple Translation `lowLatency` (short clause) | typically 50–200 ms |
| Audience sees target draft | about 400–700 ms after speech |

LM Studio polish is **off the live path**. It only runs on the finished line when the setting is enabled.

ANE overlap: ASR and Translation may share the Neural Engine. If drafts stall, the subscriber drops in-flight duplicates (`lastSubmittedSource`) instead of queueing.

Checked on this Mac: `LanguageAvailability` reports EN→TH as **supported** (pack not installed yet). First use must download the Apple language pack from Live Translation; after that, the 50–200 ms translate budget applies. A CLI probe of `TranslationSession(installedSource:)` skipped until the pack is present.

`ASRService.commitStreamingSegment()` is intentionally **not** used. A 30-minute talk is ~115 MB of 16 kHz float audio.

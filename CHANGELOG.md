# Changelog

All notable changes to fluidSubtitles are documented in this file.

## [Unreleased]

- Getting Started lists Screen Recording for Watch next to the Lectern microphone. The microphone permission string no longer claims audio never leaves this Mac. README screenshots show the current Theater home and board.
- Theater Open / Listen / Stop use the same buttons and copy on Home, Settings, History, and the window. Settings cards use the same section headers as Theater.
- Theater chrome groups delivery and Board controls, keeps Captions only on the bar, and confirms Close while Listen is running. Home has Pause. Undo removes the last printed line. Menu bar says Open Theater home / Show Theater.
- Theater can Clear the caption board and session archive from the window or Theater Window settings. Listen keeps going.
- TheaterSession.jsonl overflow writes on a serial queue with a batched flush so clause commits do not fsync on the MainActor.
- Type into app uses Reliable Paste when a Korean or Thai IME is selected, or when Show-as is Korean/Thai after the first Theater caption.
- Cross-language commits can reuse a speculative Apple Translation started at a clause-boundary approximation. Live prefetch does not preempt a queued commit and does not use local MLX.
- Critical thermal can use Apple Speech for this Listen only; the Voice Engine setting is unchanged. Serious thermal still only thins silence-edge ASR ticks.
- Watch drops packets that look like a delayed copy of the same capture (virtual/aggregate howl). Check capture warns when default output looks like loopback. Process exclusion stays; the hardware output mix is not subtracted.
- README now has a How Theater works section for the on-device capture, commit, wrap, memory, and measured-clock path.
- First run uses Apple Speech Analyzer on macOS 26 (Flash is under Show other models), defaults to same-language captions, and waits for a translation pack before Open Theater when the pair is two languages. The landing page says Theater needs macOS 26 and Apple Silicon.
- Watch stays on the chosen app when audio has not started yet, instead of flipping to This Mac. Check capture success and failure use different status styles. Export, Retry, and Listen restore key the same way Theme and Pause already do.
- Theater can be a solid Pop-up board or a Transparent overlay over slides. Switch it in Theater Window or on the board; Open / Close Theater turns the window on or off.
- Theater (Listen, Watch, floating captions) requires macOS 26. Dictation still runs on macOS 15.
- Changing I speak no longer swaps the Voice Engine. Listen stays on the model you picked and tells you if it cannot hear that language.
- A new Listen no longer sends the previous talk’s last clauses into Apple Translation or MLX. Korean zero-subject context stays inside this Listen.
- A spoken paragraph without a period now prints after about eight words (or 36 Korean/Thai characters) so the audience can follow. Thin ASR starters like “It.” wait until they grow into a real clause. Korean and Thai no longer wait for a 30-second re-decode before the first mid-talk line. Follow-along cuts at a comma or “and”, and a new Listen can repeat the last greeting.
- Theater can sit over Keynote without stealing key (nonactivating panel). Chrome takes key for Theme, font, hide, Pause, and Edit, then gives it back unless the caption editor is open. Pause keeps ASR warm and does not rewrite printed lines. Minimize shrinks the board to a pill.
- Watch mode captions audio other apps play (ScreenCaptureKit). Home and Theater pick This Mac or a running app; Safari/Chrome/Firefox include helper processes. A silent app waits for audio instead of flipping to This Mac. Check capture starts a short tap and reports whether audio arrived. If Screen Recording was just granted, Listen says to quit and reopen. If the stream dies, Listen ends. Lectern stays on the microphone. DRM and some calls stay silent.
- Drop YouTube boilerplate and clause-level loops before a line prints. Short acknowledgements and Korean/Thai emphasis stays.
- Apple Speech (macOS 26+) now follows I speak (Korean, English, or Thai) instead of the Mac locale, so Speech Analyzer no longer fails with “Current locale is not supported.”
- Drop leftover FluidVoice file-transcription APIs and Voice Engine language lists. This app only hears Korean, English, and Thai.
- Theater home is now header actions, languages, and blockers only. Getting Started, onboarding, and Settings drop leftover FluidVoice copy and the extra Open Theater / credit cards.
- Theater Listen and dictation both pin Whisper to I speak. The Voice Engine picker no longer offers Automatic or unused Whisper locales.
- Theater can hide from Zoom, Keynote, and screen recordings while still showing on this Mac and a wired projector. The latency clock now reports request-to-first-buffer as `mic`. Whisper can auto-detect English, Korean, and Thai questions. Import lecture terms as JSON. Short first greetings and Theater Listen are not thrown away as silence.
- Listen stays off until the Voice Engine, translation pack, and microphone are ready. Type into app stays hidden until the first Theater caption.
- Korean and Thai print after a fuller 30-second confirm, not a preview tick. Commit translation sends up to four prior source clauses. A running local MLX runner can translate the first print; Apple Translation is the fallback.
- Score a recorded talk with `scripts/score-theater-talk.py` and `docs/STAGE_SCORE.md`. Signing and notarization steps are in `docs/SIGNING.md`.
- On a pause, re-decode leftover speech only. A caption already on the board stays; Pause, Stop, and polish do not rewrite it.
- Theater says captions print after each sentence. Before a talk: Voice Engine, one close mic, macOS 15 vs 26, and that SRT/VTT times are commit times. Type into app notes Korean/Thai IME limits.
- A failed translation retries once after two seconds. The last Listen clock is written to Application Support as `LastListenLatency.json`.
- On a hot Mac, skip extra ASR ticks after the 400 ms silence hold (serious/critical). First words and voiced speech still run.
- Apple Translation now sees the last 1–2 source clauses, then peels the new caption. Korean zero-subject lines keep a little prior context.
- Warm the language pack when I speak / Show as changes, not only when Listen starts.
- SRT/VTT use commit times when every cue has a date; otherwise they still use 4-second slots.
- Overflow JSONL fsyncs after each batch. Thai/Korean Theater warns when the Voice Engine is English-only or Nemotron Thai experimental.
- Theater Listen follows I speak: English-only Parakeet engines are switched off for Korean and Thai, and an uninstalled model falls back to Apple Speech when that locale is on the Mac. The language card shows which engine will hear the speaker.
- Optional MLX polish stays off the printed board so a later cleanup cannot rewrite a line the audience is already reading.
- Score printed same-language captions for English, Korean, and Thai with a local 15% error bar so a stage Listen can be checked without a BLEU suite.
- On Stop, apply the fuller 30-second re-decode to the last leftover even after Theater already has lines. Parakeet end-of-utterance now holds 400 ms and restarts settle instead of being ignored. After 400 ms of quiet, one last ASR tick still runs. Insert Listen waits for the language pack the same way caption Listen does. Apple Translation prefers the warm session over a new session per clause.
- When a bilingual Theater caption wraps, show English with Korean or Thai line by line. Line breaks stay fixed while the sentence types, and the next wrap-pair waits until the current one finishes.
- Hold Theater captions until a sentence is finished, then print that one clause. Incomplete speech stays off the board; Parakeet end-of-utterance no longer dumps the open tail.
- Allow English, Korean, and Thai to caption themselves (no translation pack). Cross-language pairs still use Apple Translation.
- Lead the first-run app with Theater: shorter onboarding, a captions-first sidebar, Listen on the Theater page, and dictation AI under Settings.
- Keep I speak and Show as visible on Theater, including captions-only. The theme control no longer crowds them off the bar.
- Print Theater captions slowly as a visual aid. A line only grows or takes back one word at a time. Already-printed text is not rewritten; a correction trims from the end. A new sentence starts on a new line.
- Keep Theater on one spoken line: the current sentence can print while you talk, and leftover speech no longer reprints earlier sentences or goes blank after a restitch.
- Cross-language Theater prints what you said first, then the translation types in below. It does not wait for Pause. Same-language talks stay one line.
- Keep captions moving on a long talk. Peeling printed clauses off the live transcript no longer rescans it once per committed line, so a full 200-line board costs about 2 ms per speech update instead of stalling past the next one.
- Prefer a readable typewriter over catching up. A late line keeps walking forward instead of dumping the rest.
- Show real numbers on the Theater latency readout again. It reported only thermal state.
- Drop the unused live-draft translation path and ANE mutex. Theater translates a clause when it commits.
- Cap the live Theater transcript at the newest 2,400 characters so a long Listen cannot feed hours of text into every speech update. Dictation Stop still keeps the full listen.
- Remove Command Mode, Rewrite/Edit Mode, File Transcription, the local HTTP API, and PostHog analytics so the tree matches Theater + dictation.
- Optional Gemma / MLX polish stays off the live clause. It can rewrite a finished caption only, using prior lines for Korean omitted subjects.
- Document the live path in `docs/ARCHITECTURE.md`.
- Slow stale-bot windows to 30/14 for issues and 45/14 for pull requests.
- Pin GitHub Actions to commit SHAs and add Dependabot for Actions.
- Harden update install checks and fail closed when a release cannot be signed.

## [1.6.10] — 2026-02-23

First public tree of fluidSubtitles, a GPLv3 branch of FluidVoice focused on live translation and Theater captions.

- Korean, English, and Thai in either direction via Apple on-device Translation
- Theater floating captions with Listen, Insert, Copy, and Speak/Show on the window
- Captions follow speech, then translate at a pause. Closing Theater hides the window; the board comes back when you open it again
- Visible board keeps 200 lines; older lines stay in a local JSONL archive you can export
- Separate shortcut that types this listen’s translation into another app
- Optional local MLX cleanup on finished lines only
- Analytics endpoint left unconfigured; this release does not send telemetry
- Signing team IDs moved to gitignored `xcconfig/Local.xcconfig`
- Swift package dependencies pinned to revisions

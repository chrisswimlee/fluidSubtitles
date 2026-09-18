# Changelog

All notable changes to fluidSubtitles are documented in this file.

## [Unreleased]

- Launch no longer crashes when SettingsStore reads login-item state. Init uses this store's defaults instead of SettingsStore.shared.
- Apple Translation no longer asks macOS for every locale pair. That list can crash Theater on macOS 26. Pack checks stay on Korean, English, Thai, and Japanese.
- Theater drops a Whisper restitch that repeats the last clause, so the live row does not print the same sentence twice.
- Theater Minimize hides the board so it is not always in front. Listen stays. Open Theater or Show Theater brings it back.
- Either way (speak either language of the pair) is off for now. Translate stays I speak → Show as. The flip path stays in the tree for a later release.
- Translation Engine is its own Setup tab, next to Voice Engine. Apple Translation stays the default. An experimental local LLM can sharpen that Apple first print; Apple stays the fallback.
- Theater wrap fills more of the board and rewraps when the window is narrower. The first spoken sentence keeps a full title-line height so the opening letters are not sliced in half.
- Theater stacks spoken then Show-as and wraps only when a line fills the board.
- Theater keeps filling this caption while you talk. A finished sentence with more speech after it commits that pair mid-talk so English and Korean do not wait for a pause. A lone period still stays on this caption.
- Theater commits leftover speech on end-of-utterance, silence, or Stop. The Pause button freezes capture and leaves printed lines. lineCut splits leftover into history rows; it does not cap the live line.
- Theater types one language at a time and wraps only when the line fills the board. Empty wrap slots are gone so the live row does not bounce at the bottom.
- Theater pins the live row to the bottom only after the board is full. A height shrink or a fitting board no longer flips the scroll.
- Theater ignores a thin mid-talk stub (`It.`) and fills the spoken line before wrapping to Show-as. A real finished sentence plus more speech commits that pair.
- Theater keeps only on-screen captions. Off-screen lines and leftover ASR are dropped.
- After a pause, Theater peels leftover speech from the last printed clause so the next pair is only the new clause.
- Theater can import notes, a PDF, or a JSON name list for this talk. Names stay on this Mac and lock in Apple Translation and the optional local LLM. Slide titles and two-letter acronyms inside words no longer rewrite captions.
- Theater shows a presenter pace cue: whether the audience caption has caught the last spoken clause. The lamp uses the measured e2e clock, not a score.
- A long Korean or Japanese connective can print as a caption. Short tags stay open. The 1.0 s / 6.0 s settle helpers are unused; leftover commits on EOU, silence, or Stop.
- A Zoom virtual microphone and spoken English TTS stay out of Theater. Captions remain the product.
- Translate keeps talk notes on screen as a short name count. Voice hides notes and the pace lamp. Clear wipes captions only. The pace cue is Behind or Caught up.

## [1.6.11] — 2026-09-15

- Theater Listen is Voice or Translate on the microphone. A new Listen starts with an empty board. Watch is not a product path.
- The Show-as title types on top; the spoken line is a smaller undertone you can hide. A finished sentence or a natural pause starts the next title. Leftover speech no longer reprints sentence one plus two.
- First hour is a notarized GitHub Release zip, or a signed `./build.sh` and Apple Speech. Screen Recording is not part of Theater Listen.
- Pause-other-apps is off in the public tree. MediaRemoteAdapter published no license, so it is not linked.
- Hosted CI uses Xcode 26.3, the latest image on macos-15 runners. SwiftLint strict matches this FluidVoice-scale tree.

## [1.6.10] — 2026-02-23

First public tree of fluidSubtitles, a GPLv3 branch of FluidVoice focused on live translation and Theater captions.

- Korean, English, and Thai in either direction via Apple on-device Translation
- Theater floating captions with Listen, Insert, Copy, and Speak/Show on the window
- Captions follow speech, then translate at a pause. Closing Theater hides the window. A new Listen starts with an empty board
- Visible board keeps 200 lines; older lines stay in a local JSONL archive you can export
- Separate shortcut that types this listen’s translation into another app
- Optional local MLX cleanup on finished lines only
- Analytics endpoint left unconfigured; this release does not send telemetry
- Signing team IDs moved to gitignored `xcconfig/Local.xcconfig`
- Swift package dependencies pinned to revisions

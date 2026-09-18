# Changelog

All notable changes to fluidSubtitles are documented in this file.

## [Unreleased]

- An unsigned preview zip can be downloaded from GitHub pre-releases without Xcode. macOS asks for Open Anyway the first time. `./build.sh preview` builds it and the Preview workflow publishes it; signed releases still need a Developer ID.
- Theater's first idle Overlay says how to get back: slides stay clickable, Control-Option-T shows tools, Control-Option-L starts Listen. With presenter shortcuts off it points to the menu bar.
- Theater Home asks who sees captions: Slides in the room (hidden from screen share, still the default) or Zoom or Meet (shown). The window shows a Hidden from Zoom badge, and the menu-bar item says so.
- The Settings shortcut is now Listen and type: it starts its own Listen and types the translation of what you say. The window button stays Type into app and types captions already on the board. The shortcut card shows before the first caption and unlocks after it.
- Type into app is in the menu bar for Overlay. With Accessibility off it opens the Accessibility guide instead of failing, and it no longer marks lines typed when nothing was typed. When every line is typed, it says so.
- Korean, Japanese, or Thai captions still paste, but English dictation no longer switches to paste after a Theater session.
- Talk notes list every name with a delete button and a field to add a name. Names stay for the next talk until Remove.
- Theater keeps a short sliding window for leftover peel and the last four MT priors. Older clauses drop as new ones commit, so a long Listen does not grow without bound. A language change clears that window. Pop-up drops behind Home or Settings when this app becomes front again.
- Launch no longer crashes when SettingsStore reads login-item state. Init uses this store's defaults instead of SettingsStore.shared.
- Theater Overlay is text on slides: idle Overlay hides chrome and click-through, Control-Option-T shows tools, and Control-Option-L starts or stops Listen. Pop-up stays a boxed board. Overlay buttons have hover tags that name them. The menu-bar Theater menu changes font, size, plate, theme, and position while slides stay in front.
- Theater Pop-up no longer stays above Home and Settings. It only floats over other apps, so Setup is not covered. Overlay still sits on slides.
- Apple Translation no longer asks macOS for every locale pair. That list can crash Theater on macOS 26. Pack checks stay on Korean, English, Thai, and Japanese.
- Theater drops a Whisper restitch that repeats the last clause, so the live row does not print the same sentence twice.
- Theater Minimize hides the board so it is not always in front. Listen stays. Open Theater or Show Theater brings it back.
- Either way (speak either language of the pair) is off for now. Translate stays I speak → Show as. The flip path stays in the tree for a later release.
- Translation Engine is its own Setup tab, next to Voice Engine. Apple Translation stays the default. An experimental local LLM can sharpen that Apple first print; Apple stays the fallback.
- Theater wrap fills more of the board and rewraps when the window is narrower. The first spoken sentence keeps a full title-line height so the opening letters are not sliced in half.
- Theater stacks spoken then Show-as and wraps only when a line fills the board.
- Theater keeps filling this caption while you talk. A finished sentence with more speech after it commits that pair mid-talk so English and Korean do not wait for a pause. A finished sentence on its own prints once two recognition updates agree on it.
- Theater commits leftover speech on end-of-utterance, silence, or Stop. The Pause button freezes capture and leaves printed lines. lineCut splits leftover into history rows; it does not cap the live line.
- Theater types one language at a time and wraps only when the line fills the board. Empty wrap slots are gone so the live row does not bounce at the bottom.
- Theater pins the live row to the bottom only after the board is full. A height shrink or a fitting board no longer flips the scroll.
- Theater ignores a thin mid-talk stub (`It.`) and fills the spoken line before wrapping to Show-as. A real finished sentence plus more speech commits that pair.
- The Theater board keeps only on-screen captions. History and export keep the whole talk.
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

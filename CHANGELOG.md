# Changelog

All notable changes to fluidSubtitles are documented in this file.

## [Unreleased]

- Theater Listen is Voice or Translate on the microphone. A new Listen starts with an empty board. Watch is not part of first-hour Theater.
- The Show-as title types on top; the spoken line is a smaller undertone you can hide. A finished sentence or a natural pause starts the next title. Leftover speech no longer reprints sentence one plus two.
- First hour is a notarized GitHub Release zip, or a signed `./build.sh` and Apple Speech. Screen Recording is not part of Theater Listen.
- Pause-other-apps is off in the public tree. MediaRemoteAdapter published no license, so it is not linked.

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

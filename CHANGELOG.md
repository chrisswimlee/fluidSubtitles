# Changelog

All notable changes to fluidSubtitles are documented in this file.

## [Unreleased]

- One unfinished-clause rule: a real clause appears once when finished or confirmed by silence or Stop; caption Pause and Stop drop a leftover fragment; only Listen and type Stop still types a trailing fragment. Pause holds capture, cancels delayed unaccepted flushes, and does not resurrect the drop on Resume.
- Theater Listen leaves spoken words like "period" and "um" on the board. It does not pause the presenter's media, play a stop chime, or switch Parakeet to Faster Long Dictation's incremental window.
- Listen and type asks for Accessibility when the shortcut cannot run. Until macOS allows this app, Left Option and any other Listen and type shortcut never start a Listen.
- The old dictation shortcut no longer starts a separate recording, and releasing it does not stop Theater Listen. Theater Listen and Listen and type are unchanged. A missing dictation callback leaves the microphone idle.
- The Dock icon, menu bar, and in-app mark are a caption lower-third, not chat bubbles. Theater Home leads with the board. The accent defaults to caption gold instead of the dictation teal. The sidebar says fluidSubtitles, live captions.
- Theater Listen is no longer FluidVoice dictation. Captions and Listen and type start as `.theater`, own the ASR partial bus, and skip spoken-send / prompt-mode Stop. Escape stops the mic without dictation Stop. A busy Listen and type start unlocks so the next Listen is not stuck. A sentence stays off the board until it is accepted, then the whole sentence appears once. The first Apple Translation still has a 25 s floor. Leftover peel keeps the Korean, Japanese, or Thai rest of the line. Microphone-change alerts default off and only appear in fluidSubtitles. Settings hide Dictation. A FluidVoice Application Support folder is left alone when FluidVoice is still installed.
- Settings, Getting Started, Feedback, and Theater Home show a For work notice with a commercial-license page and email. A signed offline key replaces that notice with Licensed to the organization. Personal use stays free; Listen stays unlocked.
- Theater wrap fills the line until the next word does not fit. A restitch no longer hops leftover words to the next line at twelve words, and words already on the live row stay when recognition rewrites them.
- Same-language Voice appends each accepted sentence. A lagged restitch does not rewrite a sentence already on the board.
- A leftover caption no longer waits for the next sentence when the last ASR tick of a pause lands late. The pause flush stays, and the first spoken words start typing instead of sitting blank.
- Theater Pop-up always fills this display on Open. Drag a corner to resize; Minimize keeps that size. Overlay stays a caption bar.
- Leftover peel keeps a similar next sentence in English, Korean, Japanese, and Thai. A one-word swap (영어 / 한국어, 英語 / 韓国語) prints as the next line instead of revising the last caption. A pause-cut fragment no longer stays on the live row. A new Listen can still repeat a short greeting; a printed lecture line stays put.
- Theater Home puts this talk on one card: Voice / Translate, languages, Spoken line, and who sees captions, plus a caption-stack preview. Listen is the primary action. Setup Wizard sits on the status row.
- The empty Theater board previews Show-as above spoken using the current pair and Spoken line setting. Hidden from Zoom, talk notes, and the pace cue are chips.
- Theater buttons show a hover label that names them and what they do. Size buttons change spoken and Show-as, not only the spoken line.
- Spoken line is Off, After a pause, or While talking. After a pause is the default: it waits, then translates the whole leftover with context and prints spoken under it. While talking translates word by word and grows spoken under the live title. Setup Wizard, Settings → Theater, and the Theater menu set it.
- The Theater board control is a gear labeled Settings.
- Setup Wizard walks languages, captions, and who sees the board. After first-run onboarding it opens once. Open it again from Setup, Theater Home, Getting Started, or Settings → Theater.
- Voice stays on this caption until a finished sentence has more speech after it, or until a pause. A comma or “and” no longer jumps to the next line mid-thought, and a lone Apple Speech period does not print “talk.” then hop to “talk about it.”
- Theater types one incoming caption at a time. Extra finished sentences stay queued while their translations start, so a restitch does not dump several lines at once.
- Theater commits every finished sentence in a fast restitch and starts each translation immediately, so Show-as does not wait until you stop talking.
- Theater Flow / Word types the Show-as title before spoken, and a row that leaves current still finishes that title instead of dumping it.
- Theater treats only a re-decode-confirmed prefix as ground truth, so a restitch cannot rewrite words already on the live row.
- Theater keeps the live caption's row id when a translation fails or retries, so Flow does not remount and retype the title.
- A first-clause Apple Translation wait uses the 25 s floor; local polish no longer shares that timeout. Stop clears the mailbox in-flight slot so the next Listen is not stuck.
- An unpunctuated pause-cut no longer peels the rest of the same sentence onto a new caption. Unspaced Korean aligns on a shared character run.
- Pending rows reserve the Show-as slot, wrap width follows the board lock, and the board scrolls when a new wrap line appears.
- Theater wrap fills the caption line. A new visual line starts when the next word does not fit.
- Theater keeps a Show-as title that is already on screen: a late polish or empty draft no longer blanks it and dumps the new wording in one step.
- Theater Flow types the Show-as title a little slower, and a finished sentence no longer keeps its last words on the next caption.
- Theater wrap still fills the board, but a new line now starts on a word: opening quotes, hyphens, and Japanese small kana stay with their token instead of sitting alone.
- Theater captions fill the Pop-up panel and grow with the board so a full-screen window is not stuck at the setting size.
- Theater peels a finished sentence off the live row even while its translation is still in flight, and splits an unpunctuated Then / then / And restitch so two sentences do not stay on one caption. "and then" stays on this pair.
- Theater print-in reserves the Show-as slot and the next wrap line, then types on the display refresh so the title does not jump.
- Automatic update checks are off until you turn them on. Feedback and transcription examples stay on this Mac as a local draft; they are not POSTed.
- Dictation history defaults to one year and at most 20,000 rows, with FTS search. Korean, Japanese, and Thai word counts no longer collapse to 1. Quit shuts ASR and Private AI down through terminateLater instead of spinning the main run loop. Update zips are hashed in chunks.

## [1.6.11] — 2026-09-19

- A printed Show-as title no longer vanishes when the next sentence starts or while Apple Translation is still finishing.
- Apple Speech Analyzer Listen no longer asks to download a Voice Engine. An empty ASR Stop still prints leftover captions and types Listen and type. A second Listen during warmup does not wipe the board.

- First public Developer ID zip. In-app updates accept team `C6BH3WS28B`. Preview zips stay unsigned. Check for Updates stays off on an unsigned, ad-hoc, or Personal Team build.
- Listen and type Stop delivers this listen even when the shortcut release does not go through Theater Stop. The target app is captured before the overlay appears.
- An Apple Translation timeout remints the session so the next caption does not overlap a hung translate. Changing I speak waits until Listen has stopped, so the next Listen is not a no-op.
- Also hear others still translates I speak → Show as, but clause rules follow the script of a Korean, Japanese, or Thai question.
- Switching Overlay's caption bar to Pop-up opens a lower-third board instead of filling the display.
- Apple Translation now keeps one serve loop. Opening Theater or the pack sheet no longer starts a second host that can hang the first Translate.
- Listen and type uses the app you clicked when you started, even if fluidSubtitles is frontmost on Stop. If there is no other app, it says to click into one.
- Check for Updates on an unsigned or ad-hoc build says updates are not published yet, instead of You're Up To Date. A cold pack status waits instead of opening the download sheet.
- An unsigned preview zip can be downloaded from GitHub pre-releases without Xcode. macOS asks for Open Anyway the first time. `./build.sh preview` builds it and a `preview-<version>-<n>` tag publishes it; signed releases still need a Developer ID.
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

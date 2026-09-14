# Contributing to fluidSubtitles

This repo is Theater captions and dictation insert among **Korean, English, and Thai**. Speech recognition and the macOS app shell come from [FluidVoice](https://github.com/altic-dev/FluidVoice). Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues only through [SECURITY.md](SECURITY.md).

## Who this repo is for

| Change | File it here | File it upstream |
| --- | --- | --- |
| Theater window, Watch, captions, Apple Translation, latency HUD | Yes | No |
| Dictation insert of **this Listen** into another app | Yes | Only if the typing engine itself is wrong |
| Voice Engine picker limited to KO/EN/TH | Yes | No |
| ASR decode, microphone graph, Parakeet / Whisper / Nemotron internals | Ask first | Usually [FluidVoice](https://github.com/altic-dev/FluidVoice) |
| Command Mode, rewrite, file transcription, local HTTP API, PostHog | No — those were removed | FluidVoice if they still exist there |

Do not add product surfaces to files marked `Tracked grandfather`. Do not open a 2k-line refactor of `ContentView.swift`, `CustomDictionaryView.swift`, `MenuBarManager.swift`, or `ASRService+*.swift` without an accepted issue.

Ready starter tickets live in [.github/GOOD_FIRST_ISSUES.md](.github/GOOD_FIRST_ISSUES.md). Label them `good first issue` when you file them.

## First hour

You need an **Apple Silicon** Mac and **macOS 26** for Theater. Dictation still builds on macOS 15.

1. Copy signing config and set your 10-character Apple team ID (a free Personal Team is enough):

```bash
cp xcconfig/Local.xcconfig.example xcconfig/Local.xcconfig
# set DEVELOPMENT_TEAM
./build.sh
```

2. Launch `DerivedData/Build/Products/Debug/fluidSubtitles Debug.app`. Keep using that product so macOS can keep Accessibility / Screen Recording.

3. Open **Theater**. First run already selects **Apple Speech Analyzer** on macOS 26. Use **Parakeet Flash** only for faster English lectern (Show other models). Do not start with Nemotron Thai.

4. Lectern: allow the microphone, pick I speak / Show as, press **Listen**, speak one sentence. Watch: Screen Recording → quit and reopen → Capture **This Mac** → **Check capture** → play a non-DRM Korean, English, or Thai video → **Listen**. Download an Apple Translation pack only for a cross-language pair.

5. Format, lint, and test:

```bash
./scripts/format-and-lint.sh
xcodebuild test -project fluidSubtitles.xcodeproj -scheme fluidSubtitles \
  -destination 'platform=macOS,arch=arm64' \
  -skip-testing:FluidSubtitlesUITests
```

`FluidSubtitlesUITests` is the Theater smoke. It needs macOS UI automation and macOS 26. Local machines can skip it. Hosted CI uses Xcode 26 on a `macos-15` runner; it **cannot** prove Watch or a live Theater listen. Prove those on your Mac with [docs/WATCH_PROOF.md](docs/WATCH_PROOF.md) and [docs/STAGE_SCORE.md](docs/STAGE_SCORE.md).

Do not commit `xcconfig/Local.xcconfig` or a `DEVELOPMENT_TEAM` value in `project.pbxproj`. Optional hook:

```bash
cp scripts/check-team-id.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

Unsigned fallback for machines without a team: `./build.sh unsigned`.

Optional caption cleanup uses a local MLX runner. Install Python 3.12 (`brew install python@3.12`), then set `FLUID_PYTHON` if it is not on `PATH`.

## Where to edit

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing Theater or the speech engine.

| Area | Path | Role |
| --- | --- | --- |
| Live translation | `Sources/FluidSubtitles/Services/LiveTranslation/` | Clause split, Apple Translation, Theater archive, latency HUD, optional MLX |
| Theater UI | `Sources/FluidSubtitles/UI/LiveTranslation/` | Home, Theater window, presenter chrome |
| Speech engine | `ASRService.swift` plus `ASRService+*.swift` | Microphone / Watch audio → transcript. Keep this as the engine, not the product. |
| Dictation insert | `TypingService`, `GlobalHotkeyManager` | Types the current listen into the frontmost app |
| Overlay | `BottomOverlayView`, `NotchOverlayManager` | Dictation preview only |
| Settings | `SettingsStore.swift` plus `SettingsStore+*.swift` | Persist models, shortcuts, Theater options |
| App shell | `ContentView.swift` plus `ContentView+*.swift` | Window, dictation start, insert, onboarding |

New settings belong in a `SettingsStore+*.swift` file. New ContentView routing belongs in a `ContentView+*.swift` file. New Theater work stays under `LiveTranslation/`.

Watch defaults to **This Mac**. Safari includes every `com.apple.WebKit.*` process (Mail, Slack, and other WKWebView audio can ride along). Chrome helpers mix **every Chrome tab**, not one. That is why This Mac is the honest first path.

## Start with Discussions

Start a [GitHub Discussion](https://github.com/chrisswimlee/fluidSubtitles/discussions) first when you want to:

- Ask a support question.
- Propose a broad idea or feature.
- Explore a design direction.
- Report behavior that you are not sure is a fluidSubtitles bug.
- Ask whether a change would be accepted before writing code.

Feature ideas should begin in the Ideas category. Maintainers may turn an accepted discussion into a tracked issue.

## Issues

Issues are for work that maintainers can triage and act on.

Use a bug issue only when you can provide:

- A clear description of the bug.
- Exact reproduction steps.
- Expected behavior and actual behavior.
- fluidSubtitles version, macOS version, and architecture.
- Logs, crash reports, screenshots, or recordings when relevant.

Incomplete bug reports may be labeled `needs reproduction`. If the missing details are not provided after 14 days, the issue-intake workflow may close them.

Issues and PRs with no activity are marked stale after 30 days (issues) or 45 days (PRs) and closed 14 days later. Add `keep-open`, `pinned`, `security`, `good first issue`, or `help wanted` to skip that.

## Pull Requests

Pull requests should be tied to an accepted issue, Discussion, or roadmap item. Before opening a PR:

- Fill out every required section of the PR template.
- Select a type of change.
- Link the related issue or accepted Discussion.
- Describe how you tested the change.
- Attach screenshots or video for UI, UX, settings, onboarding, overlay, menu bar, or visual behavior changes.

If a PR has no UI or visual behavior changes, check the "No UI/visual changes" box. The PR Policy workflow still requires screenshots or video when changed files touch visual surfaces.

PRs that do not follow the template will be blocked by the `PR Policy` check. If required information is still missing after 7 days, the PR may be closed.

Add a `[Unreleased]` bullet to [CHANGELOG.md](CHANGELOG.md) for user-facing changes.

## Maintainer gates

These are not CI checks. The public project is not recommendable until they are done.

- Make `chrisswimlee/fluidSubtitles` **public**. In-app update checks, issue templates, and feedback links already point there.
- Enable Issues, Discussions (Ideas / Help / General), and Private Vulnerability Reporting.
- Require the build/test check and the `PR Policy` check on `main`.
- Create a GitHub Environment named `release` with required reviewers. The release workflow fails closed unless Developer ID and notarization secrets are present.
- Fill one [Watch proof note](docs/WATCH_PROOF.md) and one [stage score](docs/STAGE_SCORE.md) on a real Mac. Do not invent numbers.
- After the first Developer ID zip, add that team ID to `FluidProduct.allowedUpdateTeamIDs` (empty today, so in-app updates reject everyone) and publish a `v*` GitHub Release. See [docs/SIGNING.md](docs/SIGNING.md).

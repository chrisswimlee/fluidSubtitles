# Contributing to fluidSubtitles

Thanks for taking the time to improve fluidSubtitles. This app is a FluidVoice branch focused on live translation and Theater captions. The repository keeps GitHub Issues focused on actionable work, and uses Discussions for questions, ideas, and early design conversations.

When a change belongs in the upstream dictation engine rather than translation or captions, consider contributing to [FluidVoice](https://github.com/altic-dev/FluidVoice) as well.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately using [SECURITY.md](SECURITY.md).

## Start with Discussions

Start a [GitHub Discussion](https://github.com/chrisswimlee/fluidSubtitles/discussions) first when you want to:

- Ask a support question.
- Propose a broad idea or feature.
- Explore a design direction.
- Report behavior that you are not sure is a fluidSubtitles bug.
- Ask whether a change would be accepted before writing code.

Feature ideas should usually begin in the Ideas discussion category. Maintainers may turn an accepted or prioritized discussion into a tracked issue.

## Issues

Issues are for work that maintainers can triage and act on.

Use a bug issue only when you can provide:

- A clear description of the bug.
- Exact reproduction steps.
- Expected behavior and actual behavior.
- fluidSubtitles version, macOS version, and architecture.
- Logs, crash reports, screenshots, or recordings when relevant.

Feature issues show guidance to start with Discussions first, but this is advisory for now. Maintainers may still redirect broad or unclear feature ideas to Discussions during triage.

Incomplete bug reports may be labeled `needs reproduction`. If the missing reproduction details are not provided after 14 days, the issue-intake workflow may close them.

Issues and PRs with no activity are marked stale after 30 days (issues) or 45 days (PRs) and closed 14 days later. Add `keep-open`, `pinned`, `security`, `good first issue`, or `help wanted` to skip that.

## Pull Requests

Pull requests should be tied to an accepted issue, Discussion, or roadmap item. Before opening a PR:

- Fill out every required section of the PR template.
- Select a type of change.
- Link the related issue or accepted Discussion.
- Describe how you tested the change.
- Attach screenshots or video for UI, UX, settings, onboarding, overlay, menu bar, or visual behavior changes.

If a PR has no UI or visual behavior changes, check the "No UI/visual changes" box in the template. The PR Policy workflow still requires screenshots or video when changed files touch visual surfaces.

PRs that do not follow the template will be blocked by the `PR Policy` check. If required information is still missing after 7 days, the PR may be closed so maintainers can keep review queues focused.

Add a `[Unreleased]` bullet to [CHANGELOG.md](CHANGELOG.md) for user-facing changes. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing Theater or the speech engine. Report vulnerabilities only through [SECURITY.md](SECURITY.md).

Optional caption cleanup uses a local MLX runner. Install Python 3.12 (`brew install python@3.12` or any `python3.12` on `PATH`), then set `FLUID_PYTHON` if it is not on `PATH`.

## Local setup

```bash
cp xcconfig/Local.xcconfig.example xcconfig/Local.xcconfig
# set DEVELOPMENT_TEAM to your 10-character Apple team ID
./build.sh
```

Do not commit `xcconfig/Local.xcconfig` or a `DEVELOPMENT_TEAM` value in `project.pbxproj`. `scripts/check-team-id.sh` can be installed as a pre-commit hook:

```bash
cp scripts/check-team-id.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

Format and lint before you push:

```bash
./scripts/format-and-lint.sh
```

Run tests:

```bash
xcodebuild test -project fluidSubtitles.xcodeproj -scheme fluidSubtitles \
  -destination 'platform=macOS,arch=arm64' \
  -skip-testing:FluidSubtitlesUITests
```

`FluidSubtitlesUITests` is the Theater smoke. It needs macOS UI automation permission, so CI runs it with ad-hoc signing and local machines can skip it.

## Repository Settings

Maintainers should enable GitHub Discussions with these categories:

- Ideas
- Help
- General

Maintainers should require the existing build/test check and the `PR Policy` check before merging to `main`.

Create a GitHub Environment named `release` with required reviewers. The release workflow fails closed unless Developer ID and notarization secrets are present.

# Signing and notarization

Trust for a venue tech is Gatekeeper silence, not a longer onboarding screen.

## Ship

1. Put your 10-character Developer ID team in gitignored `xcconfig/Local.xcconfig`. Do not commit `DEVELOPMENT_TEAM` in the pbxproj.
2. After you have a published Developer ID, add that team ID to `FluidProduct.allowedUpdateTeamIDs` so GitHub updates accept it. Leave the set empty until that identity is known; empty and ad-hoc teams are rejected, so in-app updates do nothing until you fill it. Hosted CI cannot notarize without the `release` environment secrets.
3. Archive, notarize, staple. GitHub Release jobs already fail closed when credentials are missing.
4. `scripts/check-team-id.sh` must stay green.

Ad-hoc, `not set`, and empty team IDs are rejected by `UpdateSignaturePolicy`.

## First public Release

1. Make `chrisswimlee/fluidSubtitles` public so `SimpleUpdater` can see GitHub Releases. Run `scripts/enable-github-gates.sh` when `gh` is logged in as an owner.
2. Run `./build.sh release` with Developer ID and notarization credentials. That writes `dist/fluidsubtitles-{version}.zip` and `dist/SHA256SUMS`.
3. Put the published team ID in `FluidProduct.allowedUpdateTeamIDs`. Until that set is non-empty, every in-app update is rejected.
4. Tag `v*` and attach the zip plus `SHA256SUMS` (or let `.github/workflows/release.yml` do it once the `release` environment secrets exist).
5. Hosted CI still cannot prove a live Theater listen. Keep [STAGE_SCORE.md](STAGE_SCORE.md) next to the release notes. Watch is not a product gate.
6. Homebrew listing is a personal tap first, then an official cask PR. See [HOMEBREW.md](HOMEBREW.md).

## Library validation

`com.apple.security.cs.disable-library-validation` is still on because Whisper’s `CTranscribe.framework` can fail to load after Xcode flattens the XCFramework. Removing it without fixing that copy step breaks Whisper.

Theater’s default path (Apple Speech, Parakeet) does not need that exception. A Theater-only Release that drops Whisper can ship `fluidSubtitles.entitlements` without the key. Do not flip the key off while Whisper is linked.

## First run

Listen stays disabled until the Voice Engine matches I speak, the Apple Translation pack is installed (or the pair is same-language), and the microphone is not denied. Pressing Listen asks for the microphone when the grant is still undetermined. Type into app stays hidden until the first Theater caption.

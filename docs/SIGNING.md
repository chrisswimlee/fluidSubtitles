# Signing and notarization

Trust for a venue tech is Gatekeeper silence, not a longer onboarding screen.

Paying the Apple Developer Program fee is step zero. It does not mint a Developer ID by itself, and it does not put secrets on GitHub.

## After the $99

Apple may take hours to activate the membership. Then:

1. Xcode → Settings → Accounts → select the **paid** team (not the free Personal Team).
2. Manage Certificates → **+ → Developer ID Application**. The identity must be `Developer ID Application: <your name> (<your 10-character team>)`.
3. Run `./scripts/prepare-release-signing.sh`. It prints whether this Mac has **your** Developer ID, or only a Development cert / another team's Developer ID.
4. Put **your** team ID in gitignored `xcconfig/Local.xcconfig`. Do not commit it. Do not sign fluidSubtitles with someone else's Developer ID already in the keychain.
5. Export that Developer ID as a `.p12` from Keychain Access. Add these secrets on the GitHub `release` environment (not repo-wide if you can avoid it):

   | Secret | Value |
   |---|---|
   | `DEVELOPER_ID_P12_BASE64` | `base64 -i YourCert.p12` |
   | `DEVELOPER_ID_P12_PASSWORD` | The export password |
   | `FLUIDSUBTITLES_DEVELOPMENT_TEAM` | Your 10-character team ID |
   | `FLUIDSUBTITLES_CODESIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
   | `APPLE_ID` | The Apple Account email on the paid membership |
   | `APPLE_TEAM_ID` | Same 10-character team ID |
   | `APPLE_APP_SPECIFIC_PASSWORD` | appleid.apple.com → Sign-In and Security → App-Specific Passwords |

6. `./build.sh release` writes `dist/fluidsubtitles-{version}.zip` and notarizes when those Apple credentials are set.
7. Tag `v*` from `main` after the changelog section matches `CFBundleShortVersionString`. `FluidProduct.allowedUpdateTeamIDs` already includes `C6BH3WS28B`. The stapled app’s `TeamIdentifier` must be that team.

## Ship

1. Put your 10-character Developer ID team in gitignored `xcconfig/Local.xcconfig`. Do not commit `DEVELOPMENT_TEAM` in the pbxproj.
2. After you have a published Developer ID, add that team ID to `FluidProduct.allowedUpdateTeamIDs` so GitHub updates accept it. Hosted CI cannot notarize without the `release` environment secrets.
3. Archive, notarize, staple. GitHub Release jobs already fail closed when credentials are missing.
4. `scripts/check-team-id.sh` must stay green.

Ad-hoc, `not set`, and empty team IDs are rejected by `UpdateSignaturePolicy`.

## First public Release

1. Make `chrisswimlee/fluidSubtitles` public so `SimpleUpdater` can see GitHub Releases. Run `scripts/enable-github-gates.sh` when `gh` is logged in as an owner.
2. Run `./build.sh release` with Developer ID and notarization credentials. That writes `dist/fluidsubtitles-{version}.zip` and `dist/SHA256SUMS`.
3. Put the published team ID in `FluidProduct.allowedUpdateTeamIDs`. Check for Updates stays off unless this build’s TeamIdentifier is usable and in that set.
4. Tag `v*` and attach the zip plus `SHA256SUMS` (or let `.github/workflows/release.yml` do it once the `release` environment secrets exist).
5. Hosted CI still cannot prove a live Theater listen. Keep [STAGE_SCORE.md](STAGE_SCORE.md) next to the release notes. Watch is not a product gate.
6. Homebrew listing is a personal tap first, then an official cask PR. See [HOMEBREW.md](HOMEBREW.md).

## Library validation

`com.apple.security.cs.disable-library-validation` is still on because Whisper’s `CTranscribe.framework` can fail to load after Xcode flattens the XCFramework. Removing it without fixing that copy step breaks Whisper.

Theater’s default path (Apple Speech, Parakeet) does not need that exception. A Theater-only Release that drops Whisper can ship `fluidSubtitles.entitlements` without the key. Do not flip the key off while Whisper is linked.

## First run

Listen stays disabled until the Voice Engine matches I speak, the Apple Translation pack is installed (or the pair is same-language), and the microphone is not denied. Pressing Listen asks for the microphone when the grant is still undetermined. Type into app stays hidden until the first Theater caption.

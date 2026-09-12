# Signing and notarization

Trust for a venue tech is Gatekeeper silence, not a longer onboarding screen.

## Ship

1. Put your 10-character Developer ID team in gitignored `xcconfig/Local.xcconfig`. Do not commit `DEVELOPMENT_TEAM` in the pbxproj.
2. After you have a published Developer ID, add that team ID to `FluidProduct.allowedUpdateTeamIDs` so Sparkle/GitHub updates accept it.
3. Archive, notarize, staple. GitHub Release jobs already fail closed when credentials are missing.
4. `scripts/check-team-id.sh` must stay green.

Ad-hoc, `not set`, and empty team IDs are rejected by `UpdateSignaturePolicy`.

## Library validation

`com.apple.security.cs.disable-library-validation` is still on because Whisper’s `CTranscribe.framework` can fail to load after Xcode flattens the XCFramework. Removing it without fixing that copy step breaks Whisper.

Theater’s default path (Apple Speech, Parakeet) does not need that exception. A Theater-only Release that drops Whisper can ship `fluidSubtitles.entitlements` without the key. Do not flip the key off while Whisper is linked.

## First run

Listen stays disabled until the Voice Engine matches I speak, the Apple Translation pack is installed (or the pair is same-language), and the microphone is not denied. Type into app stays hidden until the first Theater caption.

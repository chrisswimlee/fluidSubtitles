# Security Policy

## Supported versions

Please report vulnerabilities against the current `main` branch of fluidSubtitles.

## Reporting a vulnerability

Do not open a public issue for a security report.

Email [chris.suyoung.lee@gmail.com](mailto:chris.suyoung.lee@gmail.com) with:

- A description of the issue and its impact
- Steps to reproduce, or a proof of concept if you have one
- The fluidSubtitles version, macOS version, and architecture

If the repository has GitHub Private Vulnerability Reporting enabled, you may also use **Security → Report a vulnerability**.

You should hear back within 7 days. Please give us a reasonable window to ship a fix before any public disclosure.

## Scope

In scope:

- Unauthorized access to transcripts, audio history, API keys, or Keychain items
- Update download or code-signature bypass
- Path traversal or unsafe model-file handling

Out of scope:

- Issues that require a compromised local user account
- Denial of service against your own Mac
- Missing features or product requests

## Notes for this build

The app is **unsandboxed**. Theater and dictation need the microphone. Insert-into-another-app needs Accessibility. Global hotkeys and user-downloaded voice / MLX weights also need to run outside the App Sandbox. Hardened Runtime stays on.

`com.apple.security.cs.disable-library-validation` is still set because Xcode’s XCFramework copy of `CTranscribe.framework` (TranscribeCpp / Whisper) can fail to load after its versioned layout is flattened. MLX and Python run in a separate process and are not the reason. A Theater-only build that drops Whisper can remove the key. See [docs/SIGNING.md](docs/SIGNING.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Automatic updates only install a zip that:

- matches `SHA256SUMS` on the GitHub Release
- contains a single top-level `fluidSubtitles.app`
- passes `codesign --verify --deep --strict`
- uses bundle id `com.fluidsubtitles.app`
- is signed with a usable Developer ID team, not ad-hoc or `not set`

GitHub Release jobs fail closed when Developer ID or notarization credentials are missing. This tree does not ship a local HTTP API or analytics. Live Theater does not send telemetry.

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
- Local API listeners that accept non-loopback clients
- Update download or code-signature bypass
- Path traversal or unsafe model-file handling

Out of scope:

- Issues that require a compromised local user account
- Denial of service against your own Mac
- Missing features or product requests

## Notes for this build

This release ships with an empty PostHog key and does not send analytics. Cloud AI providers only receive data after you add your own API key.

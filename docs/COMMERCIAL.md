# Commercial license

Personal, student, and evaluation use is free under GPLv3. Theater Listen stays unlocked.

If IT or legal need a vendor they can sanction — a named license, a security contact, or an SLA — request a commercial license.

**Request:** [chrisswimlee.com/fluidSubtitles/license](https://chrisswimlee.com/fluidSubtitles/license/) or email [suyoung.lee99@gmail.com](mailto:suyoung.lee99@gmail.com?subject=fluidSubtitles%20commercial%20license).

This is not consulting. Consulting is [Engage](https://chrisswimlee.com/engage/).

## What IT usually asks

**How does this monetize?** Named commercial licenses and optional support. Not transcripts, voiceprints, or model training.

**Does voice leave this Mac?** No, unless someone opts in to a cloud speech model. There is no analytics host. Live Theater does not send telemetry. See the README Privacy section.

**Who patches a break?** Security reports go to [SECURITY.md](../SECURITY.md) and get a reply within 7 days. A paid license can add a written SLA.

GPLv3 still lets a firm run the free zip. A commercial license does not forbid work use of that zip. It is the vendor paper and the signed key that shows **Licensed to** the organization in the app.

## What a paid license includes today

- A named organization license and an air-gapped activation key
- The same security mailbox, with an optional written SLA
- A **Licensed to {org}** line in Settings, Getting Started, Feedback, and Theater Home so procurement can see the Mac is covered

The key does not lock Talk notes, the dictionary, export, or Listen. It only replaces the work notice.

## Later (not in this tree)

These are not built yet. Do not promise a date.

- MDM `.pkg` for Jamf or Fleet
- Cryptographic zero-retention audit logs
- Fleet settings backup and restore
- Seat enforcement

## How a key works

The token is `base64url(json).base64url(ed25519)`.

JSON fields: `product` (`fluidSubtitles`), `org`, `seats`, `issued` (`YYYY-MM-DD`), `expires` (`YYYY-MM-DD`).

The app verifies the signature with the public key in `CommercialLicense.swift`. It does not phone home. Expired or tampered keys fail closed.

Paste the token in **Settings → General**. Remove it from the same row.

## Issue a key (maintainer)

The Ed25519 **private** key never belongs in git.

1. Put the raw 32-byte private key, standard Base64, in `FLUIDSUBTITLES_LICENSE_PRIVATE_KEY`, or in `~/.config/fluidsubtitles/commercial-license.ed25519` (mode `600`).
2. Confirm the matching public key is the one baked into `Sources/FluidSubtitles/Services/LiveTranslation/CommercialLicense.swift`. Rotating the key needs a new app release.
3. Issue:

```bash
./scripts/issue-commercial-license.sh --org "Example LLP" --seats 25 --expires 2027-09-21
```

`--issued` defaults to today (UTC). The script prints the token. Send that token to the buyer. Do not commit it.

Generate a new pair only when you intend to ship a new public key:

```bash
./scripts/issue-commercial-license.sh --generate-key
```

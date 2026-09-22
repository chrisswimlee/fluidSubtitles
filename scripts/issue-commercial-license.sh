#!/bin/bash
# Issue a fluidSubtitles commercial license token.
# The Ed25519 private key never belongs in git.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_KEY="${HOME}/.config/fluidsubtitles/commercial-license.ed25519"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/issue-commercial-license.sh --org "Example LLP" --seats 25 --expires 2027-09-21
  ./scripts/issue-commercial-license.sh --generate-key

Private key, standard Base64 of 32 raw bytes:
  FLUIDSUBTITLES_LICENSE_PRIVATE_KEY
  or ~/.config/fluidsubtitles/commercial-license.ed25519 (mode 600)

Optional: --issued YYYY-MM-DD (UTC, default today)
EOF
}

ORG=""
SEATS=""
EXPIRES=""
ISSUED=""
GENERATE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --org) ORG="${2:-}"; shift 2 ;;
        --seats) SEATS="${2:-}"; shift 2 ;;
        --expires) EXPIRES="${2:-}"; shift 2 ;;
        --issued) ISSUED="${2:-}"; shift 2 ;;
        --generate-key) GENERATE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

PRIVATE_KEY="${FLUIDSUBTITLES_LICENSE_PRIVATE_KEY:-}"
if [[ -z "${PRIVATE_KEY}" && -f "${DEFAULT_KEY}" ]]; then
    PRIVATE_KEY="$(tr -d '[:space:]' < "${DEFAULT_KEY}")"
fi

swift - "$ROOT" "$GENERATE" "$ORG" "$SEATS" "$EXPIRES" "$ISSUED" "$PRIVATE_KEY" "$DEFAULT_KEY" <<'SWIFT'
import CryptoKit
import Foundation

let args = CommandLine.arguments
let generate = args[2] == "1"
let org = args[3]
let seatsText = args[4]
let expires = args[5]
let issuedArg = args[6]
let privateKeyBase64 = args[7]
let defaultKeyPath = args[8]

func dayFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

if generate {
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: defaultKeyPath).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try key.rawRepresentation.base64EncodedString().write(toFile: defaultKeyPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: defaultKeyPath)
    FileHandle.standardError.write(Data("Wrote private key to \(defaultKeyPath)\n".utf8))
    FileHandle.standardError.write(Data("Public key (bake into CommercialLicense.swift):\n".utf8))
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}

guard !org.isEmpty, let seats = Int(seatsText), seats >= 1, !expires.isEmpty else {
    FileHandle.standardError.write(Data("Need --org, --seats (>= 1), and --expires YYYY-MM-DD.\n".utf8))
    exit(1)
}

let days = dayFormatter()
guard days.date(from: expires) != nil else {
    FileHandle.standardError.write(Data("expires must be YYYY-MM-DD.\n".utf8))
    exit(1)
}

let issued: String
if issuedArg.isEmpty {
    issued = days.string(from: Date())
} else {
    guard days.date(from: issuedArg) != nil else {
        FileHandle.standardError.write(Data("issued must be YYYY-MM-DD.\n".utf8))
        exit(1)
    }
    issued = issuedArg
}

guard let keyData = Data(base64Encoded: privateKeyBase64),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
else {
    FileHandle.standardError.write(Data("Set FLUIDSUBTITLES_LICENSE_PRIVATE_KEY or \(defaultKeyPath).\n".utf8))
    exit(1)
}

struct Wire: Encodable {
    var product: String
    var org: String
    var seats: Int
    var issued: String
    var expires: String
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let data = try encoder.encode(
    Wire(product: "fluidSubtitles", org: org, seats: seats, issued: issued, expires: expires)
)
let signature = try privateKey.signature(for: data)
print("\(base64URL(data)).\(base64URL(signature))")
SWIFT

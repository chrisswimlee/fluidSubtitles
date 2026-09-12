#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="${ROOT}/fluidSubtitles.xcodeproj/project.pbxproj"

if grep -E 'DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}' "${PBXPROJ}" | grep -vq 'DEVELOPMENT_TEAM = "";'; then
    echo "project.pbxproj must not contain a DEVELOPMENT_TEAM. Use xcconfig/Local.xcconfig." >&2
    exit 1
fi

if git -C "${ROOT}" ls-files --error-unmatch xcconfig/Local.xcconfig >/dev/null 2>&1; then
    echo "xcconfig/Local.xcconfig is tracked. Keep team IDs gitignored." >&2
    exit 1
fi

echo "Team ID check passed."

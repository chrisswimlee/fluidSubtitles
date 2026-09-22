#!/bin/bash
# Show whether this Mac can ship a Developer ID zip for fluidSubtitles.
# Does not export certificates or write secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${ROOT}/xcconfig/Local.xcconfig"

echo "fluidSubtitles release signing"
echo

configured=""
if [ -f "${CONFIG}" ]; then
    configured="$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); if ($2 != "" && $2 != "YOUR_TEAM_ID") print $2; exit}' "${CONFIG}" || true)"
fi

if [ -n "${configured}" ]; then
    echo "Local.xcconfig team: ${configured}"
else
    echo "Local.xcconfig team: (not set)"
    echo "Copy xcconfig/Local.xcconfig.example and set DEVELOPMENT_TEAM to your paid team."
fi
echo

echo "Code-signing identities:"
security find-identity -v -p codesigning 2>/dev/null | sed 's/^/  /'
echo

developer_ids="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' || true)"

if [ -z "${developer_ids}" ]; then
    echo "No Developer ID Application certificate on this Mac."
    echo "After Apple activates the paid membership:"
    echo "  Xcode → Settings → Accounts → your paid team → Manage Certificates"
    echo "  + → Developer ID Application"
    echo
    echo "A free Personal Team and an Apple Development cert cannot notarize."
    exit 1
fi

echo "Developer ID Application identities:"
while IFS= read -r identity; do
    [ -n "${identity}" ] || continue
    team="$(printf '%s\n' "${identity}" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"
    echo "  ${identity}"
    if [ -n "${configured}" ] && [ "${team}" = "${configured}" ]; then
        echo "  → matches Local.xcconfig. This is the identity ./build.sh release should use."
    elif [ -n "${configured}" ] && [ -n "${team}" ]; then
        echo "  → team ${team} does not match Local.xcconfig ${configured}."
        echo "    Do not sign fluidSubtitles with another team's Developer ID."
    fi
done <<< "${developer_ids}"
echo

if [ -n "${configured}" ] && printf '%s\n' "${developer_ids}" | grep -q "(${configured})"; then
    echo "Next: export that Developer ID as a .p12 and add the GitHub release environment secrets."
    echo "See docs/SIGNING.md."
    exit 0
fi

echo "This Mac has a Developer ID, but not one for the Local.xcconfig team."
echo "Create Developer ID Application on your paid team, then rerun this script."
exit 1

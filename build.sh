#!/bin/bash

# fluidSubtitles build router
#
# Usage:
#   ./build.sh            # signed Debug build
#   ./build.sh public     # signed Debug build
#   ./build.sh unsigned   # unsigned Debug build (CI / no signing identity)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${1:-${BUILD_PROFILE:-public}}"
DERIVED_DATA_PATH="${FLUIDSUBTITLES_DERIVED_DATA_PATH:-${FLUIDVOICE_DERIVED_DATA_PATH:-${PROJECT_DIR}/DerivedData}}"

resolve_development_team() {
    if [ -n "${FLUIDSUBTITLES_DEVELOPMENT_TEAM:-${FLUIDVOICE_DEVELOPMENT_TEAM:-}}" ]; then
        printf '%s\n' "${FLUIDSUBTITLES_DEVELOPMENT_TEAM:-${FLUIDVOICE_DEVELOPMENT_TEAM}}"
        return
    fi

    local from_xcconfig
    from_xcconfig="$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); if ($2 != "" && $2 != "YOUR_TEAM_ID") print $2; exit}' \
        "${PROJECT_DIR}/xcconfig/Local.xcconfig" 2>/dev/null || true)"
    if [ -n "${from_xcconfig}" ]; then
        printf '%s\n' "${from_xcconfig}"
        return
    fi

    local identity
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | awk 'NR == 1 { identity = $0 } END { print identity }')"
    [ -n "${identity}" ] || return 0

    security find-certificate -c "${identity}" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -n 's/.*OU=\([^,]*\).*/\1/p'
}

run_public_build() {
    local signing_mode="$1"
    local development_team
    local -a build_args=(
        -project fluidSubtitles.xcodeproj
        -scheme fluidSubtitles
        -configuration Debug
        -destination 'platform=macOS'
        -derivedDataPath "${DERIVED_DATA_PATH}"
        build
    )

    cd "${PROJECT_DIR}"

    if [ "${signing_mode}" = "unsigned" ]; then
        echo "Running unsigned fluidSubtitles build..."
        echo "Accessibility permission may need to be granted again after rebuilding."
        exec xcodebuild "${build_args[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
    fi

    development_team="$(resolve_development_team)"
    if [ -z "${development_team}" ]; then
        cat >&2 <<'EOF'
No Apple Development signing identity was found.

For stable Accessibility permission across rebuilds, add any Apple Account in:
  Xcode > Settings > Accounts

Then open Manage Certificates and create an Apple Development certificate.

A free Personal Team is sufficient. Copy xcconfig/Local.xcconfig.example to
xcconfig/Local.xcconfig and set DEVELOPMENT_TEAM, or export
FLUIDSUBTITLES_DEVELOPMENT_TEAM.

To build without signing instead, run:
  ./build.sh unsigned
EOF
        exit 1
    fi

    echo "Running signed fluidSubtitles build..."
    echo "Build product: ${DERIVED_DATA_PATH}/Build/Products/Debug/fluidSubtitles Debug.app"
    exec xcodebuild "${build_args[@]}" DEVELOPMENT_TEAM="${development_team}"
}

case "${PROFILE}" in
    public|oss|incremental|fast|"")
        run_public_build signed
        ;;
    unsigned|ci)
        run_public_build unsigned
        ;;
    *)
        echo "Unknown build profile: ${PROFILE}"
        echo "Valid profiles: public, unsigned"
        exit 1
        ;;
esac

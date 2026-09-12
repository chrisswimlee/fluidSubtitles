#!/bin/bash

# fluidSubtitles build router
#
# Usage:
#   ./build.sh            # signed Debug build
#   ./build.sh public     # signed Debug build
#   ./build.sh unsigned   # unsigned Debug build (CI / no signing identity)
#   ./build.sh release    # signed Release zip; notarize when Apple credentials are set

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

app_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_DIR}/Info.plist"
}

restore_ctranscribe_layout() {
    local framework="$1/Contents/Frameworks/CTranscribe.framework"
    if [ ! -d "${framework}/Versions/A" ]; then
        echo "CTranscribe.framework is missing from the Release app." >&2
        exit 1
    fi
    rm -rf \
        "${framework}/Versions/Current" \
        "${framework}/CTranscribe" \
        "${framework}/Resources" \
        "${framework}/Versions/A/_CodeSignature"
    ln -s A "${framework}/Versions/Current"
    ln -s Versions/Current/CTranscribe "${framework}/CTranscribe"
    ln -s Versions/Current/Resources "${framework}/Resources"
}

run_release_build() {
    local development_team
    local version
    local app_path
    local zip_name
    local zip_path
    local identity="${FLUIDSUBTITLES_CODESIGN_IDENTITY:-Developer ID Application}"
    local -a build_args=(
        -project fluidSubtitles.xcodeproj
        -scheme fluidSubtitles
        -configuration Release
        -destination 'platform=macOS'
        -derivedDataPath "${DERIVED_DATA_PATH}"
        build
    )

    cd "${PROJECT_DIR}"
    development_team="$(resolve_development_team)"
    if [ -z "${development_team}" ]; then
        echo "A DEVELOPMENT_TEAM is required for ./build.sh release." >&2
        exit 1
    fi

    echo "Running signed Release fluidSubtitles build..."
    xcodebuild "${build_args[@]}" \
        DEVELOPMENT_TEAM="${development_team}" \
        CODE_SIGN_IDENTITY="${identity}"

    app_path="${DERIVED_DATA_PATH}/Build/Products/Release/fluidSubtitles.app"
    if [ ! -d "${app_path}" ]; then
        app_path="$(find "${DERIVED_DATA_PATH}/Build/Products/Release" -maxdepth 1 -name '*.app' | head -n 1)"
    fi
    if [ -z "${app_path}" ] || [ ! -d "${app_path}" ]; then
        echo "Release app was not found in ${DERIVED_DATA_PATH}/Build/Products/Release." >&2
        exit 1
    fi

    restore_ctranscribe_layout "${app_path}"
    codesign --force --sign "${identity}" --timestamp --options runtime \
        "${app_path}/Contents/Frameworks/CTranscribe.framework"
    codesign --force --sign "${identity}" --timestamp --options runtime \
        --entitlements "${PROJECT_DIR}/fluidSubtitles.entitlements" \
        "${app_path}"
    codesign --verify --deep --strict "${app_path}"

    version="$(app_version)"
    zip_name="fluidsubtitles-${version}.zip"
    zip_path="${PROJECT_DIR}/dist/${zip_name}"
    mkdir -p "${PROJECT_DIR}/dist"

    if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
        echo "Notarizing ${app_path}..."
        ditto -c -k --keepParent "${app_path}" "${zip_path}"
        xcrun notarytool submit "${zip_path}" \
            --apple-id "${APPLE_ID}" \
            --team-id "${APPLE_TEAM_ID}" \
            --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
            --wait
        xcrun stapler staple "${app_path}"
    else
        if [ "${REQUIRE_NOTARIZATION:-}" = "1" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
            echo "APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD are required. Refusing to publish an unsigned zip." >&2
            exit 1
        fi
        echo "Skipping notarization. Set APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD to notarize."
    fi

    rm -f "${zip_path}"
    ditto -c -k --keepParent "${app_path}" "${zip_path}"
    echo "Release zip: ${zip_path}"
}

case "${PROFILE}" in
    public|oss|incremental|fast|"")
        run_public_build signed
        ;;
    unsigned|ci)
        run_public_build unsigned
        ;;
    release|notarize)
        run_release_build
        ;;
    *)
        echo "Unknown build profile: ${PROFILE}"
        echo "Valid profiles: public, unsigned, release"
        exit 1
        ;;
esac

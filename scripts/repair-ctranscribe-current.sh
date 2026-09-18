#!/bin/bash
# Xcode flattens CTranscribe.framework so Versions/Current is a directory.
# AppKit then fails with "Couldn't resolve framework symlink".
set -euo pipefail

repair_current() {
    local current="$1"
    local versions
    versions="$(dirname "${current}")"
    if [ ! -d "${versions}/A" ]; then
        return 0
    fi
    if [ -L "${current}" ]; then
        return 0
    fi
    rm -rf "${current}"
    ln -s A "${current}"
    echo "Repaired CTranscribe Versions/Current -> A (${versions})"
}

scan_root() {
    local root="$1"
    [ -d "${root}" ] || return 0
    find "${root}" -path '*/CTranscribe.framework/Versions/Current' -print 2>/dev/null \
        | while IFS= read -r current; do
            repair_current "${current}"
        done
}

if [ -n "${BUILD_DIR:-}" ]; then
    derived="${BUILD_DIR}"
    while [ -n "${derived}" ]; do
        if [ -d "${derived}/SourcePackages" ]; then
            scan_root "${derived}/SourcePackages"
            break
        fi
        parent="$(dirname "${derived}")"
        [ "${parent}" = "${derived}" ] && break
        derived="${parent}"
    done
fi

scan_root "${HOME}/Library/Developer/Xcode/DerivedData"
if [ -n "${SRCROOT:-}" ]; then
    scan_root "${SRCROOT}/DerivedData"
fi

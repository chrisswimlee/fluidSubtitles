#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if command -v swiftformat >/dev/null 2>&1; then
    swiftformat Sources Tests
else
    echo "swiftformat is not installed; skipping format."
fi

if command -v swiftlint >/dev/null 2>&1; then
    swiftlint lint --config .swiftlint.yml --strict
else
    echo "swiftlint is not installed; skipping lint."
fi

#!/bin/bash
# Pre-commit hook: refuse committed Apple team IDs in the Xcode project.
# Install: cp scripts/check-team-id.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

set -euo pipefail

PROJECT_FILE="fluidSubtitles.xcodeproj/project.pbxproj"

if ! git diff --cached --name-only | grep -q "$PROJECT_FILE"; then
  exit 0
fi

if git diff --cached "$PROJECT_FILE" | grep -E '^\+[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}'; then
  echo "ERROR: Do not commit DEVELOPMENT_TEAM in project.pbxproj."
  echo "Put your team ID in xcconfig/Local.xcconfig (gitignored) or pass"
  echo "FLUIDSUBTITLES_DEVELOPMENT_TEAM to ./build.sh."
  exit 1
fi

exit 0

import assert from "node:assert/strict";
import test from "node:test";

import { isDocsOrTestOnly, validatePullRequest } from "./github-policy.mjs";

const readyBody = `
## Description
Document first-hour Theater Listen without Watch.

## Type of Change
- [x] Documentation update

## Related Issue or Discussion
Closes #12

## Changelog
- [x] Added a \`[Unreleased]\` bullet in \`CHANGELOG.md\` for user-facing changes, or this change is internal-only.

## Testing
- [x] Ran tests locally:

## Screenshots / Video
Attach screenshots or a video for UI, UX, settings, onboarding, overlay, menu bar, or visual behavior changes.
`;

test("docs and test-only paths skip Theater screenshots", () => {
  assert.equal(
    isDocsOrTestOnly(["docs/STAGE_SCORE.md", "README.md", "Tests/FluidSubtitlesIntegrationTests/LiveTranslationClauseTests.swift"]),
    true,
  );
  assert.equal(
    isDocsOrTestOnly(["Sources/FluidSubtitles/UI/LiveTranslation/PresenterCaptionWindow.swift"]),
    false,
  );
});

test("docs-only PR is not blocked on screenshots", () => {
  const result = validatePullRequest({
    body: readyBody,
    changedFiles: ["docs/STAGE_SCORE.md", "CHANGELOG.md", "README.md"],
  });
  assert.equal(result.ok, true);
  assert.equal(result.requiresMedia, false);
});

test("Theater UI PR still needs screenshots or the no-visual checkbox", () => {
  const result = validatePullRequest({
    body: readyBody,
    changedFiles: ["Sources/FluidSubtitles/UI/LiveTranslation/PresenterCaptionWindow.swift"],
  });
  assert.equal(result.ok, false);
  assert.ok(result.missing.includes("Screenshots / Video"));
});

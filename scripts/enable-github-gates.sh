#!/bin/bash
# Apply the maintainer GitHub gates from CONTRIBUTING.md.
# Needs `gh` authenticated as an owner of chrisswimlee/fluidSubtitles.
set -euo pipefail

OWNER="${GITHUB_REPOSITORY_OWNER:-chrisswimlee}"
REPO="${GITHUB_REPOSITORY_NAME:-fluidSubtitles}"
FULL="${OWNER}/${REPO}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v gh >/dev/null 2>&1; then
    echo "gh is required. Install GitHub CLI and run gh auth login." >&2
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "gh is not logged in. Run gh auth login, then rerun this script." >&2
    exit 1
fi

echo "Enabling public repo, Issues, Discussions, and Private Vulnerability Reporting on ${FULL}..."
gh repo edit "${FULL}" \
    --visibility public \
    --accept-visibility-change-consequences \
    --enable-issues \
    --enable-discussions \
    --description "Live Korean, English, Thai, and Japanese captions for macOS."

gh api --method PUT "repos/${FULL}/private-vulnerability-reporting" >/dev/null
gh api --method PUT "repos/${FULL}/vulnerability-alerts" >/dev/null || true
gh api --method PUT "repos/${FULL}/automated-security-fixes" >/dev/null || true
gh api --method PATCH "repos/${FULL}" --input - >/dev/null <<'EOF' || true
{
  "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" }
  }
}
EOF

echo "Discussion categories should include Ideas, Q&A, and General (GitHub defaults)."
gh api graphql -f query='query { repository(owner:"chrisswimlee", name:"fluidSubtitles") { discussionCategories(first:20) { nodes { name } } } }' --jq '.data.repository.discussionCategories.nodes[].name'

echo "Creating Environment release with the current user as a reviewer..."
USER_ID="$(gh api user --jq .id)"
gh api --method PUT "repos/${FULL}/environments/release" \
    -f wait_timer=0 \
    -F prevent_self_review=false \
    --input - >/dev/null <<EOF
{
  "reviewers": [{"type": "User", "id": ${USER_ID}}]
}
EOF

echo "Requiring Build and Test + PR Policy on main..."
gh api --method PUT "repos/${FULL}/branches/main/protection" \
    --input - >/dev/null <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Build and Test", "PR Policy"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF

echo "Ensuring labels and filing good first issues from .github/GOOD_FIRST_ISSUES.md..."
gh label create "good first issue" --repo "${FULL}" --color "7057ff" --description "Ready for a first PR" --force >/dev/null
gh label create "help wanted" --repo "${FULL}" --color "008672" --description "Maintainer would review this" --force >/dev/null
gh label create "documentation" --repo "${FULL}" --color "0075ca" --description "Docs and first-hour copy" --force >/dev/null
gh label create "enhancement" --repo "${FULL}" --color "a2eeef" --description "Product improvement" --force >/dev/null

ROOT="${ROOT}" FULL="${FULL}" python3 - <<'PY'
import json
import os
import re
import subprocess
from pathlib import Path

root = Path(os.environ["ROOT"])
full = os.environ["FULL"]
text = (root / ".github/GOOD_FIRST_ISSUES.md").read_text(encoding="utf-8")
blocks = re.split(r"^## ", text, flags=re.MULTILINE)[1:]
existing = subprocess.check_output(
    ["gh", "issue", "list", "--repo", full, "--limit", "100", "--json", "title"],
    text=True,
)
titles = {item["title"] for item in json.loads(existing)}
for block in blocks:
    title, _, body = block.partition("\n")
    title = title.strip()
    if not title or title.startswith("Good first"):
        continue
    if title in titles:
        print(f"  issue already open: {title}")
        continue
    labels = ["good first issue", "help wanted"]
    label_line = re.search(r"\*\*Labels:\*\*\s*(.+)", body)
    if label_line:
        labels = [part.strip().strip("`") for part in label_line.group(1).split(",") if part.strip()]
    cmd = ["gh", "issue", "create", "--repo", full, "--title", title, "--body", body.strip()]
    for label in labels:
        cmd.extend(["--label", label])
    subprocess.check_call(cmd)
    print(f"  filed: {title}")
PY

echo "GitHub gates applied on ${FULL}."
echo "Confirm Issues, Discussions, Private Vulnerability Reporting, and the release environment in the GitHub UI."

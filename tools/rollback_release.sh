#!/usr/bin/env bash
# Only undo the exact unpublished bump produced by this run. Never delete tags.
set -euo pipefail
: "${CANDIDATE:?Missing candidate commit}"
: "${VERSION:?Missing release version}"
[[ "$CANDIDATE" =~ ^[0-9a-f]{40}$ ]] || exit 1
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
EXISTING_TAG=$(git ls-remote origin "refs/tags/v$VERSION")
if [[ -n "$EXISTING_TAG" ]]; then
  echo "::warning::Tag v$VERSION exists. Publication may have started; preserving commit and tag for manual inspection."
  exit 0
fi
git fetch origin master
if [[ "$(git rev-parse origin/master)" != "$CANDIDATE" ]]; then
  echo "::warning::Master changed after the bump. Leaving other work untouched; manual recovery required."
  exit 0
fi
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git revert --no-edit "$CANDIDATE"
# Normal fast-forward push fails safely if someone updates master concurrently.
git push origin HEAD:master
echo "Unpublished bump reverted. Existing tags were not changed."

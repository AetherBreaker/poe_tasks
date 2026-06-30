#!/usr/bin/env bash
# release.sh — Bump version, commit, tag, build, and publish to GitHub and SFTPyPI.
# Usage: bash scripts/release.sh <major|minor|patch>
# Typically invoked via: poe release <major|minor|patch>
#
# On any error, all steps that were completed are rolled back:
#   - GitHub release deleted
#   - Package removed from SFTPyPI
#   - Remote tag deleted
#   - Local tag deleted
#   - Version-bump commit reset
#   - pyproject.toml and uv.lock restored
#   - Remote branch force-pushed back to the pre-bump state

set -euo pipefail

bump_type="${1:?Usage: release.sh <major|minor|patch>}"
notes_text="${2:-}"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
VERSION_BUMPED=false
COMMITTED=false
TAGGED=false
PUSHED=false
PUBLISHED_PYPI=false
RELEASED_GITHUB=false
NEW_VERSION=""
SNAPSHOT_DIR=""
PYPROJECT_SNAPSHOT=""
UVLOCK_SNAPSHOT=""
UVLOCK_WAS_PRESENT=false
DIST_SNAPSHOT_DIR=""

cleanup() {
  local exit_code=$?
  set +eu

  if [ $exit_code -eq 0 ]; then
    if [ -n "${SNAPSHOT_DIR:-}" ] && [ -d "${SNAPSHOT_DIR}" ]; then
      rm -rf "${SNAPSHOT_DIR}" 2>/dev/null || true
    fi
    return 0
  fi

  echo ""
  echo "ERROR: Release failed (exit code: ${exit_code}). Rolling back changes..."

  # 1. Delete GitHub release (--cleanup-tag also removes the remote tag)
  if $RELEASED_GITHUB; then
    echo "  -> Deleting GitHub release v${NEW_VERSION} (and its remote tag)..."
    gh release delete "v${NEW_VERSION}" --yes --cleanup-tag 2>/dev/null ||
      echo "     WARNING: Could not delete GitHub release. Run manually: gh release delete v${NEW_VERSION} --yes --cleanup-tag"
  fi

  # 2. Remove package from SFTPyPI via devpi REST API
  if $PUBLISHED_PYPI; then
    echo "  -> Removing ${PACKAGE_NAME}==${NEW_VERSION} from SFTPyPI..."
    curl -s -o /dev/null \
      -u "${UV_INDEX_SFTPYPI_USERNAME}:${UV_INDEX_SFTPYPI_PASSWORD}" \
      -X DELETE "https://pypi.sweetfiretobacco.com/jacob.ogden/internal/${PACKAGE_NAME}/${NEW_VERSION}" ||
      echo "     WARNING: Could not remove from SFTPyPI. Manual cleanup needed."
  fi

  # 3. Delete remote tag (only if push succeeded but GitHub release cleanup did not run)
  if $PUSHED && ! $RELEASED_GITHUB; then
    echo "  -> Deleting remote tag v${NEW_VERSION}..."
    git push origin --delete "v${NEW_VERSION}" 2>/dev/null ||
      echo "     WARNING: Could not delete remote tag v${NEW_VERSION}."
  fi

  # 4. Delete local tag
  if $TAGGED; then
    git tag -d "v${NEW_VERSION}" 2>/dev/null || true
  fi

  # 5. Reset local version bump commit (mixed: keeps working tree, restores index)
  if $COMMITTED; then
    echo "  -> Resetting local version bump commit..."
    git reset HEAD~1 ||
      echo "     WARNING: Could not reset local commit. Run manually: git reset HEAD~1"
  fi

  # 6. Restore pyproject.toml and uv.lock to their exact pre-run contents.
  if [ -n "${PYPROJECT_SNAPSHOT:-}" ] && [ -f "${PYPROJECT_SNAPSHOT}" ]; then
    cp "${PYPROJECT_SNAPSHOT}" pyproject.toml 2>/dev/null || true
  fi
  if $UVLOCK_WAS_PRESENT; then
    if [ -n "${UVLOCK_SNAPSHOT:-}" ] && [ -f "${UVLOCK_SNAPSHOT}" ]; then
      cp "${UVLOCK_SNAPSHOT}" uv.lock 2>/dev/null || true
    fi
  else
    rm -f uv.lock 2>/dev/null || true
  fi

  # 7. Force-push the rolled-back state to remote (local HEAD is now the pre-bump commit)
  if $PUSHED; then
    echo "  -> Force-pushing rollback to remote ${CURRENT_BRANCH}..."
    git push --force origin "${CURRENT_BRANCH}" 2>/dev/null ||
      echo "     WARNING: Could not force-push rollback. Run manually: git push --force origin ${CURRENT_BRANCH}"
  fi

  rm -f dist/*.whl dist/*.tar.gz 2>/dev/null || true
  if [ -n "${DIST_SNAPSHOT_DIR:-}" ] && [ -d "${DIST_SNAPSHOT_DIR}" ]; then
    cp "${DIST_SNAPSHOT_DIR}"/* dist/ 2>/dev/null || true
  fi
  if [ -n "${SNAPSHOT_DIR:-}" ] && [ -d "${SNAPSHOT_DIR}" ]; then
    rm -rf "${SNAPSHOT_DIR}" 2>/dev/null || true
  fi
  echo ""
  echo "Rollback complete."
}

trap cleanup EXIT

SNAPSHOT_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t release-snapshot)
PYPROJECT_SNAPSHOT="${SNAPSHOT_DIR}/pyproject.toml"
UVLOCK_SNAPSHOT="${SNAPSHOT_DIR}/uv.lock"
DIST_SNAPSHOT_DIR="${SNAPSHOT_DIR}/dist"
cp pyproject.toml "${PYPROJECT_SNAPSHOT}"
if [ -f uv.lock ]; then
  UVLOCK_WAS_PRESENT=true
  cp uv.lock "${UVLOCK_SNAPSHOT}"
fi
mkdir -p "${DIST_SNAPSHOT_DIR}" dist
for artifact in dist/*.whl dist/*.tar.gz; do
  [ -f "${artifact}" ] || continue
  cp "${artifact}" "${DIST_SNAPSHOT_DIR}/"
done

UV_VERSION_OUTPUT=$(uv version --bump "${bump_type}")
PACKAGE_NAME=$(echo "${UV_VERSION_OUTPUT}" | awk '{print $1}' | tr '_' '-')
NEW_VERSION=$(echo "${UV_VERSION_OUTPUT}" | awk '{print $NF}')
VERSION_BUMPED=true
uv sync
git add pyproject.toml uv.lock
git commit -m "Bump version to ${NEW_VERSION}"
COMMITTED=true
git tag -a "v${NEW_VERSION}" -m "Version ${NEW_VERSION}"
TAGGED=true
git push --follow-tags
PUSHED=true
rm -f dist/*.whl dist/*.tar.gz
uv build
# Remove any pre-existing version from the index before publishing to avoid
# checksum-mismatch errors when re-releasing the same version number.
echo "Checking SFTPyPI for a pre-existing v${NEW_VERSION}..."
pre_delete_status=$(
  curl -s -o /dev/null -w "%{http_code}" \
    -u "${UV_INDEX_SFTPYPI_USERNAME}:${UV_INDEX_SFTPYPI_PASSWORD}" \
    -X DELETE "https://pypi.sweetfiretobacco.com/jacob.ogden/internal/${PACKAGE_NAME}/${NEW_VERSION}"
)
case "$pre_delete_status" in
200 | 204) echo "  -> Removed pre-existing v${NEW_VERSION} from SFTPyPI index." ;;
404) echo "  -> No pre-existing v${NEW_VERSION} found on SFTPyPI index." ;;
*) echo "  -> WARNING: Unexpected status ${pre_delete_status} when checking SFTPyPI for pre-existing version." ;;
esac
# Publish to devpi (SFTPyPI). Pass credentials explicitly — devpi does not
# support OIDC/trusted publishing, so uv must receive them via CLI flags.
uv publish --index SFTPyPI \
  --username "${UV_INDEX_SFTPYPI_USERNAME}" \
  --password "${UV_INDEX_SFTPYPI_PASSWORD}"
PUBLISHED_PYPI=true
if [ -n "${notes_text}" ]; then
  gh release create "v${NEW_VERSION}" dist/* --title "v${NEW_VERSION}" --notes "${notes_text}"
else
  gh release create "v${NEW_VERSION}" dist/* --title "v${NEW_VERSION}" --generate-notes
fi
RELEASED_GITHUB=true

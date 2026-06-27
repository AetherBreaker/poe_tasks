#!/usr/bin/env bash
# rescind-release.sh — Remove a release from SFTPyPI, GitHub, and all Git refs.
# Usage: bash scripts/rescind-release.sh [version]
#   version   Optional version to rescind (e.g. "1.2.3" or "v1.2.3").
#             Defaults to the most recent release. When defaulting, the local
#             branch is also rewound to the previous release tag commit, with
#             all changes from the release kept in the working tree.
#
# Required env vars (loaded from .env by the poe task):
#   UV_INDEX_SFTPYPI_USERNAME
#   UV_INDEX_SFTPYPI_PASSWORD

set -euo pipefail

TARGET_VERSION="${1:-}"
TARGET_VERSION="${TARGET_VERSION#v}"   # strip leading 'v' if present
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# ── Read package name from pyproject.toml ────────────────────────────────────
PACKAGE_NAME=$(uv run python -c "
import tomllib, sys
with open('pyproject.toml', 'rb') as fh:
    name = tomllib.load(fh).get('project', {}).get('name', '')
if not name:
    sys.exit('ERROR: Could not read project.name from pyproject.toml')
print(name)
")

# ── Determine target tag ──────────────────────────────────────────────────────
IS_MOST_RECENT=false
if [ -z "$TARGET_VERSION" ]; then
    IS_MOST_RECENT=true
    LATEST_TAG=$(git tag --list 'v*' --sort=-version:refname | head -1)
    if [ -z "$LATEST_TAG" ]; then
        echo "ERROR: No release tags found in this repository."
        exit 1
    fi
    TARGET_VERSION="${LATEST_TAG#v}"
fi

TAG="v${TARGET_VERSION}"

# Ensure tag is available locally (fetch from remote if needed)
if ! git tag --list "$TAG" | grep -q .; then
    echo "Tag '$TAG' not found locally; fetching tags from remote..."
    git fetch --tags --quiet
    if ! git tag --list "$TAG" | grep -q .; then
        echo "ERROR: Tag '$TAG' not found locally or on remote."
        exit 1
    fi
fi

echo "Rescinding release '$TAG' for package '$PACKAGE_NAME'..."
echo ""

# ── Capture state before any deletions ───────────────────────────────────────
# Use ^{} to dereference annotated tag objects to the underlying commit SHA.
# Use ^{} to dereference annotated tags to their underlying commit SHA.
TAGGED_COMMIT=$(git rev-parse "${TAG}^{}")
PREV_TAG=""
PREV_COMMIT=""
if $IS_MOST_RECENT; then
    # Tags in descending-version order: [0]=current, [1]=previous
    PREV_TAG=$(git tag --list 'v*' --sort=-version:refname | sed -n '2p')
    if [ -n "$PREV_TAG" ]; then
        PREV_COMMIT=$(git rev-parse "${PREV_TAG}^{}")
    fi
fi

# ── 1. GitHub release ─────────────────────────────────────────────────────────
echo "  [1/3] GitHub release..."
if gh release view "$TAG" &>/dev/null; then
    # --cleanup-tag also removes the associated remote tag
    gh release delete "$TAG" --yes --cleanup-tag
    echo "        Deleted GitHub release and remote tag '$TAG'."
else
    echo "        No GitHub release found for '$TAG'; removing remote tag directly..."
    if git ls-remote --tags origin "refs/tags/$TAG" | grep -q .; then
        git push origin --delete "$TAG"
        echo "        Deleted remote tag '$TAG'."
    else
        echo "        Remote tag '$TAG' not found (already removed)."
    fi
fi

# ── 2. SFTPyPI package index ──────────────────────────────────────────────────
echo "  [2/3] SFTPyPI package index..."
http_status=$(
    curl -s -o /dev/null -w "%{http_code}" \
        -u "${UV_INDEX_SFTPYPI_USERNAME}:${UV_INDEX_SFTPYPI_PASSWORD}" \
        -X DELETE "https://pypi.sweetfiretobacco.com/jacob.ogden/internal/${PACKAGE_NAME}/${TARGET_VERSION}"
)
case "$http_status" in
    200|204) echo "        Removed ${PACKAGE_NAME}==${TARGET_VERSION} from SFTPyPI." ;;
    404)     echo "        ${PACKAGE_NAME}==${TARGET_VERSION} not found on SFTPyPI (already removed)." ;;
    *)       echo "        WARNING: Unexpected HTTP ${http_status} from SFTPyPI. Manual cleanup may be needed." ;;
esac

# ── 3. Local tag ──────────────────────────────────────────────────────────────
echo "  [3/3] Local git tag..."
if git tag --list "$TAG" | grep -q .; then
    git tag -d "$TAG"
    echo "        Deleted local tag '$TAG'."
else
    echo "        Local tag '$TAG' already removed."
fi

# ── 4. Rewind commits (most-recent only) ──────────────────────────────────────
if $IS_MOST_RECENT; then
    echo ""
    if [ -z "$PREV_COMMIT" ]; then
        echo "  No previous release tag found — skipping commit rewind."
    else
        # Count commits that landed after the tagged release commit
        COMMITS_AFTER=$(git rev-list "${TAGGED_COMMIT}..HEAD" --count 2>/dev/null || echo "0")
        if [ "$COMMITS_AFTER" -gt 0 ]; then
            TAGGED_SHORT=$(git rev-parse --short "$TAGGED_COMMIT")
            echo "  NOTE: $COMMITS_AFTER commit(s) exist after '$TAG' on this branch."
            echo "  Skipping automatic rewind to avoid clobbering post-release work."
            echo "  To manually remove only the release commits, run:"
            echo "    git rebase --onto ${PREV_TAG} ${TAGGED_SHORT}"
        else
            echo "  Rewinding all commits since '${PREV_TAG}' (changes kept in working tree)..."
            git reset --mixed "${PREV_COMMIT}"
            echo "  Force-pushing rewound branch to remote..."
            if git push --force origin "${CURRENT_BRANCH}"; then
                echo "  Remote branch updated."
            else
                echo "  WARNING: Force-push failed. Run manually: git push --force origin ${CURRENT_BRANCH}"
            fi
        fi
    fi
fi

echo ""
echo "Done. Release '$TAG' has been fully rescinded."

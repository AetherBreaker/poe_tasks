#!/usr/bin/env bash
# docker-pin-latest.sh — Read PACKAGE_NAME from a docker-compose.yaml build arg,
# resolve the version to pin (explicit arg or latest stable from SFTPyPI),
# and update PACKAGE_VERSION in place.
# Automatically detects the compose file in the project root.
# Typically invoked via: poe docker-pin-latest [--version <ver>]

set -euo pipefail

# Optional explicit version argument (e.g. passed by release-and-pin after a fresh release).
# When provided, the version is used as-is and supports pre-release versions (e.g. 1.2.0a1).
# When omitted, the latest stable release is fetched from SFTPyPI.
VERSION_ARG="${1:-}"

# ---------------------------------------------------------------------------
# Auto-detect docker compose file in the project root (cwd)
# ---------------------------------------------------------------------------
COMPOSE_FILE=""
for candidate in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
  if [ -f "${candidate}" ]; then
    COMPOSE_FILE="${candidate}"
    break
  fi
done

if [ -z "${COMPOSE_FILE}" ]; then
  echo "ERROR: No docker compose file found in $(pwd)." >&2
  echo "       Expected one of: compose.yaml, compose.yml, docker-compose.yaml, docker-compose.yml" >&2
  exit 1
fi

echo "Compose  : ${COMPOSE_FILE}"

# ---------------------------------------------------------------------------
# Extract PACKAGE_NAME from the compose file build args
# ---------------------------------------------------------------------------
PACKAGE_NAME=$(grep -oP 'PACKAGE_NAME:\s*\K\S+' "${COMPOSE_FILE}" | head -1 || true)

if [ -z "${PACKAGE_NAME}" ]; then
  echo "ERROR: Could not find PACKAGE_NAME in ${COMPOSE_FILE}" >&2
  exit 1
fi

echo "Package  : ${PACKAGE_NAME}"

# ---------------------------------------------------------------------------
# Determine the version to pin
# ---------------------------------------------------------------------------
if [ -n "${VERSION_ARG}" ]; then
  # Explicit version provided — use it as-is (supports pre-release versions)
  LATEST_VERSION="${VERSION_ARG}"
  echo "Version  : ${LATEST_VERSION} (explicitly provided)"
else
  # No version specified — query SFTPyPI for the latest stable release only
  echo "Querying SFTPyPI for latest stable version..."

  # Fetch all available versions from the devpi JSON API (public, no auth needed).
  # curl handles the request; uv run python handles JSON parsing and version sort.
  API_JSON=$(curl -sL -H "Accept: application/json" \
    "https://pypi.sweetfiretobacco.com/jacob.ogden/internal/${PACKAGE_NAME}")

  if [ -z "${API_JSON}" ]; then
    echo "ERROR: Empty response from SFTPyPI for package '${PACKAGE_NAME}'" >&2
    exit 1
  fi

  PYFILE=$(mktemp --suffix=.py)
  trap 'rm -f "${PYFILE}"' EXIT

  cat >"${PYFILE}" <<'PYEOF'
import sys, re, json

data = json.load(sys.stdin)

# Keep only PEP 440 stable release versions (no pre/post/dev; no metadata keys like "+doc")
versions = [
    v for v in data.get("result", {})
    if re.match(r'^\d+(\.\d+)*$', v)
]
if not versions:
    print("ERROR: No stable release versions found in SFTPyPI response", file=sys.stderr)
    sys.exit(1)

def version_key(v):
    return tuple(int(x) for x in v.split("."))

print(max(versions, key=version_key))
PYEOF

  LATEST_VERSION=$(printf '%s\n' "${API_JSON}" | uv run python "${PYFILE}")
fi

# ---------------------------------------------------------------------------
# Update PACKAGE_VERSION in the compose file
# ---------------------------------------------------------------------------
# Match any PEP 440 version string: release, pre-release (a/b/rc), post, dev
CURRENT_VERSION=$(grep -oP 'PACKAGE_VERSION:\s*\K\d+(?:\.\d+)*(?:(?:a|b|rc)\d+)?(?:\.post\d+)?(?:\.dev\d+)?' "${COMPOSE_FILE}" | head -1 || true)

echo "Current  : ${CURRENT_VERSION:-<not set>}"
echo "Latest   : ${LATEST_VERSION}"

if [ "${CURRENT_VERSION}" = "${LATEST_VERSION}" ]; then
  echo "Already pinned to ${LATEST_VERSION}. No changes made."
  exit 0
fi

# Replace any full PEP 440 version string (release, pre-release a/b/rc, post, dev)
sed -i -E "s/^([[:space:]]*PACKAGE_VERSION:[[:space:]]*)[0-9]+([.][0-9]+)*((a|b|rc)[0-9]+)?([.]post[0-9]+)?([.]dev[0-9]+)?/\1${LATEST_VERSION}/" "${COMPOSE_FILE}"

echo "Updated PACKAGE_VERSION: ${CURRENT_VERSION:-<not set>} -> ${LATEST_VERSION} in ${COMPOSE_FILE}"

# ---------------------------------------------------------------------------
# Commit the change and push to remote
# ---------------------------------------------------------------------------
git add "${COMPOSE_FILE}"
git commit -m "chore: pin ${PACKAGE_NAME} to ${LATEST_VERSION}"
git push

echo "Committed and pushed: ${COMPOSE_FILE}"

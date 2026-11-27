#!/bin/bash
# Prints a short-lived direct download URL (valid about one hour) of the ISO of a release.
# Needed because the repository is private: the normal release URL requires a login.
# Paste the URL into the ISO import of your hosting panel right away.
#   ./scripts/download-url.sh [owner/repo] [tag]     (default: current repo, latest release)
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
TAG="${2:-}"
if [ -n "$TAG" ]; then
    RELEASE_API="repos/$REPO/releases/tags/$TAG"
else
    RELEASE_API="repos/$REPO/releases/latest"
fi

ASSET_ID=$(gh api "$RELEASE_API" --jq '.assets[] | select(.name=="proxmox-ve-auto.iso") | .id')
[ -n "$ASSET_ID" ] || { echo "No ISO found in the release of $REPO" >&2; exit 1; }

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-$(gh auth token)}}"
URL=$(curl -sI \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/octet-stream" \
    "https://api.github.com/repos/$REPO/releases/assets/$ASSET_ID" \
    | awk 'tolower($1)=="location:" {print $2}' | tr -d '\r')
[ -n "$URL" ] || { echo "GitHub did not return a download location" >&2; exit 1; }
echo "$URL"

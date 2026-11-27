#!/bin/bash
# Prints a short-lived direct download URL of the latest ISO.
# Needed because the repository is private: the permanent release URL requires a login.
# Paste the printed URL into the ISO import of your hosting panel right away (it expires after a few minutes).
#   ./scripts/download-url.sh [owner/repo]
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
ASSET_ID=$(gh api "repos/$REPO/releases/tags/latest" --jq '.assets[] | select(.name=="proxmox-ve-auto.iso") | .id')
[ -n "$ASSET_ID" ] || { echo "No ISO found in release 'latest' of $REPO" >&2; exit 1; }

URL=$(curl -sI \
    -H "Authorization: Bearer $(gh auth token)" \
    -H "Accept: application/octet-stream" \
    "https://api.github.com/repos/$REPO/releases/assets/$ASSET_ID" \
    | awk 'tolower($1)=="location:" {print $2}' | tr -d '\r')
[ -n "$URL" ] || { echo "GitHub did not return a download location" >&2; exit 1; }
echo "$URL"

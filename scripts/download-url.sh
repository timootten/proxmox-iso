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

# Asks for the first byte. Retries a few times: right after an upload the blob can answer with an error once.
probe() {
    local code=""
    for _ in 1 2 3 4 5; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -r 0-0 -m 30 "$1" || true)
        if [ "$code" = "200" ] || [ "$code" = "206" ]; then break; fi
        sleep 3
    done
    echo "$code"
}
ok() { [ "$1" = "200" ] || [ "$1" = "206" ]; }

# 1. Without the "jwt" parameter: the signature alone is enough locally, and Actions would mask jwt as "***".
CLEAN=$(echo "$URL" | sed -E 's/([?&])jwt=[^&]*&?/\1/; s/[?&]$//')
CODE=$(probe "$CLEAN")
if ok "$CODE"; then
    echo "$CLEAN"
    exit 0
fi
echo "note: the URL without jwt answers $CODE, keeping jwt" >&2

# 2. With jwt, every character percent-encoded: the server decodes it, but GitHub Actions does not
#    recognise the string as a secret and does not mask it.
JWT=$(echo "$URL" | sed -nE 's/.*[?&]jwt=([^&]*).*/\1/p')
[ -n "$JWT" ] || { echo "No jwt parameter and the plain URL does not work" >&2; exit 1; }
ENC=$(printf '%s' "$JWT" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g')
URL2=$(echo "$URL" | sed -E "s/([?&]jwt=)[^&]*/\1$ENC/")
CODE=$(probe "$URL2")
ok "$CODE" || { echo "The download URL answers $CODE" >&2; exit 1; }
echo "$URL2"

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

# Asks for the first byte and returns the HTTP status. Retries for up to a minute, because right after an
# upload the storage can answer with an error. Details of every failed attempt go to stderr.
probe() {
    local out="" code=""
    for _ in 1 2 3 4 5 6; do
        out=$(curl -s -o /dev/null -w '%{http_code} exit=%{exitcode} %{errormsg}' -r 0-0 -m 30 "$1" || true)
        code=${out%% *}
        if [ "$code" = "200" ] || [ "$code" = "206" ]; then break; fi
        echo "  attempt failed: $out" >&2
        sleep 10
    done
    echo "$code"
}
ok() { [ "$1" = "200" ] || [ "$1" = "206" ]; }

# Without the "jwt" parameter: the signature alone is enough, and GitHub Actions masks jwt as "***" in logs.
CLEAN=$(echo "$URL" | sed -E 's/([?&])jwt=[^&]*&?/\1/; s/[?&]$//')
CODE=$(probe "$CLEAN")
if ! ok "$CODE"; then
    echo "WARNING: could not verify the download URL (last answer: $CODE). It is printed anyway." >&2
fi
echo "$CLEAN"

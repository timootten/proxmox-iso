#!/bin/bash
# Checks that every template image URL is still reachable. Exit code 1 lists the broken ones.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

bad=0
while IFS= read -r f; do
    url=$(grep -m1 '^IMAGE_URL=' "$f" | cut -d'"' -f2)
    code=$(curl -sIL -m 30 -o /dev/null -w '%{http_code}' "$url")
    if [ "$code" = "200" ]; then
        echo "ok   $f"
    else
        echo "FAIL $f ($code) $url"
        bad=1
    fi
done < <(find templates/configs -name '*.conf' | sort)
exit $bad

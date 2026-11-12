#!/bin/bash
# Usage: screenshot.sh <url> <out.png> [width] [height] [wait_ms]
# Takes a headless screenshot with Chrome / Chromium / Edge / Brave.
# Used by Claude during unattended Claude Servant runs.
set -euo pipefail
URL="${1:?url required}"; OUT="${2:?output path required}"
W="${3:-1440}"; H="${4:-900}"; WAIT="${5:-10000}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

BROWSER="${SERVANT_BROWSER:-}"
if [ -z "$BROWSER" ]; then
  for app in "Google Chrome" "Chromium" "Microsoft Edge" "Brave Browser" "Google Chrome Canary"; do
    for root in /Applications "$HOME/Applications"; do
      bin="$root/$app.app/Contents/MacOS/$app"
      [ -x "$bin" ] && { BROWSER="$bin"; break 2; }
    done
  done
fi
[ -n "$BROWSER" ] || { echo "No Chromium-based browser found (install Google Chrome or set SERVANT_BROWSER)." >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
PROFILE=$(mktemp -d)
trap 'rm -rf "$PROFILE"' EXIT
"$BROWSER" --headless=new --hide-scrollbars --no-first-run --no-default-browser-check \
  --enable-unsafe-swiftshader --user-data-dir="$PROFILE" \
  --window-size="${W},${H}" --virtual-time-budget="$WAIT" \
  --screenshot="$OUT" "$URL" >/dev/null 2>&1
ls -la "$OUT"

#!/bin/bash
# Claude_Servant status line hook.
# Claude Code pipes session JSON (incl. rate_limits) to this script on every update.
# We save it so the Claude Servant menu bar app can track your usage windows.
DIR="$HOME/.claude/servant"
mkdir -p "$DIR"
input=$(cat)
if printf '%s' "$input" | grep -q '"rate_limits"'; then
  tmp="$DIR/usage.json.$$"
  printf '%s' "$input" > "$tmp" && mv -f "$tmp" "$DIR/usage.json"
fi
get() { printf '%s' "$input" | plutil -extract "$1" raw -o - - 2>/dev/null; }
model=$(get model.display_name)
five=$(get rate_limits.five_hour.used_percentage)
week=$(get rate_limits.seven_day.used_percentage)
out="${model:-Claude}"
[ -n "$five" ] && out="$out · 5h $(printf '%.0f' "$five")%"
[ -n "$week" ] && out="$out · 7d $(printf '%.0f' "$week")%"
echo "$out"

#!/bin/bash
# Removes Claude Servant. Keeps ~/.claude/servant (config + logs) unless you pass --purge.
set -euo pipefail
pkill -x ClaudeServant 2>/dev/null || true
rm -rf ~/Applications/"Claude Servant.app" "/Applications/Claude Servant.app"
/usr/bin/python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(p):
    s = json.load(open(p))
    if "servant/bin/statusline.sh" in (s.get("statusLine") or {}).get("command", ""):
        del s["statusLine"]; json.dump(s, open(p, "w"), indent=2); print("Removed status line hook")
PY
if [ "${1:-}" = "--purge" ]; then rm -rf ~/.claude/servant; echo "Removed ~/.claude/servant"; fi
echo "Claude Servant uninstalled."

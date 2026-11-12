#!/bin/bash
# Removes Claude Servant. Keeps ~/.claude/servant (config + logs) unless you pass --purge.
set -euo pipefail
osascript -e 'tell application "System Events" to delete login item "Claude Servant"' 2>/dev/null || true
pkill -x ClaudeServant 2>/dev/null || true
rm -rf ~/Applications/"Claude Servant.app" "/Applications/Claude Servant.app"
/usr/bin/python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(p):
    s = json.load(open(p))
    if "servant/bin/statusline.sh" in (s.get("statusLine") or {}).get("command", ""):
        import tempfile
        del s["statusLine"]
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
        with os.fdopen(fd, "w") as f: json.dump(s, f, indent=2)
        os.replace(tmp, p); print("Removed status line hook")
    elif "servant/bin/statusline.sh" in json.dumps(s.get("statusLine") or {}):
        print("!! Your statusLine chains the Servant hook; remove the 'tee >(...statusline.sh...)' part by hand.")
PY
if [ "${1:-}" = "--purge" ]; then rm -rf ~/.claude/servant; echo "Removed ~/.claude/servant"; fi
echo "Claude Servant uninstalled."

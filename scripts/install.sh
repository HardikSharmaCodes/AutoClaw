#!/bin/bash
# Installs Claude Servant:
#  1. builds the app and copies it to ~/Applications
#  2. installs helper scripts into ~/.claude/servant/bin
#  3. registers the status-line hook in ~/.claude/settings.json (only if you have no status line yet)
#  4. launches the app
set -euo pipefail
cd "$(dirname "$0")/.."

command -v swift >/dev/null || { echo "Swift not found. Install Xcode Command Line Tools: xcode-select --install"; exit 1; }
CLAUDE=""
for c in "$(command -v claude || true)" ~/.local/bin/claude ~/.claude/local/claude /opt/homebrew/bin/claude /usr/local/bin/claude; do
  [ -n "$c" ] && [ -x "$c" ] && { CLAUDE="$c"; break; }
done
if [ -z "$CLAUDE" ]; then
  echo "⚠️  Claude Code CLI not found. Install it from https://claude.com/claude-code, then log in once with: claude"
fi

./scripts/build_app.sh

mkdir -p ~/Applications ~/.claude/servant/bin ~/.claude/servant/logs
pkill -x ClaudeServant 2>/dev/null || true
rm -rf ~/Applications/"Claude Servant.app"
cp -R "build/Claude Servant.app" ~/Applications/
install -m 755 Resources/statusline.sh ~/.claude/servant/bin/statusline.sh
install -m 755 Resources/screenshot.sh ~/.claude/servant/bin/screenshot.sh

/usr/bin/python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
s = json.load(open(p)) if os.path.exists(p) else {}
hook = os.path.expanduser("~/.claude/servant/bin/statusline.sh")
cur = s.get("statusLine")
if cur is None:
    s["statusLine"] = {"type": "command", "command": hook}
    json.dump(s, open(p, "w"), indent=2)
    print("Status line hook added to", p)
elif cur.get("command") == hook:
    print("Status line hook already installed")
else:
    print("!! You already have a statusLine command:", cur.get("command"))
    print("!! Add this to the start of it so usage gets recorded:  tee >(" + hook + " >/dev/null) |")
PY

open ~/Applications/"Claude Servant.app"
echo "Claude Servant installed and running (look for the ✦ icon in your menu bar)."

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

CLAUDE_BIN="$CLAUDE" /usr/bin/python3 - <<'PY' || echo "!! Could not update settings.json automatically (see above)."
import json, os, tempfile
def atomic_dump(obj, path):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as f: json.dump(obj, f, indent=2)
    os.replace(tmp, path)

p = os.path.expanduser("~/.claude/settings.json")
try:
    s = json.load(open(p)) if os.path.exists(p) else {}
except ValueError:
    print("!! ~/.claude/settings.json is not valid JSON; leaving it alone. Fix it, then re-run install.sh.")
    s = None
if s is not None:
    hook = os.path.expanduser("~/.claude/servant/bin/statusline.sh")
    cur = s.get("statusLine")
    if cur is None:
        s["statusLine"] = {"type": "command", "command": hook}
        atomic_dump(s, p)
        print("Status line hook added to", p)
    elif cur.get("command") == hook:
        print("Status line hook already installed")
    else:
        print("!! You already have a statusLine command:", cur.get("command"))
        print("!! Add this to the start of it so usage gets recorded:  tee >(" + hook + " >/dev/null) |")

claude = os.environ.get("CLAUDE_BIN", "")
cp = os.path.expanduser("~/.claude/servant/config.json")
if claude and os.path.exists(cp):
    try:
        c = json.load(open(cp))
        if c.get("claudePath") != claude and not os.path.exists(os.path.expanduser(c.get("claudePath", "~/.local/bin/claude"))):
            c["claudePath"] = claude
            atomic_dump(c, cp)
            print("Saved claudePath =", claude)
    except ValueError:
        pass
PY

open ~/Applications/"Claude Servant.app"
echo "Claude Servant installed and running (look for the ✦ icon in your menu bar)."

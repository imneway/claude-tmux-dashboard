#!/usr/bin/env bash
set -euo pipefail

# Installs only the tmux-monitor component (launchd agent that watches Claude
# Code sessions and auto-restarts them with --resume).
#
# Called by the top-level install.sh. You can also run it standalone if you
# only want the monitor without the dashboard.

case "${1:-}" in
  -h|--help)
    sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR_DIR="$HOME/.claude/tmux-monitor"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.claude.tmux-monitor"
PLIST_DEST="$LAUNCH_AGENTS_DIR/$PLIST_NAME.plist"
GUI_DOMAIN="gui/$(id -u)"

echo "=== tmux-monitor: install ==="

mkdir -p "$MONITOR_DIR/state" "$MONITOR_DIR/logs"

ln -sf "$SCRIPT_DIR/monitor.sh" "$MONITOR_DIR/monitor.sh"
ln -sf "$SCRIPT_DIR/ctl.sh" "$MONITOR_DIR/ctl.sh"

if [ ! -f "$MONITOR_DIR/sessions.json" ]; then
  cp "$SCRIPT_DIR/sessions.json.default" "$MONITOR_DIR/sessions.json"
  echo "  Created default sessions.json — edit it to add your bot sessions."
else
  echo "  sessions.json already exists, not overwriting."
fi

mkdir -p "$LAUNCH_AGENTS_DIR"

# Render plist with absolute paths
python3 - "$SCRIPT_DIR/com.claude.tmux-monitor.plist" "$PLIST_DEST" \
  "$MONITOR_DIR/monitor.sh" "$MONITOR_DIR/logs" "$HOME" <<'PY'
import sys
tpl, dest, monitor_sh, log_dir, home = sys.argv[1:6]
with open(tpl) as f:
    content = f.read()
content = (content
  .replace('__MONITOR_SH_PATH__', monitor_sh)
  .replace('__LOG_DIR__', log_dir)
  .replace('__HOME__', home))
with open(dest, 'w') as f:
    f.write(content)
PY

# Load via launchd (modern bootstrap with legacy fallback)
launchctl bootout "$GUI_DOMAIN/$PLIST_NAME" 2>/dev/null || \
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap "$GUI_DOMAIN" "$PLIST_DEST" 2>/dev/null || \
  launchctl load "$PLIST_DEST"

echo "  Installed. Runs every 60s; auto-starts on login."
echo "  Config: $MONITOR_DIR/sessions.json"
echo "  Logs:   $MONITOR_DIR/logs/"

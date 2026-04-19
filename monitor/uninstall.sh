#!/usr/bin/env bash
set -euo pipefail

# Removes the tmux-monitor launchd agent but keeps sessions.json/logs by default.

case "${1:-}" in
  -h|--help)
    sed -n '4,4p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

MONITOR_DIR="$HOME/.claude/tmux-monitor"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.claude.tmux-monitor"
PLIST_DEST="$LAUNCH_AGENTS_DIR/$PLIST_NAME.plist"
GUI_DOMAIN="gui/$(id -u)"

echo "=== tmux-monitor: uninstall ==="

launchctl bootout "$GUI_DOMAIN/$PLIST_NAME" 2>/dev/null || \
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
rm -f "$PLIST_DEST"
rm -f "$MONITOR_DIR/monitor.sh" "$MONITOR_DIR/ctl.sh"

echo "  launchd agent removed."
echo "  Left in place (remove manually if wanted): $MONITOR_DIR/sessions.json, $MONITOR_DIR/logs/, $MONITOR_DIR/state/"

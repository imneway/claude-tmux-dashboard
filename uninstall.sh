#!/usr/bin/env bash
set -euo pipefail

# Removes both launchd agents (dashboard + tmux-monitor).
# Leaves sessions.json, logs, and token in place — delete manually if wanted.

case "${1:-}" in
  -h|--help)
    sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.claude.bot-dashboard"
PLIST_DEST="$LAUNCH_AGENTS_DIR/$PLIST_NAME.plist"
GUI_DOMAIN="gui/$(id -u)"

echo "=== dashboard: uninstall ==="

launchctl bootout "$GUI_DOMAIN/$PLIST_NAME" 2>/dev/null || \
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
rm -f "$PLIST_DEST"
echo "  Dashboard launchd agent removed."

bash "$REPO_DIR/monitor/uninstall.sh"

cat <<EOF

Kept in place (delete manually if you want a clean slate):
  ~/.claude/bot-dashboard/       (token file, logs, error log)
  ~/.claude/tmux-monitor/         (sessions.json, logs, state)
EOF

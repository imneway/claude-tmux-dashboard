#!/usr/bin/env bash
set -euo pipefail

umask 077

show_help() {
  cat <<'HELP'
claude-tmux-dashboard installer

Usage: ./install.sh [--port <port>] [--token <token>] [--host <host>]

Options:
  --port <port>    HTTP port to bind (default: 7010)
  --token <token>  Reuse an existing access token (default: generate/read one)
  --host <host>    Host to bind (default: 0.0.0.0; use 127.0.0.1 for local-only)
  -h, --help       Show this help

Idempotent — rerun safely to upgrade. Sets up both the tmux-monitor
launchd agent and the dashboard launchd agent. Prints the dashboard URL on
completion.
HELP
}

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="7010"
TOKEN=""
HOST="0.0.0.0"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "Unknown argument: $1"; show_help; exit 1 ;;
  esac
done

# --- Preflight (fail BEFORE any side effects) ---

for cmd in tmux node python3 launchctl openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd"; exit 1; }
done

if ! command -v claude >/dev/null 2>&1; then
  echo "Warning: 'claude' CLI not found on PATH. Install Claude Code first: https://claude.com/claude-code"
fi

# --- Install monitor component ---

bash "$REPO_DIR/monitor/install.sh"

# --- Install dashboard launchd agent ---

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.claude.bot-dashboard"
PLIST_DEST="$LAUNCH_AGENTS_DIR/$PLIST_NAME.plist"
GUI_DOMAIN="gui/$(id -u)"

STATE_DIR="$HOME/.claude/bot-dashboard"
LOG_DIR="$STATE_DIR/logs"
TOKEN_FILE="$STATE_DIR/token"
mkdir -p "$STATE_DIR" "$LOG_DIR" "$LAUNCH_AGENTS_DIR"

# Resolve TOKEN: arg > existing file > new random
if [ -z "$TOKEN" ]; then
  if [ -s "$TOKEN_FILE" ]; then
    TOKEN="$(cat "$TOKEN_FILE")"
    echo "=== dashboard: reusing existing token from $TOKEN_FILE ==="
  else
    TOKEN="$(openssl rand -hex 16)"
    echo "$TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "=== dashboard: generated new token (saved to $TOKEN_FILE) ==="
  fi
else
  echo "$TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "=== dashboard: using token provided via --token ==="
fi

NODE_PATH="$(command -v node)"
SERVER_JS="$REPO_DIR/server/index.js"
MONITOR_DIR="$HOME/.claude/tmux-monitor"

python3 - "$REPO_DIR/server/com.claude.bot-dashboard.plist" "$PLIST_DEST" \
  "$NODE_PATH" "$SERVER_JS" "$LOG_DIR" "$HOME" "$PORT" "$TOKEN" "$MONITOR_DIR" "$HOST" <<'PY'
import sys
from xml.sax.saxutils import escape as xml_escape
tpl, dest, node_path, server_js, log_dir, home, port, token, monitor_dir, host = sys.argv[1:11]
with open(tpl) as f:
    c = f.read()
for placeholder, value in [
    ('__NODE_PATH__', node_path),
    ('__SERVER_JS_PATH__', server_js),
    ('__LOG_DIR__', log_dir),
    ('__HOME__', home),
    ('__PORT__', port),
    ('__TOKEN__', token),
    ('__MONITOR_DIR__', monitor_dir),
    ('__HOST__', host),
]:
    c = c.replace(placeholder, xml_escape(value))
with open(dest, 'w') as f:
    f.write(c)
PY
chmod 600 "$PLIST_DEST"

launchctl bootout "$GUI_DOMAIN/$PLIST_NAME" 2>/dev/null || \
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap "$GUI_DOMAIN" "$PLIST_DEST" 2>/dev/null || \
  launchctl load "$PLIST_DEST"

IP="$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)"

cat <<EOF

=== Installed ===
  Dashboard URL: http://${IP}:${PORT}/tmux-status?token=${TOKEN}
                 http://127.0.0.1:${PORT}/tmux-status?token=${TOKEN}
  Logs:          ${LOG_DIR}/
  Token file:    ${TOKEN_FILE}
  Monitor dir:   ${MONITOR_DIR}

Next steps:
  1. Edit sessions you want monitored:
       ${MONITOR_DIR}/sessions.json
  2. Open the dashboard URL above.
  3. Inspect logs if something goes wrong:
       tail -f ${LOG_DIR}/dashboard-stderr.log
EOF

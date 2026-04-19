#!/usr/bin/env bash
set -euo pipefail

# Claude tmux Session Monitor - Control CLI

MONITOR_DIR="${CLAUDE_TMUX_MONITOR_DIR:-$HOME/.claude/tmux-monitor}"
SESSIONS_FILE="$MONITOR_DIR/sessions.json"
STATE_DIR="$MONITOR_DIR/state"
LOG_DIR="$MONITOR_DIR/logs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Helpers ---

validate_name() {
  local name="$1"
  if [ -z "$name" ] || [[ "$name" =~ [/\\] ]] || [ "$name" = ".." ] || [ "$name" = "." ]; then
    return 1
  fi
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    return 1
  fi
  return 0
}

list_sessions() {
  python3 - "$SESSIONS_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
for k in d:
    print(k)
PY
}

json_nested() {
  local file="$1" key1="$2" key2="$3"
  python3 - "$file" "$key1" "$key2" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    print('')
    sys.exit(0)
if not isinstance(d, dict):
    print('')
    sys.exit(0)
v = d.get(sys.argv[2], {})
if isinstance(v, dict):
    r = v.get(sys.argv[3], '')
else:
    r = ''
if isinstance(r, bool):
    print('true' if r else 'false')
elif isinstance(r, str):
    print(r)
else:
    print(r)
PY
}

tmux_pane_pid() {
  tmux list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null | head -1
}

is_alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

state_get() {
  local name="$1" key="$2" default="${3:-}"
  local state_file="$STATE_DIR/$name.json"
  if [ -f "$state_file" ]; then
    python3 - "$state_file" "$key" "$default" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    print(sys.argv[3])
    sys.exit(0)
if not isinstance(d, dict):
    print(sys.argv[3])
    sys.exit(0)
v = d.get(sys.argv[2], sys.argv[3])
if isinstance(v, bool):
    print('true' if v else 'false')
else:
    print(v)
PY
  else
    echo "$default"
  fi
}

# --- Commands ---

cmd_status() {
  if [ ! -f "$SESSIONS_FILE" ]; then
    echo "No sessions.json found. Run 'install.sh' first."
    exit 1
  fi

  printf "%-20s %-10s %-8s %-12s %s\n" "NAME" "STATUS" "PID" "RESTARTS" "TMUX"
  printf "%-20s %-10s %-8s %-12s %s\n" "----" "------" "---" "--------" "----"

  while IFS= read -r name; do
    local tmux_session enabled status pid restarts tmux_alive

    tmux_session=$(json_nested "$SESSIONS_FILE" "$name" "tmuxSession")
    [ -z "$tmux_session" ] && tmux_session="$name"
    enabled=$(json_nested "$SESSIONS_FILE" "$name" "enabled")

    if [ "$enabled" = "false" ]; then
      printf "%-20s %-10s %-8s %-12s %s\n" "$name" "disabled" "-" "-" "$tmux_session"
      continue
    fi

    pid=$(state_get "$name" "pid" "-")
    restarts=$(state_get "$name" "restartCount" "0")
    status=$(state_get "$name" "status" "unknown")
    tmux_alive="no"

    if tmux has-session -t "$tmux_session" 2>/dev/null; then
      local pane_pid
      pane_pid=$(tmux_pane_pid "$tmux_session")
      if is_alive "$pane_pid"; then
        status="running"
        pid="$pane_pid"
        tmux_alive="yes"
      else
        status="dead"
        tmux_alive="zombie"
      fi
    fi

    printf "%-20s %-10s %-8s %-12s %s\n" "$name" "$status" "$pid" "$restarts" "$tmux_session ($tmux_alive)"
  done < <(list_sessions)
}

cmd_restart() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    echo "Usage: ctl.sh restart <name|all>"
    exit 1
  fi

  local sessions_list
  if [ "$target" = "all" ]; then
    sessions_list=$(list_sessions)
  else
    sessions_list="$target"
  fi

  while IFS= read -r name; do
    if ! validate_name "$name"; then
      echo "Invalid session name: $name"
      continue
    fi
    local tmux_session command
    command=$(json_nested "$SESSIONS_FILE" "$name" "command")
    if [ -z "$command" ]; then
      echo "Unknown session: $name"
      continue
    fi

    tmux_session=$(json_nested "$SESSIONS_FILE" "$name" "tmuxSession")
    [ -z "$tmux_session" ] && tmux_session="$name"

    echo "Restarting $name..."

    # Save session ID before killing
    if tmux has-session -t "$tmux_session" 2>/dev/null; then
      local pane_pid
      pane_pid=$(tmux_pane_pid "$tmux_session")
      if [ -n "$pane_pid" ]; then
        python3 - "$HOME/.claude/sessions/$pane_pid.json" "$STATE_DIR/$name.json" "$pane_pid" <<'PY'
import json, sys, os
session_file, state_file, pid = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(session_file) as f:
        sid = json.load(f).get('sessionId', '')
except: sid = ''
try:
    with open(state_file) as f:
        state = json.load(f)
except: state = {}
if sid:
    state['claudeSessionId'] = sid
state['pid'] = int(pid)
tmp = state_file + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, state_file)
PY
      fi
      tmux kill-session -t "$tmux_session" 2>/dev/null || true
      sleep 1
    fi

    # Unpause and clear crash timestamps
    if [ -f "$STATE_DIR/$name.json" ]; then
      python3 - "$STATE_DIR/$name.json" <<'PY'
import json, sys, os
state_file = sys.argv[1]
try:
    with open(state_file) as f:
        state = json.load(f)
except: state = {}
state['paused'] = False
state['restartTimestamps'] = []
tmp = state_file + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, state_file)
PY
    fi

    # Run monitor for just this session, retrying if lock is held
    local lock_dir="${CLAUDE_TMUX_MONITOR_DIR:-$HOME/.claude/tmux-monitor}/monitor.lock.d"
    local attempt=0
    while [ $attempt -lt 5 ]; do
      if bash "$SCRIPT_DIR/monitor.sh" --only "$name"; then
        break
      fi
      # Check if it was a lock contention (lock dir exists)
      if [ -d "$lock_dir" ]; then
        attempt=$((attempt + 1))
        echo "  Lock held by another monitor, retrying ($attempt/5)..."
        sleep 2
      else
        break
      fi
    done

    # Verify it actually started
    local verify_session
    verify_session=$(json_nested "$SESSIONS_FILE" "$name" "tmuxSession")
    [ -z "$verify_session" ] && verify_session="$name"
    if tmux has-session -t "$verify_session" 2>/dev/null; then
      echo "$name restarted."
    else
      echo "$name restart FAILED — check logs: $SCRIPT_DIR/ctl.sh logs $name"
    fi
  done <<< "$sessions_list"
}

cmd_logs() {
  local name="${1:-}" lines="${2:-50}"
  local logfile="$LOG_DIR/monitor.log"

  if [ ! -f "$logfile" ]; then
    echo "No logs yet."
    exit 0
  fi

  if [ -n "$name" ] && [ "$name" != "all" ]; then
    grep -F "[$name]" "$logfile" | tail -n "$lines"
  else
    tail -n "$lines" "$logfile"
  fi
}

cmd_pause() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Usage: ctl.sh pause <name>"
    exit 1
  fi
  if ! validate_name "$name"; then
    echo "Invalid session name: $name"
    exit 1
  fi

  python3 - "$STATE_DIR/$name.json" <<'PY'
import json, sys, os
state_file = sys.argv[1]
try:
    with open(state_file) as f:
        state = json.load(f)
except: state = {}
state['paused'] = True
state['status'] = 'paused'
tmp = state_file + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, state_file)
PY
  echo "$name paused."
}

cmd_unpause() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Usage: ctl.sh unpause <name>"
    exit 1
  fi
  if ! validate_name "$name"; then
    echo "Invalid session name: $name"
    exit 1
  fi

  python3 - "$STATE_DIR/$name.json" <<'PY'
import json, sys, os
state_file = sys.argv[1]
try:
    with open(state_file) as f:
        state = json.load(f)
except: state = {}
state['paused'] = False
state['status'] = 'stopped'
state['restartTimestamps'] = []
tmp = state_file + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, state_file)
PY
  echo "$name unpaused. Will restart on next monitor cycle."
}

cmd_add() {
  local name="${1:-}" command="${2:-}"
  if [ -z "$name" ] || [ -z "$command" ]; then
    echo "Usage: ctl.sh add <name> <command> [cwd]"
    exit 1
  fi
  if ! validate_name "$name"; then
    echo "Invalid session name. Use alphanumeric, dash, underscore, dot only."
    exit 1
  fi
  local cwd="${3:-$HOME}"

  python3 - "$SESSIONS_FILE" "$name" "$command" "$cwd" <<'PY'
import json, sys, os
sessions_file = sys.argv[1]
name = sys.argv[2]
command = sys.argv[3]
cwd = sys.argv[4]
try:
    with open(sessions_file) as f:
        sessions = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sessions = {}
sessions[name] = {
    'command': command,
    'cwd': cwd,
    'tmuxSession': name,
    'resumable': True,
    'enabled': True
}
tmp = sessions_file + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(sessions, f, indent=2)
os.replace(tmp, sessions_file)
PY
  echo "Added session '$name'."
}

cmd_remove() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Usage: ctl.sh remove <name>"
    exit 1
  fi
  if ! validate_name "$name"; then
    echo "Invalid session name: $name"
    exit 1
  fi

  python3 - "$SESSIONS_FILE" "$name" <<'PY'
import json, sys, os
sessions_file = sys.argv[1]
name = sys.argv[2]
try:
    with open(sessions_file) as f:
        sessions = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    print(f"Error: cannot read {sessions_file}")
    sys.exit(1)
if name in sessions:
    del sessions[name]
tmp = sessions_file + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(sessions, f, indent=2)
os.replace(tmp, sessions_file)
PY
  echo "Removed session '$name'."
}

# --- Dispatch ---

cmd="${1:-help}"
shift || true

case "$cmd" in
  status)   cmd_status "$@" ;;
  restart)  cmd_restart "$@" ;;
  logs)     cmd_logs "$@" ;;
  pause)    cmd_pause "$@" ;;
  unpause)  cmd_unpause "$@" ;;
  add)      cmd_add "$@" ;;
  remove)   cmd_remove "$@" ;;
  help|*)
    echo "Claude tmux Session Monitor - Control CLI"
    echo ""
    echo "Usage: ctl.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  status                Show all session statuses"
    echo "  restart <name|all>    Restart a session (or all)"
    echo "  logs [name] [lines]   Show recent logs"
    echo "  pause <name>          Pause auto-restart for a session"
    echo "  unpause <name>        Resume auto-restart"
    echo "  add <name> <cmd>      Add a new session"
    echo "  remove <name>         Remove a session"
    ;;
esac

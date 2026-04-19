#!/usr/bin/env bash
set -euo pipefail

# Claude tmux Session Monitor
# Called periodically by launchd to ensure configured sessions stay alive.
# Optional: pass --only <name> to check a single session.

MONITOR_DIR="${CLAUDE_TMUX_MONITOR_DIR:-$HOME/.claude/tmux-monitor}"
SESSIONS_FILE="$MONITOR_DIR/sessions.json"
STATE_DIR="$MONITOR_DIR/state"
LOG_DIR="$MONITOR_DIR/logs"
LOCK_DIR="$MONITOR_DIR/monitor.lock.d"

CRASH_WINDOW=300        # seconds (5 minutes)
CRASH_THRESHOLD=3       # max restarts within window
LOG_RETENTION_DAYS=7

ONLY_SESSION=""
if [ "${1:-}" = "--only" ] && [ -n "${2:-}" ]; then
  ONLY_SESSION="$2"
fi

mkdir -p "$STATE_DIR" "$LOG_DIR"

# Validate session name: reject path traversal and unsafe characters
validate_name() {
  local name="$1"
  if [ -z "$name" ] || [[ "$name" =~ [/\\] ]] || [ "$name" = ".." ] || [ "$name" = "." ]; then
    return 1
  fi
  # Only allow alphanumeric, dash, underscore, dot (not leading dot)
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    return 1
  fi
  return 0
}

log() {
  local level="$1"; shift
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local msg="[$ts] [$level] $*"
  echo "$msg" >> "$LOG_DIR/monitor.log"
  echo "$msg" >&2
}

# --- Atomic lock via mkdir ---
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    return 0
  fi
  # Lock dir exists — check if holder is still alive
  local lock_pid
  lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [ -z "$lock_pid" ]; then
    # No pid file yet — another process just created the dir and hasn't
    # written its pid. Treat as busy unless the dir is older than 10s
    # (owner crashed between mkdir and pid write).
    local lock_age=0
    if [ -d "$LOCK_DIR" ]; then
      local lock_mtime; lock_mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
      local now_s; now_s=$(date +%s)
      lock_age=$((now_s - lock_mtime))
    fi
    if [ "$lock_age" -lt 10 ]; then
      log WARN "Lock exists but no PID yet (owner still starting), exiting."
      exit 1
    fi
    # Pid-less lock older than 10s — treat as stale and fall through to reclaim
    log WARN "Pid-less lock is ${lock_age}s old, reclaiming as stale."
  fi
  if kill -0 "$lock_pid" 2>/dev/null; then
    log WARN "Another monitor is running (PID $lock_pid), exiting."
    exit 1
  fi
  # Stale lock — rename aside atomically, then try mkdir again.
  # If another process reclaimed between our check and rename, our
  # mkdir will fail harmlessly and we exit.
  mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null || true
  rm -rf "$LOCK_DIR.stale.$$" 2>/dev/null || true
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log WARN "Lock reclaimed by another process, exiting."
    exit 0
  fi
  echo $$ > "$LOCK_DIR/pid"
}

release_lock() {
  # Only release if we own it
  local lock_pid
  lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [ "$lock_pid" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
}
trap release_lock EXIT

# --- JSON helpers (pass data via sys.argv, not string interpolation) ---

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

tmux_pane_pid() {
  local session="$1"
  tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null | head -1
}

is_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

read_state() {
  local name="$1"
  local state_file="$STATE_DIR/$name.json"
  if [ -f "$state_file" ]; then
    cat "$state_file"
  else
    echo '{}'
  fi
}

get_claude_session_id() {
  local pid="$1"
  local session_file="$HOME/.claude/sessions/$pid.json"
  if [ -f "$session_file" ]; then
    python3 - "$session_file" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    if not isinstance(d, dict): d = {}
    print(d.get('sessionId', ''))
except (FileNotFoundError, json.JSONDecodeError):
    print('')
PY
  fi
}

# --- Crash loop detection ---
# Returns 1 (fail) if adding one more restart would exceed the threshold.
check_crash_loop() {
  local name="$1"
  local now; now=$(date +%s)
  local state; state=$(read_state "$name")
  local recent_count
  recent_count=$(_JSON_INPUT="$state" python3 - "$now" "$CRASH_WINDOW" <<'PY'
import json, sys, os
now = int(sys.argv[1])
window = int(sys.argv[2])
try:
    d = json.loads(os.environ.get('_JSON_INPUT', '{}'))
except json.JSONDecodeError:
    d = {}
if not isinstance(d, dict): d = {}
ts = d.get('restartTimestamps', [])
cutoff = now - window
recent = [t for t in ts if t > cutoff]
# Count including the restart we're about to do
print(len(recent) + 1)
PY
  )

  if [ "${recent_count:-0}" -gt "$CRASH_THRESHOLD" ]; then
    return 1  # crash loop detected
  fi
  return 0
}

# --- Start a session ---
start_session() {
  local name="$1"
  local command="$2"
  local cwd="$3"
  local tmux_session="$4"
  local resumable="$5"

  local now; now=$(date +%s)
  local now_iso; now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local state; state=$(read_state "$name")
  local resume_id=""

  # Try to resume if enabled
  if [ "$resumable" = "true" ]; then
    local last_pid
    last_pid=$(_JSON_INPUT="$state" python3 <<'PY'
import json, os
try:
    d = json.loads(os.environ.get('_JSON_INPUT', '{}'))
except json.JSONDecodeError:
    d = {}
if not isinstance(d, dict): d = {}
print(d.get('pid', ''))
PY
    ) || true

    if [ -n "$last_pid" ] && [ "$last_pid" != "0" ]; then
      resume_id=$(get_claude_session_id "$last_pid")
    fi

    # Also check claudeSessionId in state
    if [ -z "$resume_id" ]; then
      resume_id=$(_JSON_INPUT="$state" python3 <<'PY'
import json, os
try:
    d = json.loads(os.environ.get('_JSON_INPUT', '{}'))
except json.JSONDecodeError:
    d = {}
if not isinstance(d, dict): d = {}
print(d.get('claudeSessionId', ''))
PY
      ) || true
    fi
  fi

  local full_command="$command"
  if [ -n "$resume_id" ]; then
    # Validate resume_id is a UUID (alphanumeric + hyphens only) to prevent injection
    if [[ "$resume_id" =~ ^[a-zA-Z0-9-]+$ ]]; then
      full_command="$command --resume $(printf %q "$resume_id")"
      log INFO "[$name] Resuming with session ID: $resume_id"
    else
      log WARN "[$name] Invalid session ID '$resume_id', starting fresh"
      resume_id=""
    fi
  fi
  if [ -z "$resume_id" ]; then
    log INFO "[$name] Starting fresh (no session to resume)"
  fi

  # Create tmux session
  tmux new-session -d -s "$tmux_session" -c "$cwd" "$full_command" 2>/dev/null || {
    log ERROR "[$name] Failed to create tmux session '$tmux_session'"
    return 1
  }

  sleep 2

  local new_pid
  new_pid=$(tmux_pane_pid "$tmux_session")

  # Try to read the new process's actual Claude session ID
  local new_session_id="${resume_id}"
  if [ -n "$new_pid" ] && [ "$new_pid" != "0" ]; then
    local fetched_id
    fetched_id=$(get_claude_session_id "$new_pid") || true
    [ -n "$fetched_id" ] && new_session_id="$fetched_id"
  fi

  # Update restart timestamps and write state (atomic via tmp+replace)
  _JSON_INPUT="$state" python3 - "${new_pid:-0}" "$new_session_id" "$now_iso" "$now" "$CRASH_WINDOW" "$STATE_DIR/$name.json" <<'PY'
import json, sys, os
try:
    old = json.loads(os.environ.get('_JSON_INPUT', '{}'))
except json.JSONDecodeError:
    old = {}
if not isinstance(old, dict): old = {}
new_pid = int(sys.argv[1])
session_id = sys.argv[2]
now_iso = sys.argv[3]
now = int(sys.argv[4])
window = int(sys.argv[5])
out_file = sys.argv[6]

ts = old.get('restartTimestamps', [])
cutoff = now - window
recent = [t for t in ts if t > cutoff]
recent.append(now)

state = {
    'pid': new_pid,
    'claudeSessionId': session_id,
    'lastStarted': now_iso,
    'restartCount': old.get('restartCount', 0) + 1,
    'restartTimestamps': recent,
    'status': 'running',
    'paused': False
}
tmp = out_file + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, out_file)
PY

  log INFO "[$name] Started (PID: ${new_pid:-unknown}, tmux: $tmux_session)"
}

# --- Main loop ---
main() {
  acquire_lock

  if [ ! -f "$SESSIONS_FILE" ]; then
    log WARN "No sessions.json found at $SESSIONS_FILE"
    exit 0
  fi

  while IFS= read -r name; do
    # Reject unsafe session names (path traversal, special chars)
    if ! validate_name "$name"; then
      log ERROR "Unsafe session name '$name', skipping"
      continue
    fi

    # If --only specified, skip others
    if [ -n "$ONLY_SESSION" ] && [ "$name" != "$ONLY_SESSION" ]; then
      continue
    fi

    # Read session config
    local enabled command cwd tmux_session resumable
    enabled=$(json_nested "$SESSIONS_FILE" "$name" "enabled")
    command=$(json_nested "$SESSIONS_FILE" "$name" "command")
    cwd=$(json_nested "$SESSIONS_FILE" "$name" "cwd")
    tmux_session=$(json_nested "$SESSIONS_FILE" "$name" "tmuxSession")
    resumable=$(json_nested "$SESSIONS_FILE" "$name" "resumable")

    # Defaults
    [ -z "$tmux_session" ] && tmux_session="$name"
    [ -z "$resumable" ] && resumable="true"
    [ "$enabled" = "false" ] && continue
    [ -z "$command" ] && { log WARN "[$name] No command configured, skipping"; continue; }
    [ -z "$cwd" ] && cwd="$HOME"

    # Check if paused
    local state; state=$(read_state "$name")
    local paused
    paused=$(_JSON_INPUT="$state" python3 <<'PY'
import json, os
try:
    d = json.loads(os.environ.get('_JSON_INPUT', '{}'))
except json.JSONDecodeError:
    d = {}
if not isinstance(d, dict): d = {}
print('true' if d.get('paused', False) else 'false')
PY
    ) || echo "false"

    if [ "$paused" = "true" ]; then
      continue
    fi

    # Check if tmux session exists and process is alive
    local alive=false
    if tmux has-session -t "$tmux_session" 2>/dev/null; then
      local pane_pid
      pane_pid=$(tmux_pane_pid "$tmux_session")
      if is_alive "$pane_pid"; then
        # Update state with current PID (in case session was restarted externally)
        local current_state_pid
        current_state_pid=$(_JSON_INPUT="$state" python3 <<'PY'
import json, os
try:
    d = json.loads(os.environ.get('_JSON_INPUT', '{}'))
except json.JSONDecodeError:
    d = {}
if not isinstance(d, dict): d = {}
print(d.get('pid', 0))
PY
        ) || echo "0"

        if [ "$current_state_pid" != "$pane_pid" ] && [ -n "$pane_pid" ]; then
          local session_id
          session_id=$(get_claude_session_id "$pane_pid")
          local now_iso; now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

          # Read state from file (not from variable) for freshness, with fallback
          python3 - "$STATE_DIR/$name.json" "$pane_pid" "${session_id:-}" <<'PY'
import json, sys, os
state_file = sys.argv[1]
new_pid = int(sys.argv[2])
session_id = sys.argv[3]
try:
    with open(state_file) as f:
        state = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    state = {}
state['pid'] = new_pid
state['claudeSessionId'] = session_id
state['status'] = 'running'
tmp = state_file + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, state_file)
PY
          log INFO "[$name] Detected new PID $pane_pid (was $current_state_pid)"
        fi

        alive=true
      fi
    fi

    if [ "$alive" = "true" ]; then
      continue
    fi

    # Session is dead — check crash loop
    if ! check_crash_loop "$name"; then
      log ERROR "[$name] Crash loop detected (≥$CRASH_THRESHOLD restarts in ${CRASH_WINDOW}s). Pausing."
      _JSON_INPUT="$state" python3 - "$STATE_DIR/$name.json" <<'PY'
import json, sys, os
try:
    d = json.loads(os.environ.get('_JSON_INPUT', '{}'))
except json.JSONDecodeError:
    d = {}
if not isinstance(d, dict): d = {}
d['paused'] = True
d['status'] = 'paused-crash-loop'
out = sys.argv[1]
tmp = out + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(d, f, indent=2)
os.replace(tmp, out)
PY
      continue
    fi

    # Kill leftover tmux session if exists but process dead
    tmux kill-session -t "$tmux_session" 2>/dev/null || true

    log WARN "[$name] Session is dead, restarting..."
    if ! start_session "$name" "$command" "$cwd" "$tmux_session" "$resumable"; then
      log ERROR "[$name] Failed to restart, will retry next cycle"
    fi
  done < <(list_sessions)

  # Log rotation
  find "$LOG_DIR" -name "*.log" -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null || true
}

main "$@"

#!/usr/bin/env node
// Claude Bot Dashboard — manage Claude Code bot sessions (Discord, Telegram, etc.)
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { exec, spawn } = require('child_process');

const PORT = process.env.PORT ? Number(process.env.PORT) : 7010;
const HOST = process.env.HOST || '0.0.0.0';
const TOKEN = process.env.TOKEN || '';
const MONITOR_DIR = process.env.MONITOR_DIR || path.join(process.env.HOME, '.claude/tmux-monitor');
const SETTINGS_PATH = process.env.CLAUDE_SETTINGS || path.join(process.env.HOME, '.claude/settings.json');
const STATE_DIR = process.env.STATE_DIR || path.join(process.env.HOME, '.claude/bot-dashboard');
const ERROR_LOG_PATH = path.join(STATE_DIR, 'error-log.json');

if (!TOKEN) {
  console.error('ERROR: TOKEN env var is required (access token for the web UI).');
  process.exit(1);
}

try { fs.mkdirSync(STATE_DIR, { recursive: true }); } catch {}

function respond(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(body);
}

function run(cmd) {
  return new Promise((resolve, reject) => {
    exec(cmd, (err, stdout, stderr) => {
      if (err) return reject(new Error(`${err.message}\n${stderr || ''}`));
      resolve(stdout || '');
    });
  });
}

// Strict error patterns — only match actual error output lines, not conversation text.
// Each entry: { pattern, key, label }
// pattern must match lines that are clearly machine/system output, not natural language.
const ERROR_RULES = [
  // Auth — only match Claude Code's specific output format
  { pattern: /^.*Please run \/login.*API Error: 401/, key: 'auth_401', label: 'Auth failed (401)' },
  { pattern: /^\s*\⎿\s+Please run \/login/, key: 'auth_401', label: 'Auth failed (401)' },
  { pattern: /"type"\s*:\s*"authentication_error"/, key: 'auth_401', label: 'Auth failed (401)' },
  // Rate limit — match JSON error or Claude Code formatted output
  { pattern: /"type"\s*:\s*"rate_limit_error"/, key: 'rate_limit', label: 'Rate limited (429)' },
  { pattern: /API Error: 429/, key: 'rate_limit', label: 'Rate limited (429)' },
  { pattern: /quota exceeded/i, key: 'rate_limit', label: 'Quota exceeded' },
  { pattern: /billing hard limit/i, key: 'rate_limit', label: 'Billing hard limit' },
  // Overload
  { pattern: /"type"\s*:\s*"overloaded_error"/, key: 'overloaded', label: 'API overloaded' },
  { pattern: /API Error: 529/, key: 'overloaded', label: 'API overloaded (529)' },
  // Context
  { pattern: /maximum context length exceeded/i, key: 'context_full', label: 'Context full' },
  { pattern: /context window is full/i, key: 'context_full', label: 'Context full' },
  // Network — only bare error lines, not in sentences
  { pattern: /^.*Error:.*ECONNREFUSED/, key: 'network', label: 'Connection refused' },
  { pattern: /^.*Error:.*ETIMEDOUT/, key: 'network', label: 'Connection timeout' },
  { pattern: /^.*Error:.*socket hang up/, key: 'network', label: 'Socket hang up' },
  // Discord connection
  { pattern: /WebSocket connection.*closed/i, key: 'channel_disconnect', label: 'Channel disconnected' },
  { pattern: /Discord.*gateway.*disconnect/i, key: 'channel_disconnect', label: 'Discord disconnected' },
  // Telegram connection
  { pattern: /Telegram.*polling.*failed/i, key: 'channel_disconnect', label: 'Telegram disconnected' },
  { pattern: /telegram.*bot.*(conflict|terminated)/i, key: 'channel_disconnect', label: 'Telegram bot conflict' },
  // Crash loop — from monitor state
  { pattern: /paused-crash-loop/, key: 'crash_loop', label: 'Crash loop paused' },
  { pattern: /Crash loop detected/, key: 'crash_loop', label: 'Crash loop detected' },
  // Hook
  { pattern: /^\s*\⎿\s+Stop hook error:/, key: 'stop_hook', label: 'Stop hook error' },
  { pattern: /^Stop hook error:/, key: 'stop_hook', label: 'Stop hook error' },
  // Update
  { pattern: /Auto-update failed/i, key: 'update_fail', label: 'Auto-update failed' },
];

// Lines from Claude's conversation output (Chinese text, markdown, etc.) should be skipped
function isConversationLine(line) {
  // Skip lines that are clearly natural language / markdown / Claude output
  if (/^[⏺✻✶✢✳·←]/.test(line)) return true;  // Claude Code UI markers
  if (/^\s*[-*]\s+\*\*/.test(line)) return true;  // Markdown bold lists
  if (/[\u4e00-\u9fff]{3,}/.test(line) && !/Error|error|失败/.test(line)) return true;  // Chinese text without error keywords
  if (/^(改动|建议|新增|当前|关于|方案|确认|补上)/.test(line)) return true;  // Chinese conversation starters
  if (/^\s*```/.test(line)) return true;  // Code blocks
  if (/^\s*\d+\.\s+/.test(line)) return true;  // Numbered lists
  return false;
}

function loadErrorLog() {
  try {
    return JSON.parse(fs.readFileSync(ERROR_LOG_PATH, 'utf8'));
  } catch {
    return {};
  }
}

function saveErrorLog(log) {
  const tmp = ERROR_LOG_PATH + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(log, null, 2));
  fs.renameSync(tmp, ERROR_LOG_PATH);
}

function resetErrorLog(session) {
  const log = loadErrorLog();
  if (session === 'all') {
    saveErrorLog({});
  } else if (log[session]) {
    delete log[session];
    saveErrorLog(log);
  }
}

const MAX_ERRORS_PER_SESSION = 10;

function updateErrorLog(session, currentErrors) {
  const log = loadErrorLog();
  if (!log[session]) log[session] = {};
  const now = new Date().toISOString();

  // Mark existing active errors as resolved if no longer seen
  for (const [key, entry] of Object.entries(log[session])) {
    if (!entry.resolved && !currentErrors.has(key)) {
      entry.resolved = now;
    }
  }

  // Update or add current errors
  for (const [key, { label, sample }] of currentErrors) {
    if (!log[session][key]) {
      log[session][key] = { firstSeen: now, lastSeen: now, label, sample, resolved: null };
    } else {
      log[session][key].lastSeen = now;
      log[session][key].sample = sample;
      log[session][key].label = label;
      log[session][key].resolved = null;
    }
  }

  // Prune: resolved errors older than 24h, keep at most MAX_ERRORS_PER_SESSION
  const cutoff = Date.now() - 24 * 60 * 60 * 1000;
  for (const [key, entry] of Object.entries(log[session])) {
    if (entry.resolved && new Date(entry.resolved).getTime() < cutoff) {
      delete log[session][key];
    }
  }
  // If still too many, keep only the newest
  const entries = Object.entries(log[session]);
  if (entries.length > MAX_ERRORS_PER_SESSION) {
    entries.sort((a, b) => new Date(b[1].lastSeen) - new Date(a[1].lastSeen));
    log[session] = Object.fromEntries(entries.slice(0, MAX_ERRORS_PER_SESSION));
  }

  saveErrorLog(log);
  return log[session];
}

function formatTime(iso) {
  if (!iso) return '?';
  const d = new Date(iso);
  return d.toLocaleString('sv-SE', { timeZone: 'Asia/Shanghai', hour12: false }).slice(5, 16);
}

function formatSessionErrors(sessionLog) {
  const all = Object.values(sessionLog);
  if (all.length === 0) return '  (clean)';

  // Sort by time: active first (newest lastSeen first), then resolved (newest resolved first)
  const active = all.filter(e => !e.resolved).sort((a, b) => new Date(b.lastSeen) - new Date(a.lastSeen));
  const resolved = all.filter(e => e.resolved).sort((a, b) => new Date(b.resolved) - new Date(a.resolved));

  const lines = [];

  for (const e of active) {
    const duration = Math.round((Date.now() - new Date(e.firstSeen).getTime()) / 60000);
    const durStr = duration < 60 ? `${duration}m` : `${Math.floor(duration / 60)}h${duration % 60}m`;
    lines.push(`  ${formatTime(e.firstSeen)} * ${e.label} (active ${durStr})`);
    lines.push(`    ${e.sample}`);
  }

  for (const e of resolved) {
    lines.push(`  ${formatTime(e.firstSeen)} ok ${e.label} (resolved ${formatTime(e.resolved)})`);
  }

  return lines.join('\n');
}

function parseSessionMeta(pane) {
  // Parse effort level, context %, and cost from Claude Code status bar
  // Format: "项目 │ Opus 4.6 (1M context) (high) │ 13% │ $4.75"
  const lines = pane.split('\n');
  let effort = '-';
  let effortFromScrollback = '';
  let context = '-';
  let cost = '-';
  let mode = '-';
  let busy = false;

  for (const line of lines) {
    // Effort: (high), (max), (medium), (low) after "context)"
    const effortMatch = line.match(/context\)\s*\((\w+)\)/);
    if (effortMatch) effort = effortMatch[1];

    // Detect /effort command output in scrollback (overrides status bar)
    // "Set effort level to max (this session only)..." or "Current effort level: max ..."
    const setMatch = line.match(/Set effort level to (\w+)/);
    if (setMatch) effortFromScrollback = setMatch[1];
    const curMatch = line.match(/Current effort level:\s*(\w+)/);
    if (curMatch) effortFromScrollback = curMatch[1];

    // Context percentage — handles multiple formats:
    // Built-in: "│ 49% │", Custom new: "│ 49%", Custom old: "| ctx: 49%"
    const ctxMatch = line.match(/[│|]\s*(?:ctx:\s*)?(\d+%)\s*(?:[│|]|$|\s)/);
    if (ctxMatch) context = ctxMatch[1];

    // Cost — "$4.75" or "20c" format, handles both │ and | separators
    const costMatch = line.match(/[│|]\s*(\$[\d.]+|\d+c)\b/);
    if (costMatch) cost = costMatch[1];

    // Permission mode
    if (/bypass permissions on/.test(line)) mode = 'bypass';
    else if (/accept edits on/.test(line)) mode = 'accept-edits';
    else if (/plan mode on/.test(line)) mode = 'plan';
  }

  // Scrollback /effort output takes precedence over status bar
  if (effortFromScrollback) effort = effortFromScrollback;

  // Detect busy state: look for Claude Code task spinner in last 30 lines
  // Spinner pattern: "✽ taskname… (21s · tokens)" or "(thought for Xs)" or "(Xm Ys · ...)"
  const tail = lines.slice(-30);
  for (const line of tail) {
    if (/[✽✳✶✢✱⠏⠋⠙⠹·]\s.*…\s*\(\d+[sm]/.test(line) ||
        /\((?:thought for|Cooked for|Crunched for|Hyperspacing|Flibbertigibbeting)/i.test(line)) {
      busy = true;
      break;
    }
  }

  return { effort, context, cost, mode, busy };
}

function _getDefaultEffort() {
  try {
    const settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
    return settings.effortLevel || 'high';
  } catch { return 'high'; }
}

async function getTmuxStatusReport() {
  const defaultEffort = _getDefaultEffort();
  const statusOutput = await run(`bash -lc 'bash "${MONITOR_DIR}/ctl.sh" status'`);

  // Parse session names and statuses from status output.
  // Defense in depth: session names get interpolated into tmux commands later,
  // so enforce the same character whitelist as user-facing API endpoints.
  const NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/;
  const sessions = [];
  const sessionStatuses = {};
  for (const line of statusOutput.split('\n')) {
    const match = line.match(/^(\S+)\s+(\S*?(?:running|dead|disabled|paused|unknown)\S*)/);
    if (match && match[1] !== 'NAME' && match[1] !== '----' && NAME_RE.test(match[1])) {
      sessions.push(match[1]);
      sessionStatuses[match[1]] = match[2];
    }
  }

  const metaLines = [];
  const errorSections = [];
  const sessionData = [];

  metaLines.push(padRow('SESSION', 'EFFORT', 'CTX', 'COST', 'MODE'));
  metaLines.push(padRow('-------', '------', '---', '----', '----'));

  for (const session of sessions) {
    let pane = '';
    try {
      pane = await run(`tmux capture-pane -t "${session}" -p -S -120 2>/dev/null || true`);
    } catch { /* ignore */ }

    // Parse metadata from status bar + scrollback
    const meta = parseSessionMeta(pane);

    // tmux env var takes highest precedence for effort (set by /high /max pseudo commands)
    try {
      const envOut = await run(`tmux show-environment -t "${session}" CLAUDE_EFFORT 2>/dev/null || true`);
      const envMatch = envOut.match(/^CLAUDE_EFFORT=(\w+)/);
      if (envMatch) meta.effort = envMatch[1];
    } catch { /* ignore */ }

    // Fall back to settings.json default when effort is still unknown
    if (meta.effort === '-') meta.effort = defaultEffort;

    metaLines.push(padRow(session, meta.effort, meta.context, meta.cost, meta.mode));
    sessionData.push({
      name: session,
      status: sessionStatuses[session] || 'unknown',
      busy: meta.busy,
      effort: meta.effort,
      context: meta.context,
      cost: meta.cost,
      mode: meta.mode,
    });

    // Find matching error lines
    const currentErrors = new Map();
    for (const line of pane.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      if (isConversationLine(trimmed)) continue;
      for (const rule of ERROR_RULES) {
        if (rule.pattern.test(trimmed)) {
          if (!currentErrors.has(rule.key)) {
            currentErrors.set(rule.key, { label: rule.label, sample: trimmed.slice(0, 120) });
          }
          break;
        }
      }
    }

    const sessionLog = updateErrorLog(session, currentErrors);
    const errText = formatSessionErrors(sessionLog);
    if (errText !== '  (clean)') {
      errorSections.push(`[${session}]\n${errText}`);
    }
  }

  let output = `TMUX_STATUS\n${statusOutput}\nSESSION_INFO\n${metaLines.join('\n')}`;
  if (errorSections.length > 0) {
    output += `\n\nERROR_LOG\n${errorSections.join('\n\n')}`;
  } else {
    output += '\n\nERROR_LOG\n(all clean)';
  }
  return { text: output, sessions: sessionData, statusOutput, errorSections };
}

function padRow(session, effort, ctx, cost, mode) {
  return `${session.padEnd(22)} ${effort.padEnd(8)} ${ctx.padEnd(5)} ${cost.padEnd(8)} ${mode}`;
}

function renderTmuxStatusHTML(data, token) {
  const { sessions, statusOutput, errorSections } = data;
  const escHtml = s => String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');

  const renderEffortCell = (name, effort) => {
    const levels = ['high', 'xhigh', 'max'];
    return levels.map(l => {
      const cls = l === effort ? 'effort-active' : 'effort-opt';
      return `<span class="${cls}" onclick="setEffort('${escHtml(name)}','${l}')">${l}</span>`;
    }).join(' ');
  };

  const renderStatus = s => {
    if (s.status === 'running') {
      return s.busy
        ? `<span class="amber">running · busy</span>`
        : `<span class="green">running · idle</span>`;
    }
    const resetBtn = s.status.startsWith('paused')
      ? ` <button class="reset-btn" onclick="resetSession('${escHtml(s.name)}')">[RESET]</button>`
      : '';
    return `<span class="red">${escHtml(s.status)}</span>${resetBtn}`;
  };

  const renderActions = s => {
    const dis = s.status !== 'running' ? 'disabled' : '';
    return `<span class="actions">
      <button onclick="sendKeys('${escHtml(s.name)}','esc')" ${dis}>[ESC]</button>
      <button onclick="sendKeys('${escHtml(s.name)}','compact')" ${dis}>[COMPACT]</button>
      <button onclick="sendKeys('${escHtml(s.name)}','clear')" ${dis}>[CLEAR]</button>
      <button onclick="restartBot('${escHtml(s.name)}')" ${s.status === 'disabled' ? 'disabled' : ''}>[RESTART]</button>
    </span>`;
  };

  const rows = sessions.map(s => {
    return `<tr>
      <td data-label="session">${escHtml(s.name)}</td>
      <td data-label="status">${renderStatus(s)}</td>
      <td data-label="effort">${renderEffortCell(s.name, s.effort)}</td>
      <td data-label="ctx">${escHtml(s.context)}</td>
      <td data-label="cost">${escHtml(s.cost)}</td>
      <td data-label="mode">${escHtml(s.mode)}</td>
      <td>${renderActions(s)}</td>
    </tr>`;
  }).join('\n');

  const errText = errorSections.length > 0
    ? escHtml(errorSections.join('\n\n'))
    : '(all clean)';

  return `<!DOCTYPE html>
<html><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Bot Dashboard</title>
<style>
  :root {
    --bg: #1a1a1a; --bg-alt: #111; --fg: #ccc; --fg-dim: #888; --fg-faint: #555;
    --border: #333; --accent: #7fdbca; --red: #ef5350; --amber: #dda20a;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #f5f5f5; --bg-alt: #eaeaea; --fg: #222; --fg-dim: #666; --fg-faint: #aaa;
      --border: #ddd; --accent: #0e7a6b; --red: #c62828; --amber: #b8860b;
    }
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { background: var(--bg); color: var(--fg); font-family: 'SF Mono', 'Menlo', 'Monaco', monospace; font-size: 13px; padding: 16px; }
  h1 { color: var(--fg); font-size: 18px; margin: 0 0 20px; font-weight: normal; letter-spacing: 0.5px; }
  h2 { color: var(--accent); font-size: 14px; margin: 16px 0 8px; font-weight: normal; }
  h2:first-child { margin-top: 0; }
  table { border-collapse: collapse; width: 100%; }
  th { color: var(--accent); text-align: left; padding: 10px 12px 10px 0; border-bottom: 1px solid var(--border); font-weight: normal; }
  td { padding: 10px 12px 10px 0; border-bottom: 1px solid var(--border); white-space: nowrap; }
  .green { color: var(--accent); }
  .red { color: var(--red); }
  .amber { color: var(--amber); }
  button {
    background: none; border: none; color: var(--fg-dim); font-family: inherit; font-size: 12px;
    padding: 2px 8px; cursor: pointer;
  }
  button:hover { color: var(--accent); }
  button:disabled { opacity: 0.3; cursor: not-allowed; }
  button.restarting { color: var(--amber); }
  .effort-opt { color: var(--fg-faint); cursor: pointer; user-select: none; padding: 0 2px; }
  .effort-opt:hover { color: var(--accent); }
  .effort-active { color: var(--accent); padding: 0 2px; font-weight: bold; }
  .actions { display: inline-flex; gap: 2px; flex-wrap: nowrap; }
  .actions button { padding: 2px 4px; }
  .reset-btn { color: var(--amber); padding: 2px 4px; margin-left: 4px; }
  .reset-btn:hover { color: var(--accent); }
  #log-area {
    background: var(--bg-alt); border: none; padding: 12px; margin-top: 8px;
    min-height: 60px; max-height: 400px; overflow-y: auto; white-space: pre-wrap; font-size: 12px;
    color: var(--fg-dim);
  }
  #log-area .info { color: var(--fg); }
  #log-area .ok { color: var(--accent); }
  #log-area .err { color: var(--red); }
  #log-area .ts { color: var(--fg-faint); }
  .err-active { color: var(--red); }
  .err-resolved { color: var(--fg-faint); }
  #refresh-bar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
  #refresh-bar button { font-size: 13px; }
  #auto-refresh { color: var(--fg-faint); font-size: 11px; }

  @media (max-width: 640px) {
    body { padding: 12px; font-size: 13px; }
    table, thead, tbody, tr, td { display: block; width: 100%; }
    thead { display: none; }
    tr { border-bottom: 1px solid var(--border); padding: 10px 0; }
    td { border-bottom: none; padding: 4px 0; white-space: normal; display: flex; justify-content: space-between; align-items: center; gap: 12px; }
    td:first-child { color: var(--accent); font-weight: bold; padding-bottom: 6px; }
    td:first-child::before { content: none; }
    td::before { content: attr(data-label); color: var(--fg-faint); font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; flex-shrink: 0; }
    td:last-child { justify-content: flex-end; }
    td:last-child::before { content: none; }
  }
</style>
</head><body>
<h1>Claude Bot Dashboard</h1>
<div id="refresh-bar">
  <h2>SESSION_INFO</h2>
  <div><span id="auto-refresh"></span> <button onclick="refreshTable()">[REFRESH]</button></div>
</div>
<table>
  <thead><tr><th>SESSION</th><th>STATUS</th><th>EFFORT</th><th>CTX</th><th>COST</th><th>MODE</th><th></th></tr></thead>
  <tbody id="session-tbody">${rows}</tbody>
</table>

<h2>LOG</h2>
<div id="log-area"></div>

<h2>ERROR_LOG</h2>
<pre id="error-log" style="color:var(--fg-dim); font-size:12px; line-height:1.6;">${errText}</pre>

<script>
const TOKEN = '${escHtml(token)}';
const logEl = document.getElementById('log-area');
const LOG_KEY = 'tmux-status-logs';
const LOG_TTL = 24 * 60 * 60 * 1000;

function loadLogs() {
  try {
    const entries = JSON.parse(localStorage.getItem(LOG_KEY) || '[]');
    const cutoff = Date.now() - LOG_TTL;
    return entries.filter(e => e.t > cutoff);
  } catch { return []; }
}

function saveLogs(entries) {
  const cutoff = Date.now() - LOG_TTL;
  const pruned = entries.filter(e => e.t > cutoff);
  try { localStorage.setItem(LOG_KEY, JSON.stringify(pruned)); } catch {}
}

function renderLogs() {
  logEl.innerHTML = '';
  const entries = loadLogs();
  if (entries.length === 0) {
    logEl.textContent = 'No recent logs.';
    return;
  }
  for (const e of entries) {
    const tsSpan = document.createElement('span');
    tsSpan.className = 'ts';
    const d = new Date(e.t);
    tsSpan.textContent = '[' + d.toLocaleDateString('en-GB',{month:'2-digit',day:'2-digit'}) + ' ' + d.toLocaleTimeString('en-GB',{hour12:false}) + '] ';
    const span = document.createElement('span');
    span.className = e.c || 'info';
    span.textContent = e.m + '\\n';
    logEl.appendChild(tsSpan);
    logEl.appendChild(span);
  }
  logEl.scrollTop = logEl.scrollHeight;
}

function appendLog(text, cls) {
  const entries = loadLogs();
  entries.push({ t: Date.now(), m: text, c: cls || 'info' });
  saveLogs(entries);
  const tsSpan = document.createElement('span');
  tsSpan.className = 'ts';
  const d = new Date();
  tsSpan.textContent = '[' + d.toLocaleDateString('en-GB',{month:'2-digit',day:'2-digit'}) + ' ' + d.toLocaleTimeString('en-GB',{hour12:false}) + '] ';
  const span = document.createElement('span');
  span.className = cls || 'info';
  span.textContent = text + '\\n';
  logEl.appendChild(tsSpan);
  logEl.appendChild(span);
  logEl.scrollTop = logEl.scrollHeight;
}

renderLogs();

function escHtml(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }

function buildEffortCell(name, effort) {
  return ['high','xhigh','max'].map(l => {
    const cls = l === effort ? 'effort-active' : 'effort-opt';
    return '<span class="' + cls + '" onclick="setEffort(\\'' + escHtml(name) + '\\',\\'' + l + '\\')">' + l + '</span>';
  }).join(' ');
}

function buildStatus(s) {
  if (s.status === 'running') {
    return s.busy
      ? '<span class="amber">running · busy</span>'
      : '<span class="green">running · idle</span>';
  }
  const resetBtn = String(s.status).startsWith('paused')
    ? ' <button class="reset-btn" onclick="resetSession(\\'' + escHtml(s.name) + '\\')">[RESET]</button>'
    : '';
  return '<span class="red">' + escHtml(s.status) + '</span>' + resetBtn;
}

function buildActions(s) {
  const dis = s.status !== 'running' ? 'disabled' : '';
  const restartDis = s.status === 'disabled' ? 'disabled' : '';
  const n = escHtml(s.name);
  return '<span class="actions">'
    + '<button onclick="sendKeys(\\'' + n + '\\',\\'esc\\')" ' + dis + '>[ESC]</button>'
    + '<button onclick="sendKeys(\\'' + n + '\\',\\'compact\\')" ' + dis + '>[COMPACT]</button>'
    + '<button onclick="sendKeys(\\'' + n + '\\',\\'clear\\')" ' + dis + '>[CLEAR]</button>'
    + '<button onclick="restartBot(\\'' + n + '\\')" ' + restartDis + '>[RESTART]</button>'
    + '</span>';
}

function buildRow(s) {
  return '<tr>'
    + '<td data-label="session">' + escHtml(s.name) + '</td>'
    + '<td data-label="status">' + buildStatus(s) + '</td>'
    + '<td data-label="effort">' + buildEffortCell(s.name, s.effort) + '</td>'
    + '<td data-label="ctx">' + escHtml(s.context) + '</td>'
    + '<td data-label="cost">' + escHtml(s.cost) + '</td>'
    + '<td data-label="mode">' + escHtml(s.mode) + '</td>'
    + '<td>' + buildActions(s) + '</td>'
    + '</tr>';
}

async function sendKeys(name, action) {
  const msgs = { esc: 'Send ESC to', compact: 'Send /compact to', clear: 'Send /clear to' };
  if (!confirm(msgs[action] + '\\n\\n  ' + name + '\\n\\nConfirm?')) return;
  appendLog(name + ' <- ' + action + '...', 'info');
  try {
    const res = await fetch('/api/send-keys?token=' + TOKEN + '&name=' + encodeURIComponent(name) + '&action=' + action, { method: 'POST' });
    const text = await res.text();
    appendLog(text, res.ok ? 'ok' : 'err');
    if (res.ok) setTimeout(refreshTable, 1500);
  } catch (e) {
    appendLog('Error: ' + e.message, 'err');
  }
}

async function setEffort(name, level) {
  appendLog('Setting ' + name + ' effort to ' + level + '...', 'info');
  try {
    const res = await fetch('/api/set-effort?token=' + TOKEN + '&name=' + encodeURIComponent(name) + '&level=' + level, { method: 'POST' });
    const text = await res.text();
    appendLog(text, res.ok ? 'ok' : 'err');
    if (res.ok) refreshTable();
  } catch (e) {
    appendLog('Error: ' + e.message, 'err');
  }
}

async function refreshTable() {
  try {
    const res = await fetch('/api/sessions?token=' + TOKEN);
    const data = await res.json();
    document.getElementById('session-tbody').innerHTML = data.sessions.map(buildRow).join('');
    document.getElementById('error-log').textContent = data.errors.length > 0 ? data.errors.join('\\n\\n') : '(all clean)';
    countdown = REFRESH_INTERVAL;
  } catch {}
}

let restartInProgress = false;

async function restartBot(name) {
  if (!confirm('Restart session\\n\\n  ' + name + '\\n\\nConfirm?')) return;
  const btn = event.target;
  btn.disabled = true;
  btn.className = 'restarting';
  btn.textContent = '[...]';
  restartInProgress = true;
  appendLog('Restarting ' + name + '...', 'info');

  try {
    const res = await fetch('/api/restart-bot?token=' + TOKEN + '&name=' + encodeURIComponent(name), { method: 'POST' });
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\\n');
      buffer = lines.pop();
      for (const line of lines) {
        if (line.trim()) appendLog(line, line.includes('FAILED') || line.includes('error') ? 'err' : 'info');
      }
    }
    if (buffer.trim()) appendLog(buffer, buffer.includes('FAILED') ? 'err' : 'info');

    appendLog(name + ' restart complete.', res.ok ? 'ok' : 'err');
  } catch (e) {
    appendLog('Error: ' + e.message, 'err');
  }

  btn.disabled = false;
  btn.className = '';
  btn.textContent = '[RESTART]';
  restartInProgress = false;
  countdown = REFRESH_INTERVAL;
  refreshTable();
}

async function resetSession(name) {
  if (!confirm('Reset session (clears saved Claude session ID and starts fresh, losing previous context)\\n\\n  ' + name + '\\n\\nConfirm?')) return;
  restartInProgress = true;
  appendLog('Resetting ' + name + '...', 'info');
  try {
    const res = await fetch('/api/reset-session?token=' + TOKEN + '&name=' + encodeURIComponent(name), { method: 'POST' });
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\\n');
      buffer = lines.pop();
      for (const line of lines) {
        if (line.trim()) appendLog(line, line.includes('FAILED') || line.includes('failed') ? 'err' : 'info');
      }
    }
    if (buffer.trim()) appendLog(buffer, buffer.includes('FAILED') ? 'err' : 'info');
    appendLog(name + ' reset complete.', res.ok ? 'ok' : 'err');
  } catch (e) {
    appendLog('Error: ' + e.message, 'err');
  }
  restartInProgress = false;
  countdown = REFRESH_INTERVAL;
  refreshTable();
}

// Auto-refresh table every 5s (paused during restart)
const REFRESH_INTERVAL = 5;
let countdown = REFRESH_INTERVAL;
const cdEl = document.getElementById('auto-refresh');
setInterval(() => {
  if (restartInProgress) { cdEl.textContent = 'paused'; return; }
  countdown--;
  cdEl.textContent = 'refresh in ' + countdown + 's';
  if (countdown <= 0) { countdown = REFRESH_INTERVAL; refreshTable(); }
}, 1000);
</script>
</body></html>`;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const token = url.searchParams.get('token') || req.headers['x-token'];

  // Constant-time compare to resist timing attacks (cheap paranoia for LAN)
  const tokenBuf = Buffer.from(String(token || ''));
  const expectedBuf = Buffer.from(TOKEN);
  if (!TOKEN || tokenBuf.length !== expectedBuf.length ||
      !crypto.timingSafeEqual(tokenBuf, expectedBuf)) {
    return respond(res, 401, 'Unauthorized');
  }

  if (url.pathname === '/ping') {
    return respond(res, 200, 'PONG');
  }

  if (url.pathname === '/tmux-status') {
    // ?reset=all or ?reset=discord-bot to clear error log
    const resetTarget = url.searchParams.get('reset');
    if (resetTarget) {
      resetErrorLog(resetTarget);
      return respond(res, 200, `ERROR_LOG_RESET: ${resetTarget}`);
    }
    // ?format=text for plain text (API consumers), otherwise HTML
    const wantsText = url.searchParams.get('format') === 'text';
    try {
      const data = await getTmuxStatusReport();
      if (wantsText) {
        return respond(res, 200, data.text);
      }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(renderTmuxStatusHTML(data, token));
    } catch (e) {
      return respond(res, 500, `TMUX_STATUS_FAILED\n${e.message}`);
    }
    return;
  }

  if (url.pathname === '/api/sessions') {
    try {
      const data = await getTmuxStatusReport();
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ sessions: data.sessions, errors: data.errorSections }));
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  if (url.pathname === '/api/send-keys' && req.method === 'POST') {
    const name = url.searchParams.get('name');
    const action = url.searchParams.get('action');
    if (!name || !/^[a-zA-Z0-9_-]+$/.test(name)) return respond(res, 400, 'Invalid session name');
    const actionMap = {
      esc: ['Escape'],
      compact: ['/compact', 'Enter'],
      clear: ['/clear', 'Enter'],
    };
    if (!actionMap[action]) return respond(res, 400, 'Invalid action');
    try {
      const keys = actionMap[action].map(k => `"${k}"`).join(' ');
      await run(`tmux send-keys -t "${name}" ${keys}`);
      return respond(res, 200, `OK ${name} <- ${action}`);
    } catch (e) {
      return respond(res, 500, `FAILED: ${e.message}`);
    }
  }

  if (url.pathname === '/api/set-effort' && req.method === 'POST') {
    const name = url.searchParams.get('name');
    const level = url.searchParams.get('level');
    if (!name || !/^[a-zA-Z0-9_-]+$/.test(name)) return respond(res, 400, 'Invalid session name');
    if (!['high', 'xhigh', 'max'].includes(level)) return respond(res, 400, 'Invalid level');
    try {
      await run(`tmux send-keys -t "${name}" "/effort ${level}" Enter`);
      await run(`tmux set-environment -t "${name}" CLAUDE_EFFORT ${level}`);
      return respond(res, 200, `OK ${name} -> ${level}`);
    } catch (e) {
      return respond(res, 500, `FAILED: ${e.message}`);
    }
  }

  if (url.pathname === '/api/reset-session' && req.method === 'POST') {
    const name = url.searchParams.get('name');
    if (!name || !/^[a-zA-Z0-9_-]+$/.test(name)) return respond(res, 400, 'Invalid session name');
    const statePath = path.join(MONITOR_DIR, 'state', `${name}.json`);
    res.writeHead(200, {
      'Content-Type': 'text/plain; charset=utf-8',
      'Transfer-Encoding': 'chunked',
    });
    try {
      const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
      delete state.claudeSessionId;
      state.paused = false;
      state.restartCount = 0;
      state.restartTimestamps = [];
      state.status = 'unknown';
      const tmp = statePath + '.tmp.' + process.pid;
      fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
      fs.renameSync(tmp, statePath);
      res.write(`State cleared (claudeSessionId removed, unpaused).\n`);
    } catch (e) {
      res.write(`State reset failed: ${e.message}\n`);
      res.end();
      return;
    }

    const child = spawn('bash', [
      path.join(MONITOR_DIR, 'ctl.sh'),
      'restart', name,
    ], { env: { ...process.env, TERM: 'dumb' } });
    child.stdout.on('data', chunk => res.write(chunk));
    child.stderr.on('data', chunk => res.write(chunk));
    child.on('close', code => {
      res.write(code === 0 ? `\n[exit: 0]\n` : `\n[exit: ${code}]\n`);
      res.end();
    });
    child.on('error', err => {
      res.write(`\nspawn error: ${err.message}\n`);
      res.end();
    });
    return;
  }

  if (url.pathname === '/api/restart-bot' && req.method === 'POST') {
    const name = url.searchParams.get('name');
    if (!name || !/^[a-zA-Z0-9_-]+$/.test(name)) {
      return respond(res, 400, 'Invalid session name');
    }
    res.writeHead(200, {
      'Content-Type': 'text/plain; charset=utf-8',
      'Transfer-Encoding': 'chunked',
      'Cache-Control': 'no-cache',
    });

    const child = spawn('bash', [
      path.join(MONITOR_DIR, 'ctl.sh'),
      'restart', name,
    ], { env: { ...process.env, TERM: 'dumb' } });

    child.stdout.on('data', chunk => res.write(chunk));
    child.stderr.on('data', chunk => res.write(chunk));
    child.on('close', code => {
      res.write(code === 0 ? `\n[exit: 0]\n` : `\n[exit: ${code}]\n`);
      res.end();
    });
    child.on('error', err => {
      res.write(`\nspawn error: ${err.message}\n`);
      res.end();
    });
    return;
  }

  respond(res, 404, 'Not Found');
});

server.listen(PORT, HOST, () => {
  console.log(`Claude Bot Dashboard listening on http://${HOST}:${PORT}`);
  console.log(`- /tmux-status?token=...           (web UI)`);
  console.log(`- /api/sessions?token=...          (JSON)`);
  console.log(`- /api/restart-bot?token=&name=    (POST)`);
  console.log(`- /api/reset-session?token=&name=  (POST, clears saved sessionId then restarts)`);
  console.log(`- /api/send-keys?token=&name=&action=esc|compact|clear  (POST)`);
  console.log(`- /api/set-effort?token=&name=&level=high|xhigh|max     (POST)`);
  console.log(`- MONITOR_DIR: ${MONITOR_DIR}`);
});

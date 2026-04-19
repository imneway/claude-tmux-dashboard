# Claude Bot Dashboard

A zero-dependency web dashboard + tmux session monitor for Claude Code bots.

Works with any Claude Code channel plugin — **Discord, Telegram, or custom** — as long as each bot runs in its own tmux session.

## What you get

- **Web UI** — list all your bot sessions, see live status (running/idle/busy), context%, cost, thinking effort, and permission mode.
- **One-click actions per session** — `[ESC]`, `[COMPACT]`, `[CLEAR]`, `[RESTART]` (with confirmation dialogs and streaming logs).
- **Effort switcher** — toggle `high` / `xhigh` / `max` inline.
- **tmux monitor** — launchd agent polls every 60s, auto-restarts dead Claude sessions with `claude --resume <id>` so conversation context survives crashes.
- **Crash-loop detection** — pauses restart after repeated failures so you can investigate instead of burning API calls.
- **Error log** — surfaces recurring problems (401 auth, 429 rate limit, context full, stop-hook errors, etc.) with active/resolved history.
- **Channel-agnostic** — detects Discord and Telegram disconnect patterns out of the box; easy to extend.
- **Responsive** — table on desktop, card layout on mobile.
- **Auto dark/light mode** — follows `prefers-color-scheme`.

## Requirements

- macOS (uses `launchd`; Linux/systemd support would be a small fork)
- `tmux`, Node.js ≥ 18, Python 3, `openssl`
- [Claude Code](https://claude.com/claude-code) installed, with whichever channel plugin you use

## Install

```bash
git clone https://github.com/<you>/claude-bot-dashboard.git
cd claude-bot-dashboard
./install.sh
```

That's it. The script:

1. Installs the tmux-monitor launchd agent (`com.claude.tmux-monitor`).
2. Installs the dashboard launchd agent (`com.claude.bot-dashboard`).
3. Generates a random access token and saves it to `~/.claude/bot-dashboard/token`.
4. Prints the URL to open.

Optional flags:

```bash
./install.sh --port 8080 --token your-existing-token
```

Rerun `./install.sh` any time to upgrade or refresh the launchd plists.

## Configure your bot sessions

Edit `~/.claude/tmux-monitor/sessions.json` to declare what the monitor should watch. Example with both a Discord and a Telegram bot:

```json
{
  "discord-bot": {
    "command": "claude --dangerously-skip-permissions --channels plugin:discord@claude-plugins-official",
    "cwd": "/Users/you/code/project-a",
    "resumable": true,
    "enabled": true
  },
  "telegram-bot": {
    "command": "claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official",
    "cwd": "/Users/you/code/project-b",
    "resumable": true,
    "enabled": true
  }
}
```

The monitor starts/restarts these inside tmux sessions of the same name. The dashboard picks them up automatically on next refresh.

## Use it

Open the URL printed by `install.sh` (also saved at `~/.claude/bot-dashboard/token`):

```
http://<your-ip>:7010/tmux-status?token=<token>
```

### Web UI

| Column  | Meaning                                                                       |
|---------|-------------------------------------------------------------------------------|
| SESSION | tmux session name                                                             |
| STATUS  | `running · idle` / `running · busy` / `dead` / `disabled`                     |
| EFFORT  | Click `high` / `xhigh` / `max` to switch (persists via tmux env var)          |
| CTX     | Conversation context % (from Claude Code's statusline)                        |
| COST    | Cumulative API spend for the current session                                  |
| MODE    | Permission mode (`bypass` / `accept-edits` / `plan`)                          |
| Actions | `[ESC]` `[COMPACT]` `[CLEAR]` `[RESTART]` — all with confirmation dialogs     |

The table auto-refreshes every 5 seconds. Restart triggers pause auto-refresh and stream their output to the LOG panel (log is persisted in `localStorage` for 24 hours).

### HTTP API

All endpoints require `?token=<token>`.

| Method | Path                                              | Purpose                                         |
|--------|---------------------------------------------------|-------------------------------------------------|
| GET    | `/ping`                                           | Liveness check                                  |
| GET    | `/tmux-status`                                    | HTML dashboard (add `&format=text` for text)    |
| GET    | `/api/sessions`                                   | JSON with all session data                      |
| POST   | `/api/restart-bot?name=<session>`                 | Restart, stream log output                      |
| POST   | `/api/send-keys?name=<session>&action=esc\|compact\|clear` | Send key/slash command to a session    |
| POST   | `/api/set-effort?name=<session>&level=high\|xhigh\|max`   | Set thinking effort for a session      |

## How it works

```
┌─────────────────┐   HTTP    ┌─────────────────┐
│  Browser / API  │◄─────────►│  Dashboard (Node)│   ~/.claude/bot-dashboard/logs/
└─────────────────┘           └────┬────────────┘
                                   │ spawn ctl.sh
                                   ▼
                             ┌────────────────┐
                             │  ctl.sh +      │
                             │  monitor.sh    │   ~/.claude/tmux-monitor/
                             └────┬───────────┘
                                  │ tmux send-keys / new-session
                                  ▼
                            ┌─────────────────┐
                            │  tmux sessions  │
                            │  (Claude Code)  │
                            └─────────────────┘
```

- **monitor.sh** runs every 60s via launchd. For each enabled session in `sessions.json`, if tmux has no matching session it starts one, passing `--resume <lastSessionId>` so conversation context survives.
- **ctl.sh** is the CLI for ad-hoc `status`, `restart`, `pause`, `unpause`, and `logs`. The dashboard shells out to it.
- **server/index.js** is a single-file Node HTTP server (stdlib only) that renders the HTML and proxies the actions.

## Uninstall

```bash
./uninstall.sh
```

Removes both launchd agents. Your `sessions.json`, logs, and error history are kept (delete manually if you want a clean slate).

## Security notes

- The token is the only access control. Treat it like a password. Don't commit URLs with tokens, don't expose the dashboard to the public internet without putting it behind a VPN or reverse-proxy with additional auth.
- `/api/send-keys` and `/api/restart-bot` execute commands against your running Claude sessions. Anyone with the token can type `/clear` into your bot.
- Dashboard binds to `0.0.0.0` by default so you can reach it from phones on the same LAN. To restrict to local access, reinstall with `./install.sh --host 127.0.0.1`.

## License

MIT

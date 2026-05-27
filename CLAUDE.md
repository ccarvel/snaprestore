# snaprestore — Claude Code Context

## What this repo does

Two bash scripts and a Slack bot for managing DigitalOcean droplet snapshots cost-effectively: snapshot and delete when idle, restore when needed. A reserved IP stays assigned across the destroy/restore cycle so DNS and Cloudflare configs never change.

**Cost model:** ~$0.06/GB/month for snapshot storage vs $12–48+/month for a running droplet.

---

## Architecture

```
Local machine:
  do-snapshot.sh  ──►  doctl (context: snaprestore)  ──►  DO API
  do-restore.sh   ──►  doctl (context: snaprestore)  ──►  DO API

Slack bot (controller droplet at 104.236.56.16):
  Slack ──► Socket Mode WebSocket ──► bot.py ──► doctl ──► DO API
```

See `docs/snaprestore-viz.md` for full ASCII diagrams.

---

## Repo layout

```
do-snapshot.sh              # Bash — snapshot a droplet
do-restore.sh               # Bash — restore a droplet from snapshot
lib/
  bootstrap_sh.sh           # Shared Bash bootstrap (tool detection, auth)
  ui_sh.sh                  # fzf/gum TUI helpers
  ui_rich_py.py             # Rich Python UI helpers
slack-bot/
  bot.py                    # Slack Bolt async app (main implementation)
  pyproject.toml            # Python deps: slack-bolt, httpx, aiohttp
  manifest.yml              # Slack app manifest (paste at api.slack.com)
  .env.op.example           # Template for 1Password op:// references
  start.sh                  # Startup wrapper: op run → uv run bot.py
  systemd/
    do-snap-bot.service     # systemd unit for the controller droplet
  cloud-init/
    controller.yml          # Cloud-init for the controller droplet ⚠️ CONTAINS LIVE SECRETS
docs/
  setup.md                  # First-time setup guide (Parts 1–6)
  commands.md               # Day-to-day cheatsheet
  troubleshooting.md        # Organized by symptom
  setup-op-fix.md           # 1Password org account workaround
  snaprestore-viz.md        # Architecture diagrams
  slack-integration-options.md  # Free controller alternatives, Slack connection modes
  benchmarks-speed-tests.md     # Timing methodology and comparison table
  PARKING_LOT.md            # Feature backlog (checkbox items)
old_v1/                     # Original scripts preserved for reference
ai_status.json              # AI session handoff state
AI_WORK_LOG.md              # Per-session work log (prepend-only)
```

---

## Two distinct components — keep them separate

### 1. Bash scripts (`do-snapshot.sh`, `do-restore.sh`)

- Authenticated via **doctl context** named `snaprestore`
- `DOCTL_CONTEXT="snaprestore"` is set in the config block at the top of each script
- Run directly: `./do-snapshot.sh`, `./do-restore.sh`
- **Never wrap with `op run --env-file`** — injecting `DIGITALOCEAN_ACCESS_TOKEN` into the environment causes doctl to ignore `--context snaprestore` and use the injected token instead, which breaks auth silently if the tokens differ

### 2. Slack bot (`slack-bot/bot.py`)

- Authenticated via `op run --env-file=slack-bot/.env.op` which resolves `op://` paths from 1Password at runtime
- Runs on a dedicated controller droplet (`104.236.56.16`) as a systemd service (`do-snap-bot.service`)
- Uses Slack Bolt + Socket Mode (no public inbound port needed)
- `doctl` runs inside the bot as subprocesses using the `snaprestore` context (separate from the `op run` env)

---

## Security rules — non-negotiable

1. **Never stage or commit `slack-bot/cloud-init/controller.yml`** — it contains a live SSH public key and 1Password service account token once edited. It is always dirty; always skip it in `git add`.
2. **Never commit `slack-bot/.env.op`** — it contains live `op://` references. Only `.env.op.example` belongs in the repo.
3. **Never commit `.env`** — covered by `.gitignore` but worth stating explicitly.
4. **Before reading any config file a user shares, warn them to redact secrets first.**

---

## bot.py internals — key patterns

### Job lifecycle

Every slash command:
1. Calls `await ack()` immediately (Slack requires < 3 seconds)
2. Posts an initial thread message and captures `thread_ts`
3. Dispatches `asyncio.create_task(_snapshot_job(...))` or `_restore_job(...)`
4. All subsequent updates go to that thread via `thread_ts`

### Cancellation

- `_cancel_path(job_id)` → `~/.local/share/do-snap-bot/jobs/<job_id>.cancel`
- Long-running `run_doctl_long()` checks `_is_cancelled()` between heartbeats and kills the subprocess if set
- `/do-deploy-cancel <job-id>` creates the sentinel file

### Interactive confirmations (Block Kit buttons)

- `PENDING_CONFIRMATIONS: dict[str, dict]` — keyed by `conf_id`, holds an `asyncio.Event` and the resolved value
- `_ask_confirmation()` posts Block Kit buttons and `await asyncio.wait_for(event.wait(), timeout=120)`
- `@app.action()` handlers call `_resolve_confirmation()` which sets the event value and fires `.set()`
- Timeout defaults to 120 seconds; fallback behavior is stated in each call site
- Currently used for: shutdown-before-snapshot prompt, restart-after-snapshot prompt

### Long-running commands

`run_doctl_long()` polls `proc.wait()` with a timeout loop instead of `proc.communicate()`. This lets it post heartbeat messages every 2 minutes without cancellation issues. Use it for: snapshot creation, droplet creation, shutdown/power-off actions.

Use plain `run_doctl()` for quick reads: list droplets, list snapshots, get droplet details.

### Nginx welcome page on restore

`build_welcome_cloud_init()` generates a `#cloud-config` YAML that installs nginx with an HTML status page. `_restore_job()` writes it to a temp file and passes `--user-data-file` to `doctl compute droplet create`. The temp file is cleaned up in a `finally` block.

---

## 1Password secret paths (production)

All secrets live in the `CDS_Vault` vault under the `do-snap-bot` item:

| Secret | `op://` path |
|--------|-------------|
| Slack bot token | `op://CDS_Vault/do-snap-bot/slack-bot-token` |
| Slack app token | `op://CDS_Vault/do-snap-bot/slack-app-token` |
| Slack signing secret | `op://CDS_Vault/do-snap-bot/signing-secret` |
| DO API token (bot) | `op://CDS_Vault/do-snap-bot/do-token` |
| Allowed Slack user IDs | `op://CDS_Vault/do-snap-bot/allowed-users` |
| DO API token (scripts) | `op://CDS_Vault/DigitalOcean API Token snaprestore-scripts/credential` |

The controller droplet's service account token lives in `/etc/do-snap-bot/env` (mode 0600, owned `dosnap:dosnap`). **No quotes around the value** — systemd `EnvironmentFile` parses them literally.

---

## doctl token scopes

Both the scripts token and the bot token need all of these:

`droplet:read`, `droplet:create`, `droplet:update`, `droplet:delete`, `image:create`, `image:read`, `snapshot:read`, `snapshot:delete`, `ssh_key:read`, `reserved_ip:read`, `reserved_ip:update`, `action:read`

> The most common mistake: missing `image:create`. Without it, snapshot calls return a silent 403.

---

## Development workflow

### Run the bash scripts

```bash
./do-snapshot.sh --log snapshot.log
./do-restore.sh --log restore.log
./do-snapshot.sh --dry-run   # print operations without executing
```

### Run the Slack bot locally

```bash
cd slack-bot
cp .env.op.example .env.op
# update .env.op paths to match your vault
./start.sh
```

### Deploy the bot to the controller

```bash
# Sync code
rsync -av -e "ssh -i ~/.ssh/id_m3do" slack-bot/ dosnap@104.236.56.16:/opt/do-snap-bot/

# Restart service
ssh -i ~/.ssh/id_m3do root@104.236.56.16 "systemctl restart do-snap-bot"

# Verify
ssh -i ~/.ssh/id_m3do root@104.236.56.16 "systemctl status do-snap-bot --no-pager"
```

### Check bot logs

```bash
ssh -i ~/.ssh/id_m3do root@104.236.56.16 "tail -f /var/log/do-snap-bot.log"
```

> journald is not working on the controller; logs are redirected to `/var/log/do-snap-bot.log` via the systemd unit.

### Rotate a DO API token

```bash
# Update 1Password
op item edit "do-snap-bot" --vault CDS_Vault "do-token=dop_v1_NEW_TOKEN"

# Restart bot to pick up new token
ssh -i ~/.ssh/id_m3do root@104.236.56.16 "systemctl restart do-snap-bot"
```

---

## Adding a new Slack command

1. Register a new `@app.command("/do-something")` handler in `bot.py`
2. Add the command to `slack-bot/manifest.yml` under `slash_commands`
3. Re-install the Slack app: [api.slack.com/apps](https://api.slack.com/apps) → your app → **Slash Commands** → add it, or **From a manifest** → paste the updated `manifest.yml`
4. Deploy: `rsync` + `systemctl restart`

For commands that need interactive confirmation, follow the `_ask_confirmation()` / `PENDING_CONFIRMATIONS` / `@app.action()` pattern already in `bot.py`.

---

## Common pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `403 image:create` on snapshot | Token missing `image:create` scope | Recreate token with all 13 scopes; update 1Password; restart bot |
| `No accounts configured for use with 1Password CLI` | `OP_SERVICE_ACCOUNT_TOKEN` not in env, or has quotes around value | Check `/etc/do-snap-bot/env` — no quotes, mode 0600 |
| `"<vault>" isn't a vault in this account` | Service account doesn't have vault access | 1password.com → Developer → Service Accounts → grant read access |
| `uv: command not found` | uv installed to `/root/.local/bin`, not accessible by dosnap | `curl -LsSf https://astral.sh/uv/install.sh \| UV_INSTALL_DIR=/usr/local/bin sh` |
| Slack: "app did not respond" | Bot crashed or not running | Check `systemctl status do-snap-bot` and `/var/log/do-snap-bot.log` |
| doctl ignores `--context snaprestore` | `DIGITALOCEAN_ACCESS_TOKEN` set in environment | Never use `op run` with the bash scripts |
| cloud-init YAML parse failure | Non-ASCII characters (em dashes, box-drawing) in `controller.yml` | `LC_ALL=C grep -n '[^ -~]' controller.yml` to find them |

Full troubleshooting: `docs/troubleshooting.md`

---

## AI session handoff

- `ai_status.json` — current focus, exact next step, open tasks, blockers
- `AI_WORK_LOG.md` — prepend-only session log

Run `/relay-handoff` at the end of any session to update both files and push.

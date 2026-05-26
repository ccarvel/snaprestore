# DigitalOcean Snapshot Scripts

Two companion scripts for managing DigitalOcean droplet snapshots: create a snapshot from a running droplet, then restore a new droplet from that snapshot. Designed for cost-effective on-demand usage — snapshot and delete when idle, restore when needed, with the same reserved IP so DNS and Cloudflare configs remain valid.

**Full setup guide (new users start here):** [`docs/setup-cc.md`](docs/setup-cc.md)

## Scripts

| Script | Purpose |
|--------|---------|
| `do-snapshot.sh` | Snapshot an existing droplet, then start / leave / delete it |
| `do-restore.sh` | Create a new droplet from a snapshot and assign a reserved IP |

---

## Requirements

### Required

| Tool | Purpose | Install |
|------|---------|---------|
| `doctl` | DigitalOcean CLI — replaces all raw API calls | `brew install doctl` |
| `jq` | JSON parsing for doctl output | `brew install jq` |

### Optional

| Tool | Purpose | Install |
|------|---------|---------|
| `fzf` | Arrow-key selection menus (falls back to numbered menus) | `brew install fzf` |
| `1password-cli` | Secure token injection via `op read` | `brew install 1password-cli` |

### Ubuntu/Debian equivalents

```bash
# doctl — download the binary directly (no apt package)
curl -sL https://github.com/digitalocean/doctl/releases/latest/download/doctl-*-linux-amd64.tar.gz \
  | tar -xz && sudo mv doctl /usr/local/bin

sudo apt install jq fzf
```

---

## One-Time Setup

### 1. Authenticate doctl

```bash
doctl auth init --context snaprestore
# Paste your DigitalOcean API token when prompted.
# The token is stored in ~/.config/doctl/config.yaml (mode 0600).
# It is never written to a script file or shell history.
```

Set the context name in both scripts:

```bash
DOCTL_CONTEXT="snaprestore"   # in do-snapshot.sh and do-restore.sh config block
```

### 2. (Optional) 1Password integration

Store your token in 1Password, then set `OP_ITEM` in the config block:

```bash
OP_ITEM="op://Private/DigitalOcean API Token/credential"
```

Create the vault item:

```bash
op item create \
  --category login \
  --title "DigitalOcean API Token" \
  --vault Private \
  "credential=dop_v1_xxxx"
```

The scripts will call `op read "$OP_ITEM"` at startup. If `op` is not installed or the read fails, they fall back to the `DIGITALOCEAN_ACCESS_TOKEN` environment variable, then prompt interactively (with hidden input).

**Recommended vault path convention:**

| Secret | 1Password path |
|--------|---------------|
| DO API token | `op://Private/DigitalOcean API Token/credential` |

### 3. API token scopes

Create a custom-scoped token at [DigitalOcean API Tokens](https://cloud.digitalocean.com/account/api/tokens).

**Scripts token (`snaprestore-scripts`) — used by both scripts via the doctl context:**

| Scope | Required by |
|-------|-------------|
| `droplet:read` | Both scripts |
| `droplet:create` | `do-restore.sh` — create droplet from snapshot |
| `droplet:update` | `do-snapshot.sh` — shutdown / power-off / power-on / snapshot action |
| `droplet:delete` | `do-snapshot.sh` — delete droplet after snapshot (optional) |
| `snapshot:read` | Both scripts |
| `snapshot:delete` | `do-snapshot.sh` — prune old snapshots |
| `ssh_key:read` | `do-restore.sh` — attach SSH key at creation |
| `reserved_ip:read` | Both scripts |
| `reserved_ip:update` | `do-restore.sh` — assign reserved IP to restored droplet |
| `action:read` | `do-restore.sh` — poll reserved IP assignment status |

> **Missing `droplet:create` is the most common setup mistake.** Without it the restore wizard completes normally but no droplet is created and no error is shown.

**Slack bot token (`snaprestore-bot`):** same scope set as the scripts token above.

### 4. Environment file

`.env.example` is a **reference document only** — it lists every environment variable the project uses and shows the `op://` path format for what should be stored in 1Password. Do not copy or run it.

The scripts authenticate via the `snaprestore` doctl context and need no environment variables. The Slack bot uses `slack-bot/.env.op` (see the Slack bot section).

---

## Token Loading Order

The scripts authenticate via the `snaprestore` doctl context — no environment variables needed. If you ever need to override (e.g. for scripted use), set `OP_ITEM` in the script config block to an `op://` path and the script will call `op read` at startup.

---

## do-snapshot.sh

Snapshots an existing droplet. Optionally shuts the droplet down first (prompts), waits for the snapshot to complete, then lets you start, leave, or delete the droplet.

### Flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Print every operation that would run; make no API calls |
| `--quiet` | Suppress all non-error output |
| `--json` | Emit final state as a JSON object on stdout |
| `--log FILE` | Tee all output to FILE (appends) |
| `--help` | Show usage |

### Configuration block

```bash
DROPLET_ID=""       # Set to a droplet ID, or leave blank for interactive selection
SNAPSHOT_NAME=""    # Optional: defaults to {droplet-name}-snapshot-{YYYYMMDD-HHMM}
OP_ITEM=""          # Optional: op://Vault/Item/field
DOCTL_CONTEXT="snaprestore"    # Optional: doctl auth context, e.g. "snaprestore"
```

### Usage

```bash
# Fully interactive
./do-snapshot.sh

# List droplets only
DROPLET_ID="list" ./do-snapshot.sh    # or edit config var

# Dry-run (no API writes)
./do-snapshot.sh --dry-run

# Log to file
./do-snapshot.sh --log ~/.local/share/do-snap-tool/snapshot-$(date +%Y%m%d).log

# JSON output (for scripting)
./do-snapshot.sh --json 2>/dev/null | jq .snapshot_id
```

### Example session

```
$ ./do-snapshot.sh

  Fetching droplets...

Select droplet to snapshot:
> 123456789|web-server|active|s-2vcpu-4gb|nyc1|80GB
  987654321|dev-box|off|s-1vcpu-1gb|sfo3|25GB

========================================
  Droplet Details
========================================
  ID:          123456789
  Name:        web-server
  Status:      active
  Region:      nyc1
  Size:        s-2vcpu-4gb
  vCPUs:       2
  Memory:      4096MB
  Disk:        80GB
  Public IP:   164.90.xxx.xxx
  Reserved IP: 167.99.xxx.xxx

  Snapshot name [web-server-snapshot-20260526-1430]:

  Snapshot will be named: web-server-snapshot-20260526-1430

Proceed with snapshot? (y/n): y

  Shutting down droplet for clean snapshot...
  ✓ Droplet stopped.

  Creating snapshot 'web-server-snapshot-20260526-1430' (this may take several minutes)...
  ✓ Snapshot complete.

  Fetching snapshot details...

========================================
  Snapshot Created
========================================
  ID:         119876543
  Name:       web-server-snapshot-20260526-1430
  Compressed: 12.34GB  (source disk: 80GB)
  Regions:    nyc1
  Est. cost:  ~$0.74/mo

  Restore:    ./do-restore.sh  # select: web-server-snapshot-20260526-1430

What to do with the droplet?
> start|Start it back up
  leave|Leave it shut down (billing continues)
  delete|Delete/destroy it

  Starting droplet...
  ✓ Droplet is active.
  Connect: ssh root@167.99.xxx.xxx

  ✓ Done.
```

### JSON output shape

```json
{
  "droplet_id":    "123456789",
  "droplet_name":  "web-server",
  "snapshot_id":   "119876543",
  "snapshot_name": "web-server-snapshot-20260526-1430",
  "snapshot_size_gb": 12.34,
  "min_disk_gb":   80,
  "regions":       ["nyc1"],
  "post_action":   "start",
  "reserved_ip":   "167.99.xxx.xxx"
}
```

---

## do-restore.sh

Creates a new droplet from a snapshot, waits for it to become active, then assigns a reserved IP.

### Flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Print every operation that would run; make no API calls |
| `--quiet` | Suppress all non-error output |
| `--json` | Emit final state as a JSON object on stdout |
| `--log FILE` | Tee all output to FILE (appends) |
| `--tags TAGS` | Comma-separated tags to apply to the new droplet |
| `--help` | Show usage |

### Configuration block

```bash
SNAPSHOT_ID=""      # Snapshot ID, or leave blank for interactive selection
SSH_KEY_ID=""       # SSH key ID (comma-separated for multiple), or blank to prompt
SIZE_SLUG=""        # Droplet size slug, or blank to prompt
DROPLET_NAME=""     # Optional: defaults to restored-{snapshot-name}-{YYYYMMDD}
RESERVED_IP=""      # Reserved IP to assign, or blank to prompt
OP_ITEM=""          # Optional: op://Vault/Item/field
DOCTL_CONTEXT="snaprestore"    # Optional: doctl auth context, e.g. "snaprestore"
```

### Usage

```bash
# Fully interactive
./do-restore.sh

# List resources
SNAPSHOT_ID="list"  ./do-restore.sh    # List snapshots
SSH_KEY_ID="list"   ./do-restore.sh    # List SSH keys
SIZE_SLUG="list"    ./do-restore.sh    # List compatible sizes (requires SNAPSHOT_ID set)
RESERVED_IP="list"  ./do-restore.sh    # List reserved IPs

# With tags
./do-restore.sh --tags "project:dh,env:prod"

# Dry-run
./do-restore.sh --dry-run

# JSON output
./do-restore.sh --json 2>/dev/null | jq .connect_ip
```

### Example session

```
$ ./do-restore.sh

  Fetching snapshots...

Select snapshot:
> 119876543|web-server-snapshot-20260526-1430|12.34GB|min:80GB|nyc1|0d ago
  118765432|dev-backup-20251215|5.67GB|min:25GB|sfo3|162d ago

  Selected:     web-server-snapshot-20260526-1430
  Compressed:   12.34GB  (source disk: 80GB)
  Created:      2026-05-26T14:30:00Z  (0 days ago)
  Regions:      nyc1

  Fetching compatible droplet sizes...

Select droplet size:
> s-2vcpu-4gb|2vCPU|4096MB|80GB disk|$24/mo
  s-4vcpu-8gb|4vCPU|8192MB|160GB disk|$48/mo

  Size: s-2vcpu-4gb

  Fetching SSH keys...
  Attach an SSH key? (y/n): y

Select SSH key:
> 12345678|my-macbook

  SSH key: 12345678

  Assign a reserved IP? (y/n): y

Select reserved IP:
> 167.99.xxx.xxx|unassigned|nyc1

  Reserved IP: 167.99.xxx.xxx
  Droplet name [restored-web-server-snapshot-20260526-1430-20260526]: web-server

========================================
  Creating Droplet
========================================
  Name:        web-server
  Size:        s-2vcpu-4gb
  Region:      nyc1
  Image:       119876543 (web-server-snapshot-20260526-1430)
  SSH Key:     12345678
  Reserved IP: 167.99.xxx.xxx

Proceed? (y/n): y

  Creating droplet (this may take 1–2 minutes)...
  ✓ Droplet active.  ID: 456789123  IP: 164.90.xxx.xxx

  Assigning reserved IP 167.99.xxx.xxx to droplet 456789123...
  ✓ Reserved IP assigned.

========================================
  Done
========================================
  Droplet ID:    456789123
  Droplet IP:    164.90.xxx.xxx
  Reserved IP:   167.99.xxx.xxx

  Connect:       ssh root@167.99.xxx.xxx
```

### JSON output shape

```json
{
  "droplet_id":    "456789123",
  "droplet_name":  "web-server",
  "droplet_ip":    "164.90.xxx.xxx",
  "reserved_ip":   "167.99.xxx.xxx",
  "connect_ip":    "167.99.xxx.xxx",
  "snapshot_id":   "119876543",
  "snapshot_name": "web-server-snapshot-20260526-1430",
  "size":          "s-2vcpu-4gb",
  "region":        "nyc1",
  "tags":          ["project:dh", "env:prod"]
}
```

---

## Docker Auto-Start Configuration

For Docker containers to start automatically after a restore:

### 1. Enable Docker on boot

```bash
sudo systemctl enable docker
sudo systemctl is-enabled docker    # should output: enabled
```

### 2. Set restart policy on containers

```bash
# docker run
docker run -d --restart=unless-stopped myapp

# docker-compose.yml
services:
  myapp:
    image: myapp:latest
    restart: unless-stopped
```

| Policy | Behavior |
|--------|----------|
| `no` | Never restart (default) |
| `always` | Always restart, including on daemon start |
| `unless-stopped` | Restart unless manually stopped — recommended |
| `on-failure` | Restart only on non-zero exit code |

### 3. Verify before snapshotting

```bash
sudo systemctl is-enabled docker
docker inspect --format '{{.Name}}: {{.HostConfig.RestartPolicy.Name}}' $(docker ps -aq)
```

### Cloudflare Tunnels

If you use `cloudflared`, give it `restart: unless-stopped` in your compose file. The tunnel reconnects automatically on boot — no IP updates needed since traffic routes through Cloudflare, and the reserved IP remains constant across snapshot/restore cycles.

---

## Typical Workflow

### Cost-saving on-demand usage

1. **Snapshot and delete** when not needed:
   ```bash
   ./do-snapshot.sh
   # Select droplet → name snapshot → choose "delete"
   # ~$0.74/mo snapshot storage vs. ~$24/mo running droplet
   ```

2. **Restore when needed**:
   ```bash
   ./do-restore.sh
   # Select snapshot → choose size → assign reserved IP
   # Same IP, same DNS, same Cloudflare config
   ```

3. **Tips:**
   - Reserved IPs preserve your IP across cycles. Keep them assigned.
   - Snapshot while off ensures filesystem consistency — both scripts handle this.
   - `min_disk_size` is locked to the source droplet's total disk at snapshot time, not actual used space. Use the smallest adequate disk droplet to maximize restore flexibility.
   - Snapshot names default to `{droplet-name}-snapshot-{YYYYMMDD-HHMM}` — unique enough to avoid collision.

---

## Troubleshooting

### `doctl: command not found`

```bash
brew install doctl
doctl auth init --context snaprestore
```

### `unable to initialize DigitalOcean API client: access token is required`

No token was found. Set `DOCTL_CONTEXT` in the config block, or export `DIGITALOCEAN_ACCESS_TOKEN`, or set `OP_ITEM` pointing to your 1Password vault entry.

### `op read failed`

1. Confirm `op` is signed in: `op account list`
2. Confirm the vault path is correct: `op read 'op://Private/DigitalOcean API Token/credential'`
3. If 1Password CLI is not installed, remove `OP_ITEM` from the config block — the script falls back to the env var.

### `No compatible droplet sizes found`

The snapshot's `min_disk_size` exceeds every available size in the region. This happens when the original droplet had a large disk. Options:
- Resize the original droplet to a smaller disk before snapshotting (requires migration)
- Future snapshots: start with the smallest adequate disk droplet

### `Reserved IP assignment did not complete`

The script prints a manual fallback command. Run it after checking the console:
```bash
doctl compute reserved-ip-action assign <IP> <droplet-id>
```

### `Script hangs / no output`

With `doctl --wait`, the command polls until the action completes or times out (doctl default: 600 s for actions, longer for droplet create). If it exceeds this, doctl exits non-zero and the cleanup trap prints the interrupted operation and resource ID.

### `fzf not working`

The script falls back to numbered menus automatically. To get arrow-key selection:
```bash
brew install fzf
```

---

## Slack Bot (`slack-bot/`)

Trigger snapshot and restore operations from Slack using slash commands. Runs as a Python Slack Bolt app in Socket Mode on a dedicated $6/mo DigitalOcean controller droplet.

**Full Slack bot documentation:** [`slack-bot/README-slack-bot.md`](slack-bot/README-slack-bot.md)

### Commands

| Command | Description |
|---------|-------------|
| `/do-snapshot [name-or-id]` | Snapshot a droplet (shuts it down first). Prompts if multiple droplets exist. |
| `/do-restore [snap-id-or-name]` | Create a droplet from a snapshot. Lists recent snapshots if no argument given. |
| `/do-deploy-cancel <job-id>` | Cancel a running snapshot or restore job by job ID. |

All operations run asynchronously and post status updates in a Slack thread. Long-running steps (shutdown, snapshot creation, droplet creation) post elapsed-time heartbeats every 2 minutes.

### Architecture

- **Slack Bolt Python** (`slack-bolt>=1.19`) with **Socket Mode** — no public ingress required, no HTTP port to expose
- **1Password service account** — the only secret on disk is `OP_SERVICE_ACCOUNT_TOKEN` in `/etc/do-snap-bot/env` (mode 0600); all other secrets (`SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_SIGNING_SECRET`, `DIGITALOCEAN_ACCESS_TOKEN`, `SLACK_ALLOWED_USERS`) are resolved at runtime via `op run`
- **Allow-list** — `SLACK_ALLOWED_USERS` (comma-separated Slack user IDs) gates all commands; empty = allow all (not recommended)
- **Request authentication** — Bolt verifies Slack's `X-Slack-Signature` HMAC on every event automatically

### Secrets — 1Password vault paths

Store these in 1Password before deploying. The paths below match `slack-bot/.env.op.example`:

| Secret | 1Password path |
|--------|---------------|
| Slack bot token (`xoxb-…`) | `op://Private/do-snap-bot/slack-bot-token` |
| Slack app-level token (`xapp-…`) | `op://Private/do-snap-bot/slack-app-token` |
| Slack signing secret | `op://Private/do-snap-bot/signing-secret` |
| DigitalOcean API token | `op://Private/do-snap-bot/do-token` |
| Allowed user IDs | `op://Private/do-snap-bot/allowed-users` |

**WARNING:** Never write raw tokens to `.env.op`, commit files with secrets, or store tokens in shell history.

### Required token scopes

Create a custom-scoped token for the bot's DO token:

| Resource | Permissions |
|----------|-------------|
| Droplet | read, create, delete |
| Droplet Action | create |
| Snapshot | read |
| Reserved IP | read, update |

For the Slack app, the manifest at `slack-bot/manifest.yml` declares the required OAuth scopes (`chat:write`, `chat:write.public`, `commands`, `users:read`).

### Setup

#### 1. Create the Slack app

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest**
2. Paste the contents of `slack-bot/manifest.yml`
3. Under **Settings → Socket Mode**, enable Socket Mode and generate an **App-Level Token** with scope `connections:write` — this is your `SLACK_APP_TOKEN` (`xapp-…`)
4. Under **OAuth & Permissions**, install the app to your workspace and copy the **Bot User OAuth Token** (`xoxb-…`) — this is your `SLACK_BOT_TOKEN`
5. Under **Basic Information**, copy the **Signing Secret** — this is your `SLACK_SIGNING_SECRET`

#### 2. Store secrets in 1Password

```bash
# Create the vault item (do this once per secret)
op item create --category login --title "do-snap-bot" --vault Private \
  "slack-bot-token=xoxb-..." \
  "slack-app-token=xapp-..." \
  "signing-secret=..." \
  "do-token=dop_v1_..." \
  "allowed-users=U01AB2CD3,U04XY5EF6"
```

#### 3. Create a 1Password service account

1. In 1Password.com → **Developer** → **Service Accounts** → **New Service Account**
2. Grant read access to the `Private` vault (or a dedicated vault)
3. Copy the service account token — this is `OP_SERVICE_ACCOUNT_TOKEN`

#### 4. Launch the controller droplet

Create a new $6/mo DigitalOcean droplet (Debian/Ubuntu, 1 vCPU, 1 GB RAM, the region of your choice):

```
User Data: paste contents of slack-bot/cloud-init/controller.yml
           (after replacing <YOUR_SSH_PUBLIC_KEY> and <OP_SERVICE_ACCOUNT_TOKEN>)
```

Wait ~3 minutes for cloud-init to finish.

#### 5. Deploy the bot

```bash
# From your local machine:
rsync -av slack-bot/ dosnap@<controller-ip>:/opt/do-snap-bot/

# On the controller:
ssh dosnap@<controller-ip>
cd /opt/do-snap-bot
cp .env.op.example .env.op
# Verify op:// paths match what you created in step 2
systemctl start do-snap-bot
journalctl -u do-snap-bot -f
```

You should see `⚡️ Bolt app is running!` in the logs.

#### 6. Verify

In Slack, type `/do-snapshot` — the bot should respond with a list of droplets (or a message if none exist).

### Running locally (development)

```bash
cd slack-bot
cp .env.op.example .env.op
# Edit .env.op if your op:// paths differ

# Requires: op CLI signed in, uv installed
./start.sh
```

Or without 1Password:

```bash
export SLACK_BOT_TOKEN=xoxb-...
export SLACK_APP_TOKEN=xapp-...
export SLACK_SIGNING_SECRET=...
export DIGITALOCEAN_ACCESS_TOKEN=dop_v1_...
export SLACK_ALLOWED_USERS=U01AB2CD3
cd slack-bot
uv run python bot.py
```

### File structure

```
snaprestore/
├── do-snapshot.sh            # Snapshot a droplet (shutdown → snapshot → start/leave/delete)
├── do-restore.sh             # Restore a droplet from snapshot + assign reserved IP
├── .env.example              # Environment variable reference with op:// examples (tracked)
├── docs/
│   └── setup-cc.md           # Complete setup guide (DO tokens, doctl, 1Password, Slack bot)
├── lib/
│   ├── bootstrap_sh.sh       # UI bootstrap (gum detection, dependency checks)
│   ├── ui_sh.sh              # Shell UI primitives (spinner, panel, choose, confirm)
│   └── ui_rich_py.py         # Rich/gum UI layer (optional enhanced output)
└── slack-bot/
    ├── README-slack-bot.md   # Slack bot documentation (file breakdown, setup, operations)
    ├── bot.py                # Slack Bolt async app (Socket Mode)
    ├── pyproject.toml        # Python dependencies (slack-bolt, httpx)
    ├── manifest.yml          # Slack app manifest (paste at api.slack.com)
    ├── .env.op.example       # 1Password op:// reference template for the bot
    ├── start.sh              # op run wrapper to launch the bot
    ├── systemd/
    │   └── do-snap-bot.service  # systemd unit (deployed by cloud-init)
    └── cloud-init/
        └── controller.yml    # Cloud-init for controller droplet provisioning
```

---

## License

MIT — use freely.

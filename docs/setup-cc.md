# snaprestore — Complete Setup Guide

Everything you need to go from zero to a working snapshot/restore workflow, plus the optional Slack bot on a dedicated controller droplet.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Part 1 — DigitalOcean](#part-1--digitalocean)
3. [Part 2 — doctl](#part-2--doctl)
4. [Part 3 — 1Password](#part-3--1password)
5. [Part 4 — Environment File](#part-4--environment-file)
6. [Part 5 — Testing the Scripts](#part-5--testing-the-scripts)
7. [Part 6 — Controller Droplet](#part-6--controller-droplet)
8. [Part 7 — Slack App Setup](#part-7--slack-app-setup)
9. [Quick Reference](#quick-reference)

---

## Prerequisites

Install required tools before starting:

| Tool | Required | Install |
|------|----------|---------|
| `doctl` | Yes | `brew install doctl` |
| `jq` | Yes | `brew install jq` |
| `1password-cli` | Yes (for `op://` injection) | `brew install 1password-cli` |
| `fzf` | Optional (arrow-key menus) | `brew install fzf` |
| `gum` | Optional (rich TUI on first run) | `brew install gum` |

Verify installs:

```bash
doctl version
jq --version
op --version
```

---

## Part 1 — DigitalOcean

### 1.1 Create a DigitalOcean API token

You need at minimum one API token. For production, create separate tokens — one for the scripts and one for the Slack bot — so you can revoke them independently.

Create **two tokens** — one for the scripts, one for the Slack bot — so you can revoke them independently.

**Token 1 — Scripts (`snaprestore-scripts`):**
Used by `do-restore.sh` and `do-snapshot.sh` via the doctl context. This token needs full read/write access to droplets, snapshots, SSH keys, and reserved IPs.

1. Log in to [cloud.digitalocean.com](https://cloud.digitalocean.com).
2. Go to **API** → **Tokens** → **Generate New Token**.
3. Name it `snaprestore-scripts`.
4. Select **Custom Scopes** and enable **all** of the following:

| Scope | Required by |
|-------|-------------|
| `droplet:read` | Both scripts — list and inspect droplets |
| `droplet:create` | `do-restore.sh` — create a new droplet from snapshot |
| `droplet:update` | `do-snapshot.sh` — power off droplet; trigger snapshot action |
| `droplet:delete` | `do-snapshot.sh` — delete droplet after snapshot (optional) |
| `snapshot:read` | Both scripts — list and select snapshots |
| `snapshot:delete` | `do-snapshot.sh` — prune old snapshots |
| `ssh_key:read` | `do-restore.sh` — list SSH keys to attach at creation |
| `reserved_ip:read` | Both scripts — list reserved IPs |
| `reserved_ip:update` | `do-restore.sh` — assign reserved IP to restored droplet |
| `action:read` | `do-restore.sh` — poll reserved IP assignment action status |

> **Missing `droplet:create` is the most common setup mistake.** Without it, the restore wizard completes normally but the droplet is never created and no error is shown.

5. Click **Generate Token**, copy the value — **shown only once** — and store it in 1Password immediately (see Part 3).

---

**Token 2 — Slack bot (`snaprestore-bot`):**
Used by the Slack bot service. Create a second token with the same scope table above plus any additional scopes the bot needs.

---

> **Note — “Droplet Action” scope no longer exists.** DigitalOcean’s current custom scopes UI (GA’d 2024) uses granular CRUD scopes per resource. Snapshot creation is triggered via the Droplet Actions API and is covered by `droplet:update`. Full reference: [docs.digitalocean.com/reference/api/scopes](https://docs.digitalocean.com/reference/api/scopes/).

> **WARNING:** Never paste a raw token into a script, commit it to git, or store it in shell history.

### 1.2 Verify you have a droplet

The snapshot script needs at least one existing droplet. List yours:

```bash
doctl compute droplet list
```

If you have no droplets yet, create a minimal one for testing:

```bash
doctl compute droplet create test-droplet \
  --image ubuntu-22-04-x64 \
  --size s-1vcpu-1gb \
  --region nyc1 \
  --ssh-keys $(doctl compute ssh-key list --no-header --format ID | head -1)
```

Wait ~60 seconds, then verify it is active:

```bash
doctl compute droplet list
```

### 1.3 Create a test snapshot

`do-restore.sh` needs at least one existing snapshot to work with. Create one using any of these methods:

**Option A — use the script (recommended after completing setup):**

```bash
./do-snapshot.sh
# Select the droplet → accept the default name → choose "leave" or "delete"
```

**Option B — create one via doctl directly:**

```bash
DROPLET_ID=$(doctl compute droplet list --no-header --format ID | head -1)
doctl compute droplet-action snapshot "$DROPLET_ID" \
  --snapshot-name "test-snapshot-$(date +%Y%m%d)" --wait
```

**Option C — create one in the control panel:**

1. Go to **Droplets** → click your droplet → **Snapshots** tab → **Take Snapshot**.
2. Give it a name and click **Take Snapshot**.

After creating a snapshot, verify it appears:

```bash
doctl compute snapshot list --resource droplet
```

### 1.4 (Optional) Reserve an IP

A reserved IP keeps your droplet's IP address constant across snapshot/restore cycles so DNS and Cloudflare configurations stay valid.

1. Go to **Networking** → **Reserved IPs** → **Reserve New IP**.
2. Select the same region as your droplet and click **Reserve IP**.

List your reserved IPs:

```bash
doctl compute reserved-ip list
```

---

## Part 2 — doctl

### 2.1 Authenticate doctl

```bash
doctl auth init --context snaprestore
```

When prompted, paste your DigitalOcean API token. The token is stored in `~/.config/doctl/config.yaml` (mode 0600) — it is never written to a script file or to shell history.

Verify the context works:

```bash
doctl auth switch --context snaprestore
doctl compute droplet list
```

### 2.2 Set the context in the scripts

In both `do-snapshot.sh` and `do-restore.sh`, locate the configuration block near the top of each file and set:

```bash
DOCTL_CONTEXT="snaprestore"
```

This tells every `doctl` call in the script which stored token to use. When `DOCTL_CONTEXT` is set, the scripts do not need `DIGITALOCEAN_ACCESS_TOKEN` in the environment.

---

## Part 3 — 1Password

### 3.1 Install and sign in to 1Password CLI

```bash
brew install 1password-cli
op signin
```

Verify you are signed in:

```bash
op account list
```

### 3.2 Create a vault item for the snapshot scripts

Store your DigitalOcean API token in a 1Password item:

```bash
op item create \
  --category login \
  --title "DigitalOcean API Token" \
  --vault Private \
  "credential=dop_v1_YOUR_TOKEN_HERE"
```

The default path used in `.env.example` is:

```
op://Private/DigitalOcean API Token/credential
```

Verify the path resolves:

```bash
op read "op://Private/DigitalOcean API Token/credential"
```

### 3.3 Create a vault item for the Slack bot

You will collect the Slack tokens in Part 7. Run the command below **after completing Part 7**, substituting the real values:

```bash
op item create \
  --category login \
  --title "do-snap-bot" \
  --vault Private \
  "slack-bot-token=xoxb-YOUR_BOT_TOKEN" \
  "slack-app-token=xapp-YOUR_APP_TOKEN" \
  "signing-secret=YOUR_SIGNING_SECRET" \
  "do-token=dop_v1_YOUR_BOT_DO_TOKEN" \
  "allowed-users=U01AB2CD3,U04XY5EF6"
```

The resulting 1Password paths, which match `slack-bot/.env.op.example`:

| Secret | 1Password path |
|--------|---------------|
| Slack bot token (`xoxb-…`) | `op://Private/do-snap-bot/slack-bot-token` |
| Slack app-level token (`xapp-…`) | `op://Private/do-snap-bot/slack-app-token` |
| Slack signing secret | `op://Private/do-snap-bot/signing-secret` |
| DigitalOcean API token | `op://Private/do-snap-bot/do-token` |
| Allowed user IDs | `op://Private/do-snap-bot/allowed-users` |

> **WARNING:** Never write raw tokens to `.env.op`, commit files containing secrets, or store tokens in shell history.

### 3.4 Create a 1Password service account

The controller droplet runs `op run` non-interactively. A service account token provides that access without exposing your personal 1Password credentials.

1. Go to [1password.com](https://1password.com) → **Developer** → **Service Accounts** → **New Service Account**.
2. Name it something descriptive (e.g., `do-snap-bot-controller`).
3. Grant **read** access to the `Private` vault (or a dedicated vault containing only the `do-snap-bot` item).
4. Click **Generate Token** and copy the value (begins with `ops_`). **It is shown only once.**

You will paste this token into `slack-bot/cloud-init/controller.yml` in Part 6.

---

## Part 4 — Environment File Reference

`.env.example` in the project root is a **reference document only**. It lists every environment variable the project uses and shows the `op://` path format for what should be stored in 1Password. You do not copy or use it directly.

- **Scripts (`do-restore.sh`, `do-snapshot.sh`)** authenticate via the `snaprestore` doctl context. They do not use `.env` — run them directly (see Part 5).
- **Slack bot** uses `slack-bot/.env.op` with `op run` (see Part 6). The `op://` paths in that file correspond to the 1Password items you created in Part 3.

---

## Part 5 — Testing the Scripts

### 5.1 Dry-run (no API writes)

```bash
./do-snapshot.sh --dry-run
./do-restore.sh --dry-run
```

Both commands print every operation that would run — no API calls are made. This is the safest way to verify your setup before running for real.

### 5.2 List resources without acting

```bash
DROPLET_ID=list ./do-snapshot.sh     # list all droplets, then exit
SNAPSHOT_ID=list ./do-restore.sh     # list all snapshots, then exit
SSH_KEY_ID=list  ./do-restore.sh     # list SSH keys
RESERVED_IP=list ./do-restore.sh     # list reserved IPs
```

### 5.3 Full snapshot test

```bash
./do-snapshot.sh
```

1. Select a droplet from the interactive list.
2. Accept the default snapshot name or enter a custom one.
3. Confirm. The script gracefully shuts down the droplet, creates the snapshot (several minutes), then asks what to do with the droplet: **start**, **leave** (shut down, billing continues), or **delete**.

### 5.4 Full restore test

```bash
./do-restore.sh
```

1. Select a snapshot from the list.
2. Choose a droplet size (must meet the snapshot's minimum disk size).
3. Optionally attach an SSH key.
4. Optionally assign a reserved IP.
5. Confirm. The script creates the new droplet, waits for it to become active, and assigns the reserved IP.

---

## Part 6 — Controller Droplet

The Slack bot runs on a dedicated **$6/mo DigitalOcean droplet** (1 vCPU, 1 GB RAM). Cloud-init provisions all dependencies automatically.

### 6.1 Prepare cloud-init/controller.yml

Open `slack-bot/cloud-init/controller.yml` and replace both placeholders:

| Placeholder | Replace with |
|-------------|-------------|
| `<YOUR_SSH_PUBLIC_KEY>` | Your SSH public key (`cat ~/.ssh/id_ed25519.pub`) |
| `<OP_SERVICE_ACCOUNT_TOKEN>` | The service account token from Part 3.4 |

> **WARNING:** Do not commit `controller.yml` after filling in the service account token. Work from a local copy — the file is in `.gitignore`.

### 6.2 Create the controller droplet

1. Log in to [cloud.digitalocean.com](https://cloud.digitalocean.com).
2. Go to **Droplets** → **Create Droplet**.
3. Configure the droplet:
   - **Image:** Ubuntu 22.04 (LTS) x64
   - **Size:** Basic → Regular CPU → **$6/mo** (1 vCPU, 1 GB RAM, 25 GB SSD)
   - **Region:** Any — match the region of your other droplets for lowest latency
   - **Authentication:** SSH Key — select or add your key
4. Expand **Advanced Options** → enable **Add Initialization scripts (free)** → paste the full contents of your edited `controller.yml`.
5. Click **Create Droplet**.

Cloud-init takes **3–5 minutes**. Monitor progress:

```bash
ssh dosnap@<controller-ip> "sudo tail -f /var/log/cloud-init-output.log"
```

### 6.3 Verify the droplet

```bash
ssh dosnap@<controller-ip>
doctl version      # should print the doctl version
op --version       # should print the 1Password CLI version
uv --version       # should print the uv version
```

### 6.4 Deploy the bot

```bash
# From your local machine — sync the bot code to the controller:
rsync -av slack-bot/ dosnap@<controller-ip>:/opt/do-snap-bot/

# On the controller:
ssh dosnap@<controller-ip>
cd /opt/do-snap-bot
cp .env.op.example .env.op
# Verify the op:// paths in .env.op match what you created in Part 3.3
sudo systemctl start do-snap-bot
sudo journalctl -u do-snap-bot -f
```

You should see `⚡️ Bolt app is running!` in the logs within a few seconds of starting.

### 6.5 Manage the service

```bash
sudo systemctl status do-snap-bot      # current status
sudo systemctl restart do-snap-bot     # restart after code changes
sudo systemctl stop do-snap-bot        # stop
sudo journalctl -u do-snap-bot -n 100  # last 100 log lines
sudo journalctl -u do-snap-bot -f      # follow live logs
```

---

## Part 7 — Slack App Setup

### 7.1 Create a dedicated channel

In Slack, create a channel for bot operations — e.g., `#do-ops` or `#deploys`. Invite team members who should have access.

### 7.2 Create the Slack app from a manifest

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest**.
2. Select your Slack workspace.
3. Paste the full contents of `slack-bot/manifest.yml` into the **YAML** tab. Click **Next** → **Create**.

### 7.3 Enable Socket Mode and get the app-level token

1. In the app settings sidebar, go to **Settings** → **Socket Mode**.
2. Toggle **Enable Socket Mode** to **On**.
3. Under **App-Level Tokens**, click **Generate** (or **Add**).
4. Name the token (e.g., `socket-token`) and add the scope `connections:write`.
5. Click **Generate**.
6. Copy the token beginning with `xapp-` — this is your **`SLACK_APP_TOKEN`**.

### 7.4 Install the app to your workspace and get the bot token

1. In the app settings sidebar, go to **Settings** → **Install App**.
2. Click **Install to Workspace** → **Allow**.
3. Copy the **Bot User OAuth Token** beginning with `xoxb-` — this is your **`SLACK_BOT_TOKEN`**.

### 7.5 Copy the signing secret

1. In the app settings sidebar, go to **Settings** → **Basic Information** → **App Credentials**.
2. Click **Show** next to **Signing Secret** and copy the value — this is your **`SLACK_SIGNING_SECRET`**.

### 7.6 Invite the bot to your channel

In Slack, open your `#do-ops` channel and run:

```
/invite @DO Snap Bot
```

### 7.7 Find your Slack user ID (for the allow-list)

1. In Slack, click any team member's name to open their profile.
2. Click the **⋮** (More actions) menu → **Copy member ID**.
3. Repeat for each person who should be able to run slash commands.
4. The format is `U01AB2CD3,U04XY5EF6` — comma-separated, no spaces.

### 7.8 Store tokens in 1Password

Now that you have all the values, run the `op item create` command from Part 3.3:

```bash
op item create \
  --category login \
  --title "do-snap-bot" \
  --vault Private \
  "slack-bot-token=xoxb-YOUR_BOT_TOKEN" \
  "slack-app-token=xapp-YOUR_APP_TOKEN" \
  "signing-secret=YOUR_SIGNING_SECRET" \
  "do-token=dop_v1_YOUR_BOT_DO_TOKEN" \
  "allowed-users=U01AB2CD3,U04XY5EF6"
```

Then update `.env.op` on the controller droplet to use the `op://` paths listed in Part 3.3, and restart the bot:

```bash
sudo systemctl restart do-snap-bot
sudo journalctl -u do-snap-bot -f
```

### 7.9 Test in Slack

In your `#do-ops` channel:

```
/do-snapshot                          → lists droplets or begins a snapshot job
/do-restore                           → lists recent snapshots
/do-restore web-server-20260526       → restore a specific snapshot by name or ID
/do-deploy-cancel abc123              → cancel a running job by its job ID
```

---

## Quick Reference

### All variables at a glance

| Variable | Where it lives | Description |
|----------|----------------|-------------|
| `DIGITALOCEAN_ACCESS_TOKEN` | `slack-bot/.env.op`, 1Password | DigitalOcean API token (Slack bot only — scripts use doctl context) |
| `DOCTL_CONTEXT` | Script config block (`snaprestore`) | doctl auth context name |
| `OP_SERVICE_ACCOUNT_TOKEN` | `/etc/do-snap-bot/env` on controller | 1Password service account token |
| `SLACK_BOT_TOKEN` | `slack-bot/.env.op` | `xoxb-…` bot user OAuth token |
| `SLACK_APP_TOKEN` | `slack-bot/.env.op` | `xapp-…` socket mode app token |
| `SLACK_SIGNING_SECRET` | `slack-bot/.env.op` | Slack request signing secret |
| `SLACK_ALLOWED_USERS` | `slack-bot/.env.op` | Comma-separated Slack member IDs |

### Token loading order (both scripts)

The scripts authenticate via the `snaprestore` doctl context and do not require any environment variables. The full resolution order if you ever override via `OP_ITEM`:

1. `OP_ITEM` config var → calls `op read` if the `op` CLI is present
2. `DOCTL_CONTEXT` → doctl uses its stored context token (default path)

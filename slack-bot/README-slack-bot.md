# DO Snap Bot

A Slack Bolt app that runs DigitalOcean snapshot and restore operations via slash commands. Runs on a dedicated $6/mo DigitalOcean controller droplet in Socket Mode — no public HTTP port or ingress required.

---

## Table of Contents

1. [Slash Commands](#slash-commands)
2. [File Breakdown](#file-breakdown)
3. [Architecture](#architecture)
4. [Setup](#setup)
   - [1. Create the Slack app](#1-create-the-slack-app)
   - [2. Store secrets in 1Password](#2-store-secrets-in-1password)
   - [3. Launch the controller droplet](#3-launch-the-controller-droplet)
   - [4. Deploy the bot](#4-deploy-the-bot)
5. [Running Locally (Development)](#running-locally-development)
6. [Managing the Service](#managing-the-service)
7. [Variables Reference](#variables-reference)

---

## Slash Commands

| Command | Description |
|---------|-------------|
| `/do-snapshot [name-or-id]` | Snapshot a droplet (prompts to shut down first for consistency). Prompts if multiple droplets exist. |
| `/do-restore [snap-id-or-name]` | Create a droplet from a snapshot. Lists recent snapshots if no argument given. |
| `/do-deploy-cancel <job-id>` | Cancel a running snapshot or restore job by job ID. |

All operations run asynchronously and post status updates in a Slack thread. Long-running steps (shutdown, snapshot creation, droplet creation) post elapsed-time heartbeats every 2 minutes.

---

## File Breakdown

```
slack-bot/
├── bot.py                         # Main application
├── pyproject.toml                 # Python dependencies
├── manifest.yml                   # Slack app manifest
├── .env.op.example                # 1Password op:// reference template
├── start.sh                       # Startup script (wraps `op run`)
├── systemd/
│   └── do-snap-bot.service        # systemd unit file
└── cloud-init/
    └── controller.yml             # Cloud-init for the controller droplet
```

### `bot.py`

The Slack Bolt async application. Key responsibilities:

- **`/do-snapshot`** handler (`cmd_snapshot` → `_snapshot_job`): Finds the target droplet, prompts to shut it down gracefully (falls back to power-off if shutdown fails), creates a named snapshot via `doctl`, and reports the result in a Slack thread.
- **`/do-restore`** handler (`cmd_restore` → `_restore_job`): Lists recent snapshots if no argument is given; otherwise creates a new droplet from the specified snapshot and runs an HTTP health check after the droplet becomes active.
- **`/do-deploy-cancel`** handler (`cmd_cancel`): Creates a cancel-flag file in `~/.local/share/do-snap-bot/jobs/<job-id>.cancel`. The running job polls for this file and terminates cleanly.
- **`run_doctl` / `run_doctl_long`**: Async wrappers around `doctl` subprocesses. `run_doctl_long` posts elapsed-time heartbeats to Slack every 2 minutes while the command runs, and checks for cancellation between heartbeats.
- **`health_check`**: Polls an HTTP URL until it returns 200 or a 5-minute timeout expires. Used after restore to confirm the new droplet is serving traffic.
- **`_authorize`**: Gates every command on `SLACK_ALLOWED_USERS`. If the env var is empty, all workspace members are allowed.
- **`build_welcome_cloud_init`**: Generates a `#cloud-config` snippet that installs nginx and serves a status page on the restored droplet.

### `pyproject.toml`

Declares Python 3.11+ and two dependencies:

- `slack-bolt>=1.19` — Slack Bolt framework (Socket Mode async)
- `httpx>=0.27` — async HTTP client for the health check

`uv` reads this file to create an isolated virtualenv and install dependencies on first run.

### `manifest.yml`

Slack app manifest. Paste this into [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest** to create the app with the correct slash commands, OAuth scopes, and Socket Mode settings pre-configured.

Declares:
- Slash commands: `/do-snapshot`, `/do-restore`, `/do-deploy-cancel`
- Bot OAuth scopes: `chat:write`, `chat:write.public`, `commands`, `users:read`
- Socket Mode enabled, interactivity disabled

### `.env.op.example`

Template for the `op://` references used by `start.sh`. Copy to `.env.op` and verify the vault paths match what you created in 1Password. **Never write raw token values into this file or `.env.op`.**

```
SLACK_BOT_TOKEN=op://CDS_Vault/do-snap-bot/slack-bot-token
SLACK_APP_TOKEN=op://CDS_Vault/do-snap-bot/slack-app-token
SLACK_SIGNING_SECRET=op://CDS_Vault/do-snap-bot/signing-secret
DIGITALOCEAN_ACCESS_TOKEN=op://CDS_Vault/do-snap-bot/do-token
SLACK_ALLOWED_USERS=op://CDS_Vault/do-snap-bot/allowed-users
```

### `start.sh`

Startup wrapper used by both local development and the systemd service. Validates that `.env.op` and both CLIs (`op`, `uv`) are present, then calls:

```bash
exec op run --env-file=".env.op" -- uv run python bot.py
```

`op run` resolves every `op://` reference and injects the values as environment variables — no secrets ever touch disk beyond the 1Password vault.

### `systemd/do-snap-bot.service`

systemd unit file for the controller droplet. Key settings:

- **User/Group:** `dosnap` — a non-root service account created by cloud-init
- **WorkingDirectory:** `/opt/do-snap-bot`
- **ExecStart:** `/opt/do-snap-bot/start.sh`
- **EnvironmentFile:** `/etc/do-snap-bot/env` — loads `OP_SERVICE_ACCOUNT_TOKEN` before `start.sh` runs so `op run` can authenticate without interactive login
- **Restart:** `on-failure` with a 15-second back-off

This unit file is also embedded in `cloud-init/controller.yml` so it is installed automatically on droplet creation.

### `cloud-init/controller.yml`

Cloud-init `#cloud-config` document. Paste into the **User Data** field when creating the controller droplet. Provisions the droplet automatically:

1. Creates the `dosnap` system user with limited `sudo` (only `systemctl` commands for `do-snap-bot`)
2. Installs: `curl`, `jq`, `ca-certificates`, `nginx`, `gnupg`
3. Installs the **1Password CLI** from the official Debian repository
4. Installs **doctl** v1.110.0 from the GitHub release tarball
5. Installs **uv** via the official install script
6. Writes the systemd service unit to `/etc/systemd/system/do-snap-bot.service`
7. Writes `OP_SERVICE_ACCOUNT_TOKEN` to `/etc/do-snap-bot/env` (mode 0600, owned by `dosnap`)
8. Writes an nginx welcome page for HTTP health checks
9. Enables nginx and the `do-snap-bot` systemd unit (the service will not start until bot code is deployed)

**Before using:** replace `<YOUR_SSH_PUBLIC_KEY>` and `<OP_SERVICE_ACCOUNT_TOKEN>` with real values. Do not commit the edited file.

---

## Architecture

- **Slack Bolt Python** (`slack-bolt>=1.19`) with **Socket Mode** — the bot connects outbound to Slack over a WebSocket. No public ingress, no HTTP port to expose, no firewall rules needed.
- **1Password service account** — the only secret stored on disk is `OP_SERVICE_ACCOUNT_TOKEN` in `/etc/do-snap-bot/env` (mode 0600, root-owned). All other secrets (`SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_SIGNING_SECRET`, `DIGITALOCEAN_ACCESS_TOKEN`, `SLACK_ALLOWED_USERS`) are resolved at runtime via `op run`.
- **Allow-list** — `SLACK_ALLOWED_USERS` (comma-separated Slack user IDs) gates all commands. Empty = allow all workspace members (not recommended for production).
- **Request authentication** — Bolt verifies Slack's `X-Slack-Signature` HMAC on every incoming event automatically.
- **Async job model** — every slash command acknowledges Slack immediately (within Slack's 3-second window) then dispatches work to an `asyncio` task. Long operations post progress updates in the original Slack thread.

---

## Setup

### 1. Create the Slack app

#### 1.1 Create a dedicated channel

In Slack, create a channel for bot operations — e.g., `#do-ops` or `#deploys`. Invite team members who should have access.

#### 1.2 Create the Slack app from a manifest

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest**.
2. Select your Slack workspace.
3. Paste the full contents of `slack-bot/manifest.yml` into the **YAML** tab. Click **Next** → **Create**.

#### 1.3 Enable Socket Mode and get the app-level token

1. In the app settings sidebar, go to **Settings** → **Socket Mode**.
2. Toggle **Enable Socket Mode** to **On**.
3. Under **App-Level Tokens**, click **Generate** (or **Add**).
4. Name the token (e.g., `socket-token`) and add the scope `connections:write`.
5. Click **Generate**.
6. Copy the token beginning with `xapp-` — this is your **`SLACK_APP_TOKEN`**.

#### 1.4 Install the app to your workspace and get the bot token

1. In the app settings sidebar, go to **Settings** → **Install App**.
2. Click **Install to Workspace** → **Allow**.
3. Copy the **Bot User OAuth Token** beginning with `xoxb-` — this is your **`SLACK_BOT_TOKEN`**.

#### 1.5 Copy the signing secret

1. In the app settings sidebar, go to **Settings** → **Basic Information** → **App Credentials**.
2. Click **Show** next to **Signing Secret** and copy the value — this is your **`SLACK_SIGNING_SECRET`**.

#### 1.6 Invite the bot to your channel

In Slack, open your `#do-ops` channel and run:

```
/invite @DO Snap Bot
```

#### 1.7 Find your Slack user ID (for the allow-list)

1. In Slack, click any team member's name to open their profile.
2. Click the **⋮** (More actions) menu → **Copy member ID**.
3. Repeat for each person who should be able to run slash commands.
4. The format is `U01AB2CD3,U04XY5EF6` — comma-separated, no spaces.

---

### 2. Store secrets in 1Password

#### 2.1 Install and sign in to 1Password CLI

Install all local dependencies at once (if not already done from the main setup):

```bash
brew install doctl jq 1password-cli fzf gum uv
```

Then sign in to 1Password:

```bash
op signin
```

Verify you are signed in:

```bash
op account list
```

#### 2.2 Create the vault item for the Slack bot

Now that you have all the values from Step 1, create a single 1Password item holding all five secrets:

```bash
op item create \
  --category login \
  --title "do-snap-bot" \
  --vault CDS_Vault \
  "slack-bot-token=xoxb-YOUR_BOT_TOKEN" \
  "slack-app-token=xapp-YOUR_APP_TOKEN" \
  "signing-secret=YOUR_SIGNING_SECRET" \
  "do-token=dop_v1_YOUR_BOT_DO_TOKEN" \
  "allowed-users=U01AB2CD3,U04XY5EF6"
```

The resulting 1Password paths, which match `.env.op.example`:

| Secret | 1Password path |
|--------|---------------|
| Slack bot token (`xoxb-…`) | `op://CDS_Vault/do-snap-bot/slack-bot-token` |
| Slack app-level token (`xapp-…`) | `op://CDS_Vault/do-snap-bot/slack-app-token` |
| Slack signing secret | `op://CDS_Vault/do-snap-bot/signing-secret` |
| DigitalOcean API token | `op://CDS_Vault/do-snap-bot/do-token` |
| Allowed user IDs | `op://CDS_Vault/do-snap-bot/allowed-users` |

> **WARNING:** Never write raw tokens to `.env.op`, commit files containing secrets, or store tokens in shell history.

#### 2.3 Create a 1Password service account

The controller droplet runs `op run` non-interactively. A service account token provides that access without exposing your personal 1Password credentials.

1. Go to [1password.com](https://1password.com) → **Developer** → **Service Accounts** → **New Service Account**.
2. Name it something descriptive (e.g., `do-snap-bot-controller`).
3. Grant **read** access to the `CDS_Vault` vault (or a dedicated vault containing only the `do-snap-bot` item).
4. Click **Generate Token** and copy the value (begins with `ops_`). **It is shown only once.**

You will paste this token into `cloud-init/controller.yml` in Step 3.

---

### 3. Launch the controller droplet

The Slack bot runs on a dedicated **$6/mo DigitalOcean droplet** (1 vCPU, 1 GB RAM). Cloud-init provisions all dependencies automatically.

#### 3.1 Prepare cloud-init/controller.yml

Open `cloud-init/controller.yml` and replace both placeholders:

| Placeholder | Replace with |
|-------------|-------------|
| `<YOUR_SSH_PUBLIC_KEY>` | Your SSH public key (`cat ~/.ssh/id_ed25519.pub`) |
| `<OP_SERVICE_ACCOUNT_TOKEN>` | The service account token from Step 2.3 |

> **WARNING:** Do not commit `controller.yml` after filling in the service account token. Work from a local copy — the file is in `.gitignore`.

#### 3.2 Create the controller droplet

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

#### 3.3 Verify the droplet

```bash
ssh dosnap@<controller-ip>
doctl version      # should print the doctl version
op --version       # should print the 1Password CLI version
uv --version       # should print the uv version
```

---

### 4. Deploy the bot

#### 4.1 Sync the bot code to the controller

```bash
# From your local machine:
rsync -av slack-bot/ dosnap@<controller-ip>:/opt/do-snap-bot/
```

#### 4.2 Configure and start the bot

```bash
# On the controller:
ssh dosnap@<controller-ip>
cd /opt/do-snap-bot
cp .env.op.example .env.op
# Verify the op:// paths in .env.op match what you created in Step 2.2
sudo systemctl start do-snap-bot
sudo journalctl -u do-snap-bot -f
```

You should see `⚡️ Bolt app is running!` in the logs within a few seconds of starting.

#### 4.3 Test in Slack

In your `#do-ops` channel:

```
/do-snapshot                          → lists droplets or begins a snapshot job
/do-restore                           → lists recent snapshots
/do-restore web-server-20260526       → restore a specific snapshot by name or ID
/do-deploy-cancel abc123              → cancel a running job by its job ID
```

---

## Running Locally (Development)

Requires: `op` CLI signed in, `uv` installed.

```bash
cd slack-bot
cp .env.op.example .env.op
# Verify .env.op op:// paths are correct
./start.sh
```

Without 1Password:

```bash
export SLACK_BOT_TOKEN=xoxb-...
export SLACK_APP_TOKEN=xapp-...
export SLACK_SIGNING_SECRET=...
export DIGITALOCEAN_ACCESS_TOKEN=dop_v1_...
export SLACK_ALLOWED_USERS=U01AB2CD3
uv run python bot.py
```

---

## Managing the Service

```bash
sudo systemctl status do-snap-bot      # current status
sudo systemctl restart do-snap-bot     # restart after code changes
sudo systemctl stop do-snap-bot        # stop
sudo journalctl -u do-snap-bot -n 100  # last 100 log lines
sudo journalctl -u do-snap-bot -f      # follow live logs
```

To deploy an update:

```bash
# From your local machine:
rsync -av slack-bot/ dosnap@<controller-ip>:/opt/do-snap-bot/

# On the controller:
sudo systemctl restart do-snap-bot
sudo journalctl -u do-snap-bot -f
```

---

## Variables Reference

| Variable | Where it lives | Description |
|----------|----------------|-------------|
| `SLACK_BOT_TOKEN` | `.env.op` | `xoxb-…` bot user OAuth token |
| `SLACK_APP_TOKEN` | `.env.op` | `xapp-…` socket mode app token |
| `SLACK_SIGNING_SECRET` | `.env.op` | Slack request signing secret |
| `DIGITALOCEAN_ACCESS_TOKEN` | `.env.op` | DigitalOcean API token for bot operations |
| `SLACK_ALLOWED_USERS` | `.env.op` | Comma-separated Slack member IDs allowed to run commands |
| `OP_SERVICE_ACCOUNT_TOKEN` | `/etc/do-snap-bot/env` on controller | 1Password service account token for non-interactive `op run` |

All secrets except `OP_SERVICE_ACCOUNT_TOKEN` are resolved at runtime by `op run` — they never touch disk on the controller droplet.

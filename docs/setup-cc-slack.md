# Slack Bot Setup & Testing

Assumes **`docs/setup-cc.md` Parts 1–3** are complete (DO API token, doctl context, 1Password CLI signed in).

---

## Part 1 — Create the Slack App

### 1.1 Create a dedicated channel

In Slack, create a channel for bot operations (e.g. `#do-ops`). Invite the team members who should have access.

### 1.2 Create the app from the manifest

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest**.
2. Select your workspace.
3. Paste the full contents of **`slack-bot/manifest.yml`** into the YAML tab. Click **Next** → **Create**.

### 1.3 Enable Socket Mode and get the app-level token

1. In the app settings sidebar → **Settings** → **Socket Mode** → toggle **On**.
2. Under **App-Level Tokens** → **Generate** → name it `socket-token`, add scope `connections:write` → **Generate**.
3. Copy the `xapp-…` token — this is **`SLACK_APP_TOKEN`**.

### 1.4 Install the app and get the bot token

1. Sidebar → **Settings** → **Install App** → **Install to Workspace** → **Allow**.
2. Copy the `xoxb-…` token — this is **`SLACK_BOT_TOKEN`**.

### 1.5 Copy the signing secret

1. Sidebar → **Settings** → **Basic Information** → **App Credentials**.
2. Click **Show** next to **Signing Secret** — this is **`SLACK_SIGNING_SECRET`**.

### 1.6 Invite the bot to your channel

In Slack, open `#do-ops` and run:

```
/invite @DO Snap Bot
```

### 1.7 Get your Slack user ID (for the allow-list)

In Slack, click your name → **⋮** (More actions) → **Copy member ID**. Repeat for any other operators. Format: `U01AB2CD3,U04XY5EF6`.

---

## Part 2 — Store Secrets in 1Password

You need all five values from Part 1 plus your Slack bot's DO API token (the `snaprestore-bot` token from `setup-cc.md` Part 1).

```bash
op item create \
  --category login \
  --title "do-snap-bot" \
  --vault Private \
  "slack-bot-token=xoxb-YOUR_BOT_TOKEN" \
  "slack-app-token=xapp-YOUR_APP_TOKEN" \
  "signing-secret=YOUR_SIGNING_SECRET" \
  "do-token=dop_v1_YOUR_BOT_DO_TOKEN" \
  "allowed-users=U01AB2CD3"
```

Verify the paths resolve:

```bash
op read "op://Private/do-snap-bot/slack-bot-token"
op read "op://Private/do-snap-bot/do-token"
```

### 2.1 Create a 1Password service account

The controller droplet runs `op run` non-interactively and needs a service account token.

1. Go to [1password.com](https://1password.com) → **Developer** → **Service Accounts** → **New Service Account**.
2. Name it `do-snap-bot-controller`.
3. Grant **read** access to the `Private` vault.
4. Click **Generate Token** — copy the `ops_…` value. **Shown once only.**

---

## Part 3 — Prepare `controller.yml`

**Do not commit `controller.yml` after editing — it contains a live service account token.**

Open `slack-bot/cloud-init/controller.yml` and replace both placeholders:

| Placeholder | Replace with |
|-------------|-------------|
| `<YOUR_SSH_PUBLIC_KEY>` | Output of `cat ~/.ssh/id_ed25519.pub` |
| `<OP_SERVICE_ACCOUNT_TOKEN>` | The `ops_…` token from Part 2.1 |

---

## Part 4 — Create the Controller Droplet

1. Log in to [cloud.digitalocean.com](https://cloud.digitalocean.com) → **Droplets** → **Create Droplet**.
2. Configure:
   - **Image:** Ubuntu 22.04 (LTS) x64
   - **Size:** Basic → Regular CPU → **$6/mo** (1 vCPU, 1 GB RAM, 25 GB SSD)
   - **Region:** match your other droplets
   - **Authentication:** SSH Key — select your key
3. Expand **Advanced Options** → **Add Initialization scripts (free)** → paste the full contents of your edited `controller.yml`.
4. Click **Create Droplet**.

Cloud-init takes **3–5 minutes**. Monitor progress:

```bash
ssh dosnap@<controller-ip> "sudo tail -f /var/log/cloud-init-output.log"
```

When it settles, verify the tools are installed:

```bash
ssh dosnap@<controller-ip>
doctl version
op --version
uv --version
```

---

## Part 5 — Deploy the Bot

From your **local machine**:

```bash
rsync -av slack-bot/ dosnap@<controller-ip>:/opt/do-snap-bot/
```

On the **controller**:

```bash
ssh dosnap@<controller-ip>
cd /opt/do-snap-bot
cp .env.op.example .env.op
```

Verify `.env.op` — the `op://` paths should match what you created in Part 2:

```
SLACK_BOT_TOKEN=op://Private/do-snap-bot/slack-bot-token
SLACK_APP_TOKEN=op://Private/do-snap-bot/slack-app-token
SLACK_SIGNING_SECRET=op://Private/do-snap-bot/signing-secret
DIGITALOCEAN_ACCESS_TOKEN=op://Private/do-snap-bot/do-token
SLACK_ALLOWED_USERS=op://Private/do-snap-bot/allowed-users
```

Start the service and watch the logs:

```bash
sudo systemctl start do-snap-bot
sudo journalctl -u do-snap-bot -f
```

You should see `⚡️ Bolt app is running!` within a few seconds.

---

## Part 6 — Testing

### 6.1 Pre-flight checks

```bash
# Service is running
ssh dosnap@<controller-ip> sudo systemctl status do-snap-bot

# Tail logs in a second terminal during testing
ssh dosnap@<controller-ip> sudo journalctl -u do-snap-bot -f
```

### 6.2 Test `/do-snapshot`

In `#do-ops`:

```
/do-snapshot
```

Expected: bot replies with a list of your droplets. Select one, step through the shutdown confirmation, name the snapshot, confirm. Watch the thread for progress updates. When complete the bot should report the snapshot ID and size.

### 6.3 Test `/do-restore`

```
/do-restore
```

Expected: bot lists recent snapshots. Select the one just created, let it run. When complete the bot should report the new droplet ID and IP.

### 6.4 Test cancellation

Start a long operation (snapshot or restore), then in the same channel:

```
/do-deploy-cancel <job-id>
```

The job ID is shown in the bot's first reply in the thread.

### 6.5 Verify allow-list

Try running a slash command from a Slack account **not** in `SLACK_ALLOWED_USERS`. The bot should respond with a permission-denied message and not execute the operation.

---

## Managing the Service

```bash
sudo systemctl status do-snap-bot       # current status
sudo systemctl restart do-snap-bot      # restart after code changes
sudo systemctl stop do-snap-bot         # stop
sudo journalctl -u do-snap-bot -n 100   # last 100 log lines
sudo journalctl -u do-snap-bot -f       # follow live
```

To deploy an update:

```bash
# Local machine:
rsync -av slack-bot/ dosnap@<controller-ip>:/opt/do-snap-bot/

# Controller:
sudo systemctl restart do-snap-bot
sudo journalctl -u do-snap-bot -f
```

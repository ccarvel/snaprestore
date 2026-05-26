# Setup Guide

Complete first-time setup from zero to a working snapshot/restore workflow, including the optional Slack bot. Follow the parts in order.

**Parts 1–4** cover the scripts only. **Parts 5–6** add the Slack bot — skip if you don't need it.

---

## Part 1 — Install tools

```bash
brew install doctl jq 1password-cli fzf gum
```

Verify:

```bash
doctl version && jq --version && op --version
```

---

## Part 2 — DigitalOcean API tokens

You need two tokens: one for the scripts, one for the Slack bot. Keep them separate so you can revoke them independently.

Go to [cloud.digitalocean.com/account/api/tokens](https://cloud.digitalocean.com/account/api/tokens) → **Generate New Token** → **Custom Scopes**.

### Token 1 — Scripts (`snaprestore-scripts`)

| Scope | Required by |
|-------|-------------|
| `droplet:read` | Both scripts |
| `droplet:create` | `do-restore.sh` |
| `droplet:update` | `do-snapshot.sh` — shutdown, power-off, snapshot action |
| `droplet:delete` | `do-snapshot.sh` — delete after snapshot (optional) |
| `image:create` | Both — snapshot creation goes through the images API |
| `snapshot:read` | Both scripts |
| `snapshot:delete` | `do-snapshot.sh` — prune old snapshots |
| `ssh_key:read` | `do-restore.sh` — attach SSH key at creation |
| `reserved_ip:read` | Both scripts |
| `reserved_ip:update` | `do-restore.sh` — assign reserved IP |
| `action:read` | `do-restore.sh` — poll reserved IP assignment status |

> **Missing `droplet:create` is the most common setup mistake.** Without it, the restore wizard completes normally but no droplet is created and no error is shown.

Copy the token — shown only once — and store it in 1Password immediately.

### Token 2 — Slack bot (`snaprestore-bot`)

Same scope set as above. The bot makes identical DO API calls to the scripts. Store this one separately in 1Password.

> The "Droplet Action" scope no longer exists in DigitalOcean's current UI. Snapshot creation is covered by `droplet:update`.

---

## Part 3 — 1Password

### 3.1 Sign in

```bash
op signin
op account list   # confirm you're signed in
```

### 3.2 Store the scripts token

```bash
op item create \
  --category login \
  --title "DigitalOcean API Token snaprestore-scripts" \
  --vault <your-vault> \
  "credential=dop_v1_YOUR_TOKEN_HERE"
```

Verify it resolves:

```bash
op read "op://<your-vault>/DigitalOcean API Token snaprestore-scripts/credential"
```

### 3.3 Store the bot secrets (after completing Part 5)

Once you have the Slack tokens from Part 5, run:

```bash
op item create \
  --category login \
  --title "do-snap-bot" \
  --vault <your-vault> \
  "slack-bot-token=xoxb-YOUR_BOT_TOKEN" \
  "slack-app-token=xapp-YOUR_APP_TOKEN" \
  "signing-secret=YOUR_SIGNING_SECRET" \
  "do-token=dop_v1_YOUR_BOT_DO_TOKEN" \
  "allowed-users=U01AB2CD3"
```

The resulting paths (used in `slack-bot/.env.op`):

| Secret | Path |
|--------|------|
| Slack bot token | `op://<your-vault>/do-snap-bot/slack-bot-token` |
| Slack app token | `op://<your-vault>/do-snap-bot/slack-app-token` |
| Signing secret | `op://<your-vault>/do-snap-bot/signing-secret` |
| DO API token | `op://<your-vault>/do-snap-bot/do-token` |
| Allowed user IDs | `op://<your-vault>/do-snap-bot/allowed-users` |

### 3.4 Create a service account for the controller droplet

The controller runs `op run` non-interactively and needs a service account token.

1. Go to [1password.com](https://1password.com) → **Developer** → **Service Accounts** → **New Service Account**.
2. Name it `do-snap-bot-controller`.
3. Grant **read** access to `<your-vault>`.
4. Copy the `ops_…` token — shown only once.

> If your organization manages 1Password and you can't create service accounts, see [`docs/setup-op-fix.md`](setup-op-fix.md).

---

## Part 4 — Authenticate doctl and test the scripts

### 4.1 Authenticate

```bash
doctl auth init --context snaprestore
```

Paste your `snaprestore-scripts` token when prompted. It is stored in `~/.config/doctl/config.yaml` (mode 0600) — never written to disk anywhere else.

Verify:

```bash
doctl auth switch --context snaprestore
doctl compute droplet list
```

Both scripts already have `DOCTL_CONTEXT="snaprestore"` set — no script edits needed.

To replace the token later (e.g. after rotating it):

```bash
doctl auth remove --context snaprestore
doctl auth init --context snaprestore
```

### 4.2 Test do-snapshot.sh

```bash
./do-snapshot.sh
```

Walk through the prompts: select a droplet, confirm shutdown, name the snapshot, then choose what to do with the droplet (start / leave / delete). Use `--log snapshot.log` to capture full output.

### 4.3 Test do-restore.sh

```bash
./do-restore.sh
```

Select a snapshot, choose a size, optionally attach an SSH key and assign a reserved IP, then confirm. Use `--log restore.log` to capture full output.

**Stop here if you don't need the Slack bot.**

---

## Part 5 — Create the Slack app

### 5.1 Create a dedicated channel

In Slack, create a channel — e.g. `#do-ops`. Invite anyone who should be able to run commands.

### 5.2 Create the app from the manifest

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest**.
2. Select your workspace.
3. Paste the contents of `slack-bot/manifest.yml` into the YAML tab → **Next** → **Create**.

### 5.3 Enable Socket Mode and get the app-level token

1. Sidebar → **Settings** → **Socket Mode** → toggle **On**.
2. Under **App-Level Tokens** → **Generate** → name it `socket-token`, add scope `connections:write` → **Generate**.
3. Copy the `xapp-…` token — this is `SLACK_APP_TOKEN`.

### 5.4 Install the app and get the bot token

1. Sidebar → **Settings** → **Install App** → **Install to Workspace** → **Allow**.
2. Copy the `xoxb-…` token — this is `SLACK_BOT_TOKEN`.

### 5.5 Copy the signing secret

1. Sidebar → **Basic Information** → **App Credentials**.
2. Click **Show** next to **Signing Secret** — this is `SLACK_SIGNING_SECRET`.

### 5.6 Invite the bot to your channel

```
/invite @DO Snap Bot
```

### 5.7 Get your Slack user ID

Click your name in Slack → **⋮ More actions** → **Copy member ID**. Repeat for each operator. Format: `U01AB2CD3,U04XY5EF6`.

### 5.8 Store secrets in 1Password

You now have all five values. Run the command from Part 3.3.

---

## Part 6 — Deploy the Slack bot

### 6.1 Edit controller.yml

Open `slack-bot/cloud-init/controller.yml` and replace both placeholders:

| Placeholder | Value |
|-------------|-------|
| `<YOUR_SSH_PUBLIC_KEY>` | Output of `cat ~/.ssh/id_ed25519.pub` |
| `<OP_SERVICE_ACCOUNT_TOKEN>` | The `ops_…` token from Part 3.4 |

> **Do not commit `controller.yml` after editing** — it contains a live service account token.

Check for non-ASCII characters before deploying (these silently break cloud-init):

```bash
LC_ALL=C grep -n '[^ -~]' slack-bot/cloud-init/controller.yml
```

No output = clean.

### 6.2 Create the controller droplet

Use `doctl` — do not paste `controller.yml` into the DO console UI (browser paste can introduce invisible characters that break YAML parsing):

```bash
doctl compute ssh-key list                    # find your key ID
doctl compute droplet create do-snap-bot-controller \
  --image ubuntu-22-04-x64 \
  --size s-1vcpu-1gb \
  --region nyc1 \
  --ssh-keys <your-key-id> \
  --user-data-file slack-bot/cloud-init/controller.yml \
  --wait
```

### 6.3 Verify cloud-init completed

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "cloud-init status"
# Expected: status: done

ssh -i ~/.ssh/<your-ssh-key> dosnap@<controller-ip>
# If this fails, dosnap was not created — see docs/troubleshooting.md
```

Once in as dosnap, verify tools:

```bash
doctl version && op --version && uv --version
```

### 6.4 Fix /opt/do-snap-bot permissions (if needed)

If cloud-init didn't create the directory, do it as root:

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> \
  "mkdir -p /opt/do-snap-bot && chown dosnap:dosnap /opt/do-snap-bot"
```

### 6.5 Deploy the bot code

From your local machine:

```bash
rsync -av -e "ssh -i ~/.ssh/<your-ssh-key>" slack-bot/ dosnap@<controller-ip>:/opt/do-snap-bot/
```

### 6.6 Configure and start

On the controller:

```bash
ssh -i ~/.ssh/<your-ssh-key> dosnap@<controller-ip>
cd /opt/do-snap-bot
cp .env.op.example .env.op
nano .env.op   # update op:// paths to match your vault name
```

Verify secrets resolve before starting:

```bash
# On your local machine (where you're signed in to 1Password):
op read "op://<your-vault>/do-snap-bot/slack-bot-token"
op read "op://<your-vault>/do-snap-bot/do-token"
```

Start the service (as root):

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "systemctl start do-snap-bot"
```

Check it's running:

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "systemctl status do-snap-bot"
```

### 6.7 Test in Slack

In `#do-ops`:

```
/do-snapshot      → lists your droplets; walk through the snapshot flow
/do-restore       → lists recent snapshots; walk through the restore flow
```

If the bot doesn't respond, see [docs/troubleshooting.md](troubleshooting.md).

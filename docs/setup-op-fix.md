# 1Password — Org Account Fix

Use this if your organization manages 1Password and you cannot create service accounts or assign vault access yourself.

---

## Option A — Email IT

Use this draft to request the access you need. Adjust the vault name to whatever your org uses.

---

**Subject:** 1Password service account — vault access needed

Hi [Name],

I'm working on an internal tool that uses a 1Password service account to inject secrets into a server process at runtime — no secrets are stored on disk or in code.

I need a service account named `do-snap-bot-controller` created with **read-only** access to `<your-vault>`. The current service account token I have (`cds_dev_infrastructure`) doesn't appear to have access to any vault — when I run `op vault list` authenticated as that token it returns an empty list.

Could you either:
- Grant the existing service account read access to `<your-vault>`, or
- Create a new service account with read access and share the `ops_…` token with me securely

The secrets I'll store in the vault are Slack bot tokens, a Slack signing secret, and a DigitalOcean API token — for an internal snapshot/restore automation tool.

Thanks,
[Your name]

---

## Option B — Use a personal 1Password account

If you have a personal 1Password account where you have full admin control, you can use that instead.

### Step 1 — Create a vault

1. Log in to [1password.com](https://1password.com) with your personal account.
2. Click **New Vault** → name it (e.g. `dev`) → **Create Vault**.

### Step 2 — Add the bot secrets

```bash
op item create \
  --category login \
  --title "do-snap-bot" \
  --vault dev \
  "slack-bot-token=xoxb-YOUR_BOT_TOKEN" \
  "slack-app-token=xapp-YOUR_APP_TOKEN" \
  "signing-secret=YOUR_SIGNING_SECRET" \
  "do-token=dop_v1_YOUR_BOT_DO_TOKEN" \
  "allowed-users=U01AB2CD3"
```

Verify:

```bash
op read "op://dev/do-snap-bot/slack-bot-token"
op read "op://dev/do-snap-bot/do-token"
```

### Step 3 — Create a service account

1. Go to [1password.com](https://1password.com) → **Developer** → **Service Accounts** → **New Service Account**.
2. Name it `do-snap-bot-controller`.
3. Grant **read** access to the vault you created.
4. Copy the `ops_…` token — shown only once.

### Step 4 — Update the controller

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip>
nano /etc/do-snap-bot/env
```

Replace the token value (no quotes):

```
OP_SERVICE_ACCOUNT_TOKEN=ops_YOUR_NEW_TOKEN
```

```bash
chmod 600 /etc/do-snap-bot/env
chown dosnap:dosnap /etc/do-snap-bot/env
```

### Step 5 — Update vault name in .env.op

On the controller:

```bash
ssh -i ~/.ssh/<your-ssh-key> dosnap@<controller-ip>
nano /opt/do-snap-bot/.env.op
```

Replace `op://<old-vault>/` with `op://dev/` (or whatever you named the vault).

### Step 6 — Restart

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "systemctl restart do-snap-bot && systemctl status do-snap-bot"
```

Should show `active (running)`. Test with `/do-snapshot` in Slack.

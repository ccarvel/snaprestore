# 1Password Fix — Personal Account Workaround

Use this if your organization's 1Password account does not allow you to create
service accounts or assign vault access yourself.

---

## Step 1 — Create a vault in your personal 1Password account

1. Log in to [1password.com](https://1password.com) with your **personal** account (not the org/work account).
2. Click **New Vault**.
3. Name it something clear, e.g. `snaprestore`.
4. Click **Create Vault**.

---

## Step 2 — Add the bot secrets to the new vault

Create the `do-snap-bot` item in the new vault:

```bash
op item create \
  --category login \
  --title "do-snap-bot" \
  --vault snaprestore \
  "slack-bot-token=xoxb-YOUR_BOT_TOKEN" \
  "slack-app-token=xapp-YOUR_APP_TOKEN" \
  "signing-secret=YOUR_SIGNING_SECRET" \
  "do-token=dop_v1_YOUR_BOT_DO_TOKEN" \
  "allowed-users=U01AB2CD3"
```

Verify the paths resolve:

```bash
op read "op://snaprestore/do-snap-bot/slack-bot-token"
op read "op://snaprestore/do-snap-bot/do-token"
```

---

## Step 3 — Create a service account in your personal account

1. Go to [1password.com](https://1password.com) → **Developer** → **Service Accounts** → **New Service Account**.
2. Name it `do-snap-bot-controller`.
3. Grant **read** access to the `snaprestore` vault.
4. Click **Generate Token** — copy the `ops_…` value. **Shown once only.**

---

## Step 4 — Update the service account token on the controller

SSH in as root and update `/etc/do-snap-bot/env`:

```bash
ssh -i ~/.ssh/id_m3do root@<controller-ip>
nano /etc/do-snap-bot/env
```

Replace the existing token value with the new `ops_…` token. No quotes:

```
OP_SERVICE_ACCOUNT_TOKEN=ops_YOUR_NEW_TOKEN
```

Save, then verify permissions:

```bash
chmod 600 /etc/do-snap-bot/env
chown dosnap:dosnap /etc/do-snap-bot/env
```

---

## Step 5 — Update vault name in the project

Back on your local machine, update all `op://` paths to use the new vault name:

```bash
grep -rn "CDS_Vault" /path/to/snaprestore --include="*.md" --include="*.sh" --include="*.example"
```

Then do a find-and-replace of `CDS_Vault` with `snaprestore` (or whatever you named the vault) across:

- `README.md`
- `docs/setup.md`
- `docs/setup-slack.md`
- `.env.example`
- `slack-bot/.env.op.example`
- `slack-bot/README-slack-bot.md`
- `do-restore.sh`
- `do-snapshot.sh`

Also update `.env.op` on the controller:

```bash
ssh -i ~/.ssh/id_m3do dosnap@<controller-ip>
nano /opt/do-snap-bot/.env.op
```

Replace every `op://CDS_Vault/` with `op://snaprestore/`.

---

## Step 6 — Restart the service

```bash
ssh -i ~/.ssh/id_m3do root@<controller-ip> "systemctl restart do-snap-bot"
ssh -i ~/.ssh/id_m3do root@<controller-ip> "systemctl status do-snap-bot"
```

Should show `active (running)`. Then test in Slack:

```
/do-snapshot
```

# Next Steps — Deploy `next` Branch to Slack

This document covers everything required to apply the changes from the `next` branch to the live Slack workspace. There are two parts: **Part 1** updates the Slack app configuration (manifest), and **Part 2** deploys the new bot code to the controller droplet.

Complete Part 1 before Part 2. The new commands will return "This app has no handler for…" errors until both parts are done.

---

## Part 1 — Update the Slack App Manifest

The `slack-bot/manifest.yml` has two changes that must be applied at `api.slack.com`:

1. **Bug fix:** `interactivity.is_enabled` was `false` — now correctly `true`. Without this, all Block Kit confirmation buttons silently fail.
2. **9 new slash commands** registered (the app must know about them before the bot can handle them).

### Steps

1. Open [api.slack.com/apps](https://api.slack.com/apps) and select **DO Snap Bot**.

2. In the left sidebar, click **App Manifest**.

3. Click the **YAML** tab.

4. Replace the entire contents with the contents of `slack-bot/manifest.yml` from this branch. You can copy it directly:

   ```bash
   cat slack-bot/manifest.yml | pbcopy
   ```

5. Click **Save Changes**.

6. If Slack shows a diff preview, confirm that:
   - `interactivity.is_enabled` changed from `false` → `true`
   - 9 new commands appear under `slash_commands`:
     - `/do-snapshot-list`
     - `/do-snapshot-delete`
     - `/do-droplet-list`
     - `/do-droplet-create`
     - `/do-droplet-power-on`
     - `/do-droplet-power-off`
     - `/do-droplet-delete`
     - `/do-droplet-resize`
     - `/do-reserved-ip-assign`

7. Click **Save** to confirm.

> **Note:** Slack may prompt you to reinstall the app to the workspace after manifest changes. If it does, click **Reinstall to Workspace → Allow**. Your existing bot token remains valid — no secrets need to change.

---

## Part 2 — Deploy New Bot Code to the Controller Droplet

### 2.1 Sync the updated code

From your local machine (project root):

```bash
rsync -av -e "ssh -i ~/.ssh/id_m3do" slack-bot/ dosnap@104.236.56.16:/opt/do-snap-bot/
```

This syncs all changed files:
- `bot.py` — new commands, helpers, retention, scheduling
- `manifest.yml` — for reference on the controller
- `.env.op.example` — updated with new optional env var templates
- `pyproject.toml` — added optional dev dependencies
- `README-slack-bot.md` — updated command reference

### 2.2 Restart the bot service

```bash
ssh -i ~/.ssh/id_m3do root@104.236.56.16 "systemctl restart do-snap-bot"
```

### 2.3 Verify the service started cleanly

```bash
ssh -i ~/.ssh/id_m3do root@104.236.56.16 "systemctl status do-snap-bot --no-pager"
```

Expected output includes `Active: active (running)`.

### 2.4 Check the bot logs

```bash
ssh -i ~/.ssh/id_m3do root@104.236.56.16 "tail -n 30 /var/log/do-snap-bot.log"
```

Look for `⚡️ Bolt app is running!` — this confirms the bot connected to Slack via Socket Mode.

---

## Part 3 — Smoke Test in Slack

In your `#do-ops` channel (or whichever channel the bot is in), run these commands to confirm the new commands are reachable:

```
/do-snapshot-list
```
→ Should list recent snapshots with size and cost.

```
/do-droplet-list
```
→ Should list all droplets with status emoji, size, region, and IP.

```
/do-restore
```
→ Should now show **snapshot selection buttons** (up to 5) instead of a plain text list.

```
/do-snapshot-delete
```
→ Should show **snapshot selection buttons**, then a delete confirmation.

```
/do-droplet-power-off <your-droplet-name>
```
→ Should show a shutdown confirmation button.

---

## Part 4 (Optional) — Configure Scheduled Snapshots & Retention

These features are off by default. To enable them, edit `.env.op` on the controller and add the relevant variables, then restart the bot.

### SSH into the controller

```bash
ssh -i ~/.ssh/id_m3do dosnap@104.236.56.16
cd /opt/do-snap-bot
```

### Edit .env.op

Add any of these lines (using your actual 1Password `op://` paths or literal values):

```bash
# Auto-snapshot every 24 hours, post results to #do-ops channel
SNAPSHOT_SCHEDULE_INTERVAL_HOURS=24
SNAPSHOT_SCHEDULE_CHANNEL=C01234ABCDE     # your channel ID (right-click channel → Copy link)
SNAPSHOT_SCHEDULE_DROPLET=my-droplet      # omit if you only have one droplet

# Keep only the 5 most recent snapshots per droplet
SNAPSHOT_RETENTION_COUNT=5

# OR: delete snapshots older than 30 days
SNAPSHOT_RETENTION_DAYS=30
```

### Restart to pick up the new env vars

```bash
sudo systemctl restart do-snap-bot
sudo tail -f /var/log/do-snap-bot.log
```

The log should confirm startup without errors. If `SNAPSHOT_SCHEDULE_INTERVAL_HOURS` is set, the first auto-snapshot will run after the configured interval elapses.

---

## Rollback

If the new bot code causes issues, roll back to the previous version:

```bash
# On the controller:
cd /opt/do-snap-bot
sudo systemctl stop do-snap-bot

# On your local machine — revert to the previous bot.py from main branch:
git show main:slack-bot/bot.py > /tmp/bot_rollback.py
rsync -av -e "ssh -i ~/.ssh/id_m3do" /tmp/bot_rollback.py dosnap@104.236.56.16:/opt/do-snap-bot/bot.py

# Restart:
ssh -i ~/.ssh/id_m3do root@104.236.56.16 "systemctl restart do-snap-bot"
```

> **Manifest rollback:** If you need to revert the Slack manifest too, `git show main:slack-bot/manifest.yml | pbcopy` and paste it back at `api.slack.com/apps`.

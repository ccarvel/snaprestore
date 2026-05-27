# Commands Reference

Day-to-day operations cheatsheet. All commands run from the project root unless noted.

---

## Scripts

```bash
# Snapshot a droplet (interactive)
./do-snapshot.sh

# Snapshot with log file
./do-snapshot.sh --log snapshot.log

# Restore from a snapshot (interactive)
./do-restore.sh

# Restore with log file
./do-restore.sh --log restore.log

# Dry-run (no API writes)
./do-snapshot.sh --dry-run
./do-restore.sh --dry-run
```

---

## doctl

```bash
# List droplets
doctl compute droplet list

# List snapshots
doctl compute snapshot list --resource droplet

# List reserved IPs
doctl compute reserved-ip list

# List SSH keys
doctl compute ssh-key list

# Switch to the snaprestore context
doctl auth switch --context snaprestore

# Rotate the context token
doctl auth remove --context snaprestore
doctl auth init --context snaprestore
```

---

## 1Password

```bash
# Verify secrets resolve
op read "op://<your-vault>/do-snap-bot/slack-bot-token"
op read "op://<your-vault>/do-snap-bot/do-token"
op read "op://<your-vault>/DigitalOcean API Token snaprestore-scripts/credential"

# Check signed-in accounts
op account list
```

---

## Bot service (run on the controller or via SSH)

```bash
# SSH into the controller
ssh -i ~/.ssh/<your-ssh-key> dosnap@<controller-ip>

# Service management (requires root)
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "systemctl status do-snap-bot"
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "systemctl start do-snap-bot"
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "systemctl stop do-snap-bot"
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "systemctl restart do-snap-bot"

# Logs
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "cat /var/log/do-snap-bot.log"
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "tail -f /var/log/do-snap-bot.log"
```

---

## Deploy a bot update

```bash
# 1. Push updated code from local machine
rsync -av -e "ssh -i ~/.ssh/<your-ssh-key>" slack-bot/ dosnap@<controller-ip>:/opt/do-snap-bot/

# 2. Restart the service
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "systemctl restart do-snap-bot"

# 3. Verify
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "systemctl status do-snap-bot"
```

---

## Slack commands

| Command | What it does |
|---------|-------------|
| `/do-snapshot` | Lists droplets; walks through snapshot flow |
| `/do-snapshot [name-or-id]` | Snapshots a specific droplet directly |
| `/do-snapshot-list` | Lists recent snapshots with size, age, and estimated cost |
| `/do-snapshot-delete` | Shows snapshot selection buttons; deletes with confirmation |
| `/do-snapshot-delete <id-or-name>` | Deletes a specific snapshot with confirmation |
| `/do-restore` | Shows snapshot selection buttons; walks through restore flow |
| `/do-restore <name-or-id>` | Restores a specific snapshot directly |
| `/do-droplet-list` | Lists all droplets with status, size, region, and IP |
| `/do-droplet-create <name>` | Creates a droplet from a selected snapshot (prompts for image) |
| `/do-droplet-create <name> <size> <image>` | Creates a droplet with all args provided |
| `/do-droplet-power-on <name-or-id>` | Powers on a stopped droplet |
| `/do-droplet-power-off <name-or-id>` | Graceful shutdown with confirmation (power-off fallback) |
| `/do-droplet-delete <name-or-id>` | Deletes a droplet with confirmation; warns if no recent snapshot |
| `/do-droplet-resize <name-or-id> <size>` | Resizes a droplet (powers off first, offers to restart) |
| `/do-reserved-ip-assign <ip> <name-or-id>` | Reassigns a reserved IP to a running droplet |
| `/do-deploy-cancel <job-id>` | Cancels a running job (job ID shown in bot's first reply) |

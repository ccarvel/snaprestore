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
| `/do-restore` | Lists recent snapshots; walks through restore flow |
| `/do-restore <name-or-id>` | Restores a specific snapshot directly |
| `/do-deploy-cancel <job-id>` | Cancels a running job (job ID shown in bot's first reply) |

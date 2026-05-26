# Troubleshooting

Organized by symptom. For first-time setup issues with 1Password service accounts, see [`setup-op-fix.md`](setup-op-fix.md).

---

## Scripts

### Script exits silently after the "Proceed?" prompt

The most common cause is `get_eta` returning a non-zero exit code when no history file exists yet. This is fixed in the current version. If you see it:

1. Check your bash version: `bash --version` — must be 5+. macOS ships Bash 3.2; the scripts require `#!/usr/bin/env bash` which picks up Homebrew Bash 5.
2. Run with a log file to capture the full output: `./do-restore.sh --log restore.log`

### `doctl: command not found`

```bash
brew install doctl
doctl auth init --context snaprestore
```

### `unable to initialize DigitalOcean API client: access token is required`

The scripts authenticate via the `snaprestore` doctl context. Make sure you've run:

```bash
doctl auth init --context snaprestore
```

Do not use `op run --env-file=.env` to invoke the scripts — see the warning below.

### `op run --env-file` breaks doctl authentication

Do not use `op run --env-file=.env` to invoke `do-restore.sh` or `do-snapshot.sh`. When `op run` injects `DIGITALOCEAN_ACCESS_TOKEN` into the environment, doctl ignores `--context snaprestore` and uses that value instead of the stored context token. If the injected token is the Slack bot token (different permissions), droplet create and snapshot calls will fail silently.

Run scripts directly:

```bash
./do-restore.sh --log restore.log
./do-snapshot.sh --log snapshot.log
```

`op run` is correct only for the Slack bot service.

### `No compatible droplet sizes found`

The snapshot's `min_disk_size` is larger than every available size in the region. This happens when the source droplet had a large disk. Options:

- Use a different region that has the required size available
- Start with the smallest adequate droplet next time to maximize restore flexibility

### `Reserved IP assignment did not complete`

Run the manual fallback:

```bash
doctl compute reserved-ip-action assign <IP> <droplet-id>
```

---

## SSH access after restore

### Root login works but a non-root user is rejected

SSH keys injected by DigitalOcean at droplet creation go to `root` only. Non-root users that existed on the source snapshot need their `authorized_keys` updated manually.

Log in as root first, then:

```bash
cp /root/.ssh/authorized_keys /home/<username>/.ssh/authorized_keys
chown <username>:<username> /home/<username>/.ssh/authorized_keys
chmod 600 /home/<username>/.ssh/authorized_keys
```

---

## Controller droplet

### `dosnap` user doesn't exist after cloud-init

Cloud-init completed but the `users:` block didn't run — usually caused by a YAML parse error in `controller.yml`. Check:

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "cloud-init status"
grep -i "error\|fail\|traceback" /var/log/cloud-init-output.log
```

**Most common cause:** non-ASCII characters (em dashes `—`, box-drawing chars `─`) in YAML comments. Check your local file:

```bash
LC_ALL=C grep -n '[^ -~]' slack-bot/cloud-init/controller.yml
```

Any output means the file has non-ASCII characters. Replace them with plain hyphens `-`, then destroy the droplet and recreate.

**Always use `doctl --user-data-file`** — pasting into the DO console can silently introduce encoding characters:

```bash
doctl compute droplet create do-snap-bot-controller \
  --image ubuntu-22-04-x64 \
  --size s-1vcpu-1gb \
  --region nyc1 \
  --ssh-keys <your-key-id> \
  --user-data-file slack-bot/cloud-init/controller.yml \
  --wait
```

If `dosnap` still doesn't exist after a clean cloud-init, create the user manually:

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip>
useradd -m -s /bin/bash -G sudo dosnap
mkdir -p /home/dosnap/.ssh
echo "<your-ssh-public-key>" >> /home/dosnap/.ssh/authorized_keys
chown -R dosnap:dosnap /home/dosnap/.ssh
chmod 700 /home/dosnap/.ssh && chmod 600 /home/dosnap/.ssh/authorized_keys
```

### `uv: command not found` when starting the bot

The cloud-init script previously installed `uv` to `/root/.local/bin/` and symlinked it to `/usr/local/bin/uv`. The symlink is unreadable by `dosnap`. Fix:

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> \
  "curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh"
```

The `controller.yml` file now installs `uv` directly to `/usr/local/bin` — this only affects older droplets.

### `/opt/do-snap-bot` permission denied on rsync

Cloud-init creates the directory, but if it failed or you're working with a manually configured droplet, fix permissions as root first:

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> \
  "mkdir -p /opt/do-snap-bot && chown dosnap:dosnap /opt/do-snap-bot"
```

### Destroying and recreating a failed droplet

```bash
doctl compute droplet delete do-snap-bot-controller
# Then recreate with the fixed controller.yml
```

---

## Bot service

### Bot starts but immediately crashes (exit code 1)

Redirect service output to a file to capture the error:

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> \
  "sed -i 's|StandardOutput=journal|StandardOutput=append:/var/log/do-snap-bot.log|; s|StandardError=journal|StandardError=append:/var/log/do-snap-bot.log|' \
  /etc/systemd/system/do-snap-bot.service && systemctl daemon-reload && systemctl restart do-snap-bot && sleep 5 && cat /var/log/do-snap-bot.log"
```

### `No module named 'aiohttp'`

Install it in the bot's virtualenv:

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> \
  "su - dosnap -s /bin/bash -c 'cd /opt/do-snap-bot && uv add aiohttp'"
```

Then restart the service. `aiohttp` is now declared in `pyproject.toml` — this only affects older deployments.

### `No accounts configured for use with 1Password CLI`

The `OP_SERVICE_ACCOUNT_TOKEN` isn't being picked up. Check `/etc/do-snap-bot/env`:

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip> "cat /etc/do-snap-bot/env"
```

The file must exist and contain:

```
OP_SERVICE_ACCOUNT_TOKEN=ops_YOUR_TOKEN_HERE
```

No quotes around the value. If the file is missing, create it:

```bash
ssh -i ~/.ssh/<your-ssh-key> root@<controller-ip>
mkdir -p /etc/do-snap-bot
nano /etc/do-snap-bot/env
# Add: OP_SERVICE_ACCOUNT_TOKEN=ops_...
chmod 600 /etc/do-snap-bot/env
chown dosnap:dosnap /etc/do-snap-bot/env
```

### `"<vault-name>" isn't a vault in this account`

The 1Password service account token doesn't have access to the vault referenced in `.env.op`. Either:

- The service account was created without vault access assigned — go to 1password.com → **Developer** → **Service Accounts** → edit the account → grant read access to your vault
- The vault name in `.env.op` doesn't match the actual vault name — verify with `op vault list`

See [`setup-op-fix.md`](setup-op-fix.md) if your org manages 1Password and you can't assign vault access yourself.

### No journal entries (`journalctl` returns nothing)

journald may not be configured on the droplet. Use the log file redirect approach described above under "Bot starts but immediately crashes."

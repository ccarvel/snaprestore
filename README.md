# DigitalOcean Snapshot & Restore Scripts

A comprehensive toolkit for managing DigitalOcean droplet snapshots: one script for creating snapshots and one for restoring from them. Designed for cost-effective on-demand server usage—snapshot your droplet, delete it to stop compute charges, then restore later when needed.

## Scripts

| Script | Purpose |
|--------|---------|
| `do-snapshot.sh` | Create a snapshot from an existing droplet |
| `do-restore.sh` | Restore a new droplet from a snapshot |

## Requirements

- `doctl` — Official DigitalOcean CLI
- `jq` — JSON parsing
- `gum` (optional) — For a beautiful, rich CLI experience. The script will offer to install it via Homebrew automatically. Falls back to pure bash ANSI UI if declined.
- `fzf` (optional) — For arrow-key selection menus in fallback UI.
- `op` (optional) — 1Password CLI for secure API token injection.

### Installing dependencies

```bash
# macOS
brew install doctl jq gum 1password-cli

# Ubuntu/Debian
sudo snap install doctl
sudo apt install jq
# 1Password CLI on Ubuntu/Debian — see https://developer.1password.com/docs/cli/get-started/
```

## Configuration & Setup

A `.env.example` file is provided in the repository with all possible configuration options. 

1. Copy `.env.example` to `.env` or inject the variables into your environment.
2. The scripts interact with DigitalOcean through `doctl`. You do NOT need to run `doctl auth init` if you provide the token via environment variable or 1Password.

### Secret Management with 1Password

All credentials should be stored in 1Password and retrieved via `op` — never hardcoded in files or shell history.

**Store secrets (run once):**
```bash
# DigitalOcean Personal Access Token
op item create \
  --category login \
  --title "DigitalOcean PAT" \
  --vault Private \
  username="snaprestore" \
  credential="dop_v1_YOUR_TOKEN_HERE"

# Slack App Signing Secret
op item create \
  --category login \
  --title "SnapRestore Slack App" \
  --vault Private \
  username="snaprestore-slack" \
  signing_secret="YOUR_SLACK_SIGNING_SECRET_HERE"

# AWS SSM Runner Instance ID
op item create \
  --category login \
  --title "SnapRestore Runner" \
  --vault Private \
  username="snaprestore-runner" \
  instance_id="i-0abcdef1234567890"
```

**Read secrets at runtime:**
```bash
# Read individual secrets
op read "op://Private/DigitalOcean PAT/credential"
op read "op://Private/SnapRestore Slack App/signing_secret"
op read "op://Private/SnapRestore Runner/instance_id"
```

**Inject all secrets at once using `op run`:**
```bash
# Create .env.op (gitignored) with op:// references instead of real values:
# DO_API_TOKEN=op://Private/DigitalOcean PAT/credential
# SLACK_SIGNING_SECRET=op://Private/SnapRestore Slack App/signing_secret
# SSM_INSTANCE_ID=op://Private/SnapRestore Runner/instance_id

# Then run scripts with secrets auto-injected — no plaintext on disk:
op run --env-file=".env.op" -- ./do-snapshot.sh
op run --env-file=".env.op" -- ./do-restore.sh
```

### Providing the DigitalOcean token

```bash
# Option 1: 1Password CLI (Most Secure — Recommended)
export DO_API_TOKEN=$(op read "op://Private/DigitalOcean PAT/credential")

# Option 2: op run (secrets never touch shell history)
op run --env-file=".env.op" -- ./do-snapshot.sh

# Option 3: Environment variable
export DO_API_TOKEN="dop_v1_xxxx"

# Option 4: Edit the script's configuration section or .env file
DO_TOKEN="dop_v1_xxxx"

# Option 5: Enter when prompted
./do-snapshot.sh
# ? DigitalOcean API Token: _ (input is hidden)
```

## Features & Enhancements

- **Dynamic UI**: Uses [gum](https://github.com/charmbracelet/gum) for gorgeous interactive menus, spinners, and panels. Gracefully degrades to an ANSI-colored bash interface if gum is unavailable.
- **Dry-Run Mode**: Run `./do-snapshot.sh --dry-run` or `./do-restore.sh --dry-run` to test selections and logic without making any actual API calls to create or delete droplets.
- **Non-Interactive Mode**: Run `./do-snapshot.sh --force` (or `-y`) to skip confirmation prompts. Perfect for CRON jobs or background execution.
- **Resource Caching**: Menus load instantly. Sizes and regions are cached locally in `~/.config/do-snap-tool/` for 24 hours to reduce API calls.
- **Action Logging**: All successful snapshots, restores, and deletes are appended to `~/.local/share/do-snap-tool/action.log` with timestamps.
- **Advanced Restore Options**: Pass optional Droplet Tags, VPC UUIDs, and Cloud-Init user-data files during the restore process.
- **Strict Deletes**: Deleting a droplet requires typing the exact name of the droplet to prevent accidental data loss.
- **Slack Integration**: Serverless webhook architecture included. See `slack-integration/` directory for full AWS Lambda/SSM setup guide.

---

## do-snapshot.sh

Creates a snapshot from an existing droplet following best practices: displays droplet specs, performs a clean shutdown, creates the snapshot, then lets you choose what to do with the original droplet.

### What it does

1. Lists your droplets for selection
2. Displays full droplet specs (size, region, disk, IPs, reserved IP)
3. Prompts for a snapshot name (or uses auto-generated default)
4. Shuts down the droplet gracefully for a clean snapshot
5. Creates the snapshot and waits for completion
6. Displays the new snapshot details
7. Asks what to do with the droplet: start it, leave it off, or delete it (requires typing the name)

### Usage

**Interactive mode:**
```bash
./do-snapshot.sh
```

**List droplets only:**
```bash
export DROPLET_ID="list"
./do-snapshot.sh
```

---

## do-restore.sh

Restores a new droplet from an existing snapshot. Handles size compatibility, SSH keys, tags, VPC, user-data, and reserved IP assignment.

### What it does

1. Lists your snapshots for selection (showing snapshot age)
2. Displays snapshot details (size, minimum disk requirement, region)
3. Lists compatible droplet sizes (filters to sizes with sufficient disk space)
4. Configures SSH keys, Tags, VPC, and Cloud-Init
5. Optionally assigns a reserved IP
6. Creates the droplet and waits for it to become active
7. Displays connection information

### Usage

**Interactive mode:**
```bash
./do-restore.sh
```

**List resources:**
```bash
export SNAPSHOT_ID="list"      # List snapshots
export SSH_KEY_ID="list"       # List SSH keys
export SIZE_SLUG="list"        # List compatible sizes (requires SNAPSHOT_ID set)
export RESERVED_IP="list"      # List reserved IPs

./do-restore.sh
```

---

## Slack Integration / Serverless Invocation

The scripts now support being triggered securely via an AWS API Gateway + AWS Lambda webhook from Slack. 

Please see the [slack-integration/README_slack_integration.md](slack-integration/README_slack_integration.md) file for comprehensive, step-by-step documentation on how to provision the serverless architecture.

---

## Docker Auto-Start Configuration

For Docker containers to start automatically when restoring from a snapshot, you need two things configured on the original droplet:

### 1. Enable Docker service on boot

```bash
sudo systemctl enable docker
```

### 2. Set restart policy on containers

**For `docker run`:**
```bash
docker run -d --restart=unless-stopped myapp
```

**For `docker-compose.yml`:**
```yaml
services:
  myapp:
    image: myapp:latest
    restart: unless-stopped
```

After fixing, create a new snapshot so future restores work automatically.

---

## License

MIT — use freely.
# DigitalOcean Snapshot Scripts

Two companion scripts for managing DigitalOcean droplet snapshots: one for creating snapshots and one for restoring from them. Designed for cost-effective on-demand server usage—snapshot your droplet, delete it to stop compute charges, then restore later when needed.

## Scripts

| Script | Purpose |
|--------|---------|
| `do-snapshot_sh.sh` | Create a snapshot from an existing droplet |
| `do-restore_sh.sh` | Restore a new droplet from a snapshot |

## Requirements

- `doctl` — Official DigitalOcean CLI (handles API polling and output)
- `jq` — for JSON parsing
- `fzf` (optional) — for arrow-key selection menus; falls back to numbered menus if not installed
- `op` (optional) — 1Password CLI for secure API token injection

### Installing dependencies

```bash
# macOS
brew install doctl jq fzf 1password-cli

# Ubuntu/Debian
sudo snap install doctl
sudo apt install jq fzf
```

## API Token Setup

The scripts interact with DigitalOcean through `doctl`. You do NOT need to run `doctl auth init` if you provide the token via environment variable or prompt. The token is never logged or saved to disk.

### Providing the token

```bash
# Option 1: 1Password CLI (Most Secure)
# The scripts will automatically look for `op` and can fetch the token.
# Update the scripts' CONFIGURATION sections to point to your vault path:
# DO_TOKEN=$(op read "op://Private/DigitalOcean/credential" 2>/dev/null)

# Option 2: Environment variable
export DO_API_TOKEN="dop_v1_xxxx"

# Option 3: Edit the script's configuration section
DO_TOKEN="dop_v1_xxxx"

# Option 4: Enter when prompted
./do-snapshot_sh.sh
# DigitalOcean API Token: _ (input is hidden)
```

## Features & Enhancements

- **Dry-Run Mode**: Run `./do-snapshot_sh.sh --dry-run` or `./do-restore_sh.sh --dry-run` to test selections and logic without making any actual API calls to create or delete droplets.
- **Resource Caching**: Menus load instantly. Sizes and regions are cached locally in `~/.config/do-snap-tool/` for 24 hours to reduce API calls.
- **Action Logging**: All successful snapshots, restores, and deletes are appended to `~/.local/share/do-snap-tool/action.log` with timestamps.
- **Advanced Restore Options**: You can now pass optional Droplet Tags, VPC UUIDs, and Cloud-Init user-data files during the restore process.
- **Strict Deletes**: Deleting a droplet now requires typing the exact name of the droplet to prevent accidental data loss.

---

## do-snapshot_sh.sh

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
./do-snapshot_sh.sh
```

**List droplets only:**
```bash
# Edit script:
DROPLET_ID="list"

# Then run:
./do-snapshot_sh.sh
```

---

## do-restore_sh.sh

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
./do-restore_sh.sh
```

**List resources:**
```bash
# Edit script with any of these:
SNAPSHOT_ID="list"      # List snapshots
SSH_KEY_ID="list"       # List SSH keys
SIZE_SLUG="list"        # List compatible sizes (requires SNAPSHOT_ID set)
RESERVED_IP="list"      # List reserved IPs

# Then run:
./do-restore_sh.sh
```

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
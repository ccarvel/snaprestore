# DigitalOcean Snapshot Scripts

Two companion scripts for managing DigitalOcean droplet snapshots: create a snapshot from a running droplet, then restore a new droplet from that snapshot. Designed for cost-effective on-demand usage — snapshot and delete when idle, restore when needed, with the same reserved IP so DNS and Cloudflare configs remain valid.

## Scripts

| Script | Purpose |
|--------|---------|
| `do-snapshot.sh` | Snapshot an existing droplet, then start / leave / delete it |
| `do-restore.sh` | Create a new droplet from a snapshot and assign a reserved IP |

---

## Requirements

### Required

| Tool | Purpose | Install |
|------|---------|---------|
| `doctl` | DigitalOcean CLI — replaces all raw API calls | `brew install doctl` |
| `jq` | JSON parsing for doctl output | `brew install jq` |

### Optional

| Tool | Purpose | Install |
|------|---------|---------|
| `fzf` | Arrow-key selection menus (falls back to numbered menus) | `brew install fzf` |
| `1password-cli` | Secure token injection via `op read` | `brew install 1password-cli` |

### Ubuntu/Debian equivalents

```bash
# doctl — download the binary directly (no apt package)
curl -sL https://github.com/digitalocean/doctl/releases/latest/download/doctl-*-linux-amd64.tar.gz \
  | tar -xz && sudo mv doctl /usr/local/bin

sudo apt install jq fzf
```

---

## One-Time Setup

### 1. Authenticate doctl

```bash
doctl auth init --context snaprestore
# Paste your DigitalOcean API token when prompted.
# The token is stored in ~/.config/doctl/config.yaml (mode 0600).
# It is never written to a script file or shell history.
```

Set the context name in both scripts:

```bash
DOCTL_CONTEXT="snaprestore"   # in do-snapshot.sh and do-restore.sh config block
```

### 2. (Optional) 1Password integration

Store your token in 1Password, then set `OP_ITEM` in the config block:

```bash
OP_ITEM="op://Private/DigitalOcean API Token/credential"
```

Create the vault item:

```bash
op item create \
  --category login \
  --title "DigitalOcean API Token" \
  --vault Private \
  "credential=dop_v1_xxxx"
```

The scripts will call `op read "$OP_ITEM"` at startup. If `op` is not installed or the read fails, they fall back to the `DIGITALOCEAN_ACCESS_TOKEN` environment variable, then prompt interactively (with hidden input).

**Recommended vault path convention:**

| Secret | 1Password path |
|--------|---------------|
| DO API token | `op://Private/DigitalOcean API Token/credential` |

### 3. API token scopes

Create a custom-scoped token at [DigitalOcean API Tokens](https://cloud.digitalocean.com/account/api/tokens).

**`do-snapshot.sh` requires:**

| Resource | Permissions |
|----------|-------------|
| Droplet | read, delete |
| Droplet Action | create (shutdown, power-off, power-on, snapshot) |
| Snapshot | read |
| Reserved IP | read |

**`do-restore.sh` requires:**

| Resource | Permissions |
|----------|-------------|
| Droplet | read, create |
| Droplet Action | create |
| Snapshot | read |
| SSH Key | read |
| Reserved IP | read, update |

---

## Token Loading Order

Both scripts resolve the token in this order (first non-empty value wins):

1. `OP_ITEM` config var → calls `op read` if `op` CLI is present
2. `DIGITALOCEAN_ACCESS_TOKEN` environment variable
3. `DO_API_TOKEN` environment variable (legacy fallback)
4. `DOCTL_CONTEXT` config var → doctl uses its stored context token (no env var needed)
5. Interactive prompt — input is hidden (`read -rsp`)

**Never hardcode a token in the script.** Use one of the methods above.

To inject via environment without hardcoding:

```bash
export DIGITALOCEAN_ACCESS_TOKEN="$(op read 'op://Private/DigitalOcean API Token/credential')"
./do-snapshot.sh
```

Or use `op run` to inject automatically:

```bash
op run --env-file=.env -- ./do-snapshot.sh
# .env contains: DIGITALOCEAN_ACCESS_TOKEN=op://Private/DigitalOcean API Token/credential
```

---

## do-snapshot.sh

Snapshots an existing droplet. Performs a clean shutdown first, waits for the action to complete, then lets you start, leave, or delete the droplet.

### Flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Print every operation that would run; make no API calls |
| `--quiet` | Suppress all non-error output |
| `--json` | Emit final state as a JSON object on stdout |
| `--log FILE` | Tee all output to FILE (appends) |
| `--help` | Show usage |

### Configuration block

```bash
DROPLET_ID=""       # Set to a droplet ID, or leave blank for interactive selection
SNAPSHOT_NAME=""    # Optional: defaults to {droplet-name}-snapshot-{YYYYMMDD-HHMM}
OP_ITEM=""          # Optional: op://Vault/Item/field
DOCTL_CONTEXT=""    # Optional: doctl auth context, e.g. "snaprestore"
```

### Usage

```bash
# Fully interactive
./do-snapshot.sh

# List droplets only
DROPLET_ID="list" ./do-snapshot.sh    # or edit config var

# Dry-run (no API writes)
./do-snapshot.sh --dry-run

# Log to file
./do-snapshot.sh --log ~/.local/share/do-snap-tool/snapshot-$(date +%Y%m%d).log

# JSON output (for scripting)
./do-snapshot.sh --json 2>/dev/null | jq .snapshot_id
```

### Example session

```
$ ./do-snapshot.sh

  Fetching droplets...

Select droplet to snapshot:
> 123456789|web-server|active|s-2vcpu-4gb|nyc1|80GB
  987654321|dev-box|off|s-1vcpu-1gb|sfo3|25GB

========================================
  Droplet Details
========================================
  ID:          123456789
  Name:        web-server
  Status:      active
  Region:      nyc1
  Size:        s-2vcpu-4gb
  vCPUs:       2
  Memory:      4096MB
  Disk:        80GB
  Public IP:   164.90.xxx.xxx
  Reserved IP: 167.99.xxx.xxx

  Snapshot name [web-server-snapshot-20260526-1430]:

  Snapshot will be named: web-server-snapshot-20260526-1430

Proceed with snapshot? (y/n): y

  Shutting down droplet for clean snapshot...
  ✓ Droplet stopped.

  Creating snapshot 'web-server-snapshot-20260526-1430' (this may take several minutes)...
  ✓ Snapshot complete.

  Fetching snapshot details...

========================================
  Snapshot Created
========================================
  ID:         119876543
  Name:       web-server-snapshot-20260526-1430
  Compressed: 12.34GB  (source disk: 80GB)
  Regions:    nyc1
  Est. cost:  ~$0.74/mo

  Restore:    ./do-restore.sh  # select: web-server-snapshot-20260526-1430

What to do with the droplet?
> start|Start it back up
  leave|Leave it shut down (billing continues)
  delete|Delete/destroy it

  Starting droplet...
  ✓ Droplet is active.
  Connect: ssh root@167.99.xxx.xxx

  ✓ Done.
```

### JSON output shape

```json
{
  "droplet_id":    "123456789",
  "droplet_name":  "web-server",
  "snapshot_id":   "119876543",
  "snapshot_name": "web-server-snapshot-20260526-1430",
  "snapshot_size_gb": 12.34,
  "min_disk_gb":   80,
  "regions":       ["nyc1"],
  "post_action":   "start",
  "reserved_ip":   "167.99.xxx.xxx"
}
```

---

## do-restore.sh

Creates a new droplet from a snapshot, waits for it to become active, then assigns a reserved IP.

### Flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Print every operation that would run; make no API calls |
| `--quiet` | Suppress all non-error output |
| `--json` | Emit final state as a JSON object on stdout |
| `--log FILE` | Tee all output to FILE (appends) |
| `--tags TAGS` | Comma-separated tags to apply to the new droplet |
| `--help` | Show usage |

### Configuration block

```bash
SNAPSHOT_ID=""      # Snapshot ID, or leave blank for interactive selection
SSH_KEY_ID=""       # SSH key ID (comma-separated for multiple), or blank to prompt
SIZE_SLUG=""        # Droplet size slug, or blank to prompt
DROPLET_NAME=""     # Optional: defaults to restored-{snapshot-name}-{YYYYMMDD}
RESERVED_IP=""      # Reserved IP to assign, or blank to prompt
OP_ITEM=""          # Optional: op://Vault/Item/field
DOCTL_CONTEXT=""    # Optional: doctl auth context, e.g. "snaprestore"
```

### Usage

```bash
# Fully interactive
./do-restore.sh

# List resources
SNAPSHOT_ID="list"  ./do-restore.sh    # List snapshots
SSH_KEY_ID="list"   ./do-restore.sh    # List SSH keys
SIZE_SLUG="list"    ./do-restore.sh    # List compatible sizes (requires SNAPSHOT_ID set)
RESERVED_IP="list"  ./do-restore.sh    # List reserved IPs

# With tags
./do-restore.sh --tags "project:dh,env:prod"

# Dry-run
./do-restore.sh --dry-run

# JSON output
./do-restore.sh --json 2>/dev/null | jq .connect_ip
```

### Example session

```
$ ./do-restore.sh

  Fetching snapshots...

Select snapshot:
> 119876543|web-server-snapshot-20260526-1430|12.34GB|min:80GB|nyc1|0d ago
  118765432|dev-backup-20251215|5.67GB|min:25GB|sfo3|162d ago

  Selected:     web-server-snapshot-20260526-1430
  Compressed:   12.34GB  (source disk: 80GB)
  Created:      2026-05-26T14:30:00Z  (0 days ago)
  Regions:      nyc1

  Fetching compatible droplet sizes...

Select droplet size:
> s-2vcpu-4gb|2vCPU|4096MB|80GB disk|$24/mo
  s-4vcpu-8gb|4vCPU|8192MB|160GB disk|$48/mo

  Size: s-2vcpu-4gb

  Fetching SSH keys...
  Attach an SSH key? (y/n): y

Select SSH key:
> 12345678|my-macbook

  SSH key: 12345678

  Assign a reserved IP? (y/n): y

Select reserved IP:
> 167.99.xxx.xxx|unassigned|nyc1

  Reserved IP: 167.99.xxx.xxx
  Droplet name [restored-web-server-snapshot-20260526-1430-20260526]: web-server

========================================
  Creating Droplet
========================================
  Name:        web-server
  Size:        s-2vcpu-4gb
  Region:      nyc1
  Image:       119876543 (web-server-snapshot-20260526-1430)
  SSH Key:     12345678
  Reserved IP: 167.99.xxx.xxx

Proceed? (y/n): y

  Creating droplet (this may take 1–2 minutes)...
  ✓ Droplet active.  ID: 456789123  IP: 164.90.xxx.xxx

  Assigning reserved IP 167.99.xxx.xxx to droplet 456789123...
  ✓ Reserved IP assigned.

========================================
  Done
========================================
  Droplet ID:    456789123
  Droplet IP:    164.90.xxx.xxx
  Reserved IP:   167.99.xxx.xxx

  Connect:       ssh root@167.99.xxx.xxx
```

### JSON output shape

```json
{
  "droplet_id":    "456789123",
  "droplet_name":  "web-server",
  "droplet_ip":    "164.90.xxx.xxx",
  "reserved_ip":   "167.99.xxx.xxx",
  "connect_ip":    "167.99.xxx.xxx",
  "snapshot_id":   "119876543",
  "snapshot_name": "web-server-snapshot-20260526-1430",
  "size":          "s-2vcpu-4gb",
  "region":        "nyc1",
  "tags":          ["project:dh", "env:prod"]
}
```

---

## Docker Auto-Start Configuration

For Docker containers to start automatically after a restore:

### 1. Enable Docker on boot

```bash
sudo systemctl enable docker
sudo systemctl is-enabled docker    # should output: enabled
```

### 2. Set restart policy on containers

```bash
# docker run
docker run -d --restart=unless-stopped myapp

# docker-compose.yml
services:
  myapp:
    image: myapp:latest
    restart: unless-stopped
```

| Policy | Behavior |
|--------|----------|
| `no` | Never restart (default) |
| `always` | Always restart, including on daemon start |
| `unless-stopped` | Restart unless manually stopped — recommended |
| `on-failure` | Restart only on non-zero exit code |

### 3. Verify before snapshotting

```bash
sudo systemctl is-enabled docker
docker inspect --format '{{.Name}}: {{.HostConfig.RestartPolicy.Name}}' $(docker ps -aq)
```

### Cloudflare Tunnels

If you use `cloudflared`, give it `restart: unless-stopped` in your compose file. The tunnel reconnects automatically on boot — no IP updates needed since traffic routes through Cloudflare, and the reserved IP remains constant across snapshot/restore cycles.

---

## Typical Workflow

### Cost-saving on-demand usage

1. **Snapshot and delete** when not needed:
   ```bash
   ./do-snapshot.sh
   # Select droplet → name snapshot → choose "delete"
   # ~$0.74/mo snapshot storage vs. ~$24/mo running droplet
   ```

2. **Restore when needed**:
   ```bash
   ./do-restore.sh
   # Select snapshot → choose size → assign reserved IP
   # Same IP, same DNS, same Cloudflare config
   ```

3. **Tips:**
   - Reserved IPs preserve your IP across cycles. Keep them assigned.
   - Snapshot while off ensures filesystem consistency — both scripts handle this.
   - `min_disk_size` is locked to the source droplet's total disk at snapshot time, not actual used space. Use the smallest adequate disk droplet to maximize restore flexibility.
   - Snapshot names default to `{droplet-name}-snapshot-{YYYYMMDD-HHMM}` — unique enough to avoid collision.

---

## Troubleshooting

### `doctl: command not found`

```bash
brew install doctl
doctl auth init --context snaprestore
```

### `unable to initialize DigitalOcean API client: access token is required`

No token was found. Set `DOCTL_CONTEXT` in the config block, or export `DIGITALOCEAN_ACCESS_TOKEN`, or set `OP_ITEM` pointing to your 1Password vault entry.

### `op read failed`

1. Confirm `op` is signed in: `op account list`
2. Confirm the vault path is correct: `op read 'op://Private/DigitalOcean API Token/credential'`
3. If 1Password CLI is not installed, remove `OP_ITEM` from the config block — the script falls back to the env var.

### `No compatible droplet sizes found`

The snapshot's `min_disk_size` exceeds every available size in the region. This happens when the original droplet had a large disk. Options:
- Resize the original droplet to a smaller disk before snapshotting (requires migration)
- Future snapshots: start with the smallest adequate disk droplet

### `Reserved IP assignment did not complete`

The script prints a manual fallback command. Run it after checking the console:
```bash
doctl compute reserved-ip-action assign <IP> <droplet-id>
```

### `Script hangs / no output`

With `doctl --wait`, the command polls until the action completes or times out (doctl default: 600 s for actions, longer for droplet create). If it exceeds this, doctl exits non-zero and the cleanup trap prints the interrupted operation and resource ID.

### `fzf not working`

The script falls back to numbered menus automatically. To get arrow-key selection:
```bash
brew install fzf
```

---

## License

MIT — use freely.

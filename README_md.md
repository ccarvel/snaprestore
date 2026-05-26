# DigitalOcean Snapshot Scripts

Two companion scripts for managing DigitalOcean droplet snapshots: one for creating snapshots and one for restoring from them. Designed for cost-effective on-demand server usage—snapshot your droplet, delete it to stop compute charges, then restore later when needed.

## Scripts

| Script | Purpose |
|--------|---------|
| `do-snapshot.sh` | Create a snapshot from an existing droplet |
| `do-restore.sh` | Restore a new droplet from a snapshot |

## Requirements

- `curl` — for API requests
- `jq` — for JSON parsing
- `fzf` (optional) — for arrow-key selection menus; falls back to numbered menus if not installed

### Installing dependencies

```bash
# macOS
brew install jq fzf

# Ubuntu/Debian
sudo apt install jq fzf
```

## API Token Setup

Create a custom-scoped API token at [DigitalOcean API Tokens](https://cloud.digitalocean.com/account/api/tokens).

### Scopes for `do-snapshot.sh`

| Resource | Permissions | Purpose |
|----------|-------------|---------|
| Droplet | read, create, delete | List droplets, create snapshot action, delete droplet (optional) |
| Snapshot | read | Fetch new snapshot details |
| Reserved IP | read | Check if droplet has a reserved IP |

### Scopes for `do-restore.sh`

| Resource | Permissions | Purpose |
|----------|-------------|---------|
| Droplet | read, create | Check status, create new droplet |
| Snapshot | read | List snapshots and get details |
| SSH Key | read | List available SSH keys |
| Reserved IP | read, update | List and assign reserved IPs (optional) |

### Providing the token

```bash
# Option 1: Environment variable
export DO_TOKEN="dop_v1_xxxx"

# Option 2: Edit the script's configuration section
DO_TOKEN="dop_v1_xxxx"

# Option 3: Enter when prompted
./do-snapshot.sh
# DigitalOcean API Token: _
```

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
7. Asks what to do with the droplet: start it, leave it off, or delete it

### Usage

**Interactive mode:**
```bash
./do-snapshot.sh
```

**List droplets only:**
```bash
# Edit script:
DROPLET_ID="list"

# Then run:
./do-snapshot.sh
```

**Pre-configured:**
```bash
# Edit script:
DO_TOKEN="dop_v1_xxxx"
DROPLET_ID="123456789"
SNAPSHOT_NAME="my-backup-2026-01-03"

# Then run:
./do-snapshot.sh
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
  ID: 123456789
  Name: web-server
  Status: active
  Region: nyc1
  Size: s-2vcpu-4gb
  vCPUs: 2
  Memory: 4096MB
  Disk: 80GB
  Public IP: 164.90.xxx.xxx
  Reserved IP: 167.99.xxx.xxx
========================================

Snapshot name [web-server-snapshot-20260103-1430]: 

Proceed with snapshot? (y/n): y

Shutting down droplet for clean snapshot...
Waiting for shutdown to complete...
  Status: in-progress...
Shutdown complete.

Creating snapshot 'web-server-snapshot-20260103-1430'...
Waiting for snapshot to complete (this may take several minutes)...
  Status: in-progress...
  Status: in-progress...
Snapshot complete!

========================================
Snapshot Created Successfully
========================================
  ID: 119876543
  Name: web-server-snapshot-20260103-1430
  Size: 12.34GB
  Min Disk: 80GB
========================================

What would you like to do with the droplet?
> start|Start it back up
  leave|Leave it shut down
  delete|Delete/destroy it

Starting droplet...
Droplet is active!
Connect with: ssh root@167.99.xxx.xxx

Done!
```

---

## do-restore.sh

Restores a new droplet from an existing snapshot. Handles size compatibility, SSH keys, and reserved IP assignment.

### What it does

1. Lists your snapshots for selection
2. Displays snapshot details (size, minimum disk requirement, region)
3. Lists compatible droplet sizes (filters to sizes with sufficient disk space)
4. Optionally configures SSH key
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
# Edit script with any of these:
SNAPSHOT_ID="list"      # List snapshots
SSH_KEY_ID="list"       # List SSH keys
SIZE_SLUG="list"        # List compatible sizes (requires SNAPSHOT_ID set)
RESERVED_IP="list"      # List reserved IPs

# Then run:
./do-restore.sh
```

**Pre-configured:**
```bash
# Edit script:
DO_TOKEN="dop_v1_xxxx"
SNAPSHOT_ID="119876543"
SSH_KEY_ID="12345678"
SIZE_SLUG="s-2vcpu-4gb"
DROPLET_NAME="restored-web-server"
RESERVED_IP="167.99.xxx.xxx"

# Then run:
./do-restore.sh
```

### Example session

```
$ ./do-restore.sh

Fetching snapshots...

Select snapshot:
> 119876543|web-server-snapshot-20260103|12.34GB|min:80GB|nyc1
  118765432|dev-backup-20251215|5.67GB|min:25GB|sfo3

Selected: web-server-snapshot-20260103
Size: 12.34GB (min disk: 80GB)
Region: nyc1

Fetching droplet sizes...

Select droplet size:
> s-2vcpu-4gb|2vCPU|4096MB|80GB|$24/mo
  s-4vcpu-8gb|4vCPU|8192MB|160GB|$48/mo
  s-8vcpu-16gb|8vCPU|16384MB|320GB|$96/mo

Selected size: s-2vcpu-4gb

Fetching SSH keys...

Does this droplet require an SSH key? (y/n): y

Select SSH key:
> 12345678|my-macbook
  87654321|work-laptop

Selected SSH key: 12345678

Assign a reserved IP? (y/n): y

Fetching reserved IPs...

Select reserved IP:
> 167.99.xxx.xxx|unassigned|nyc1

Selected reserved IP: 167.99.xxx.xxx

Droplet name [restored-web-server-snapshot-20260103-20260103]: web-server

========================================
Creating droplet:
  Name: web-server
  Size: s-2vcpu-4gb
  Region: nyc1
  Image: 119876543 (web-server-snapshot-20260103)
  SSH Keys: ["12345678"]
  Reserved IP: 167.99.xxx.xxx
========================================

Proceed? (y/n): y

Created droplet: 456789123
Waiting for droplet to become active...
  Status: new...
  Status: active...

Droplet is active!
  ID: 456789123
  IP: 164.90.xxx.xxx

Assigning reserved IP 167.99.xxx.xxx to droplet...
Reserved IP assigned successfully!

Connect with: ssh root@167.99.xxx.xxx
```

---

## Docker Auto-Start Configuration

For Docker containers to start automatically when restoring from a snapshot, you need two things configured on the original droplet:

### 1. Enable Docker service on boot

The Docker daemon must be set to start automatically when the system boots:

```bash
sudo systemctl enable docker
```

Verify it's enabled:

```bash
sudo systemctl is-enabled docker
# Should output: enabled
```

### 2. Set restart policy on containers

Containers need a restart policy to start when Docker starts.

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
    # ... other config

  database:
    image: postgres:15
    restart: unless-stopped
    # ... other config
```

### Restart policy options

| Policy | Behavior |
|--------|----------|
| `no` | Never restart (default) |
| `always` | Always restart, including on daemon start |
| `unless-stopped` | Restart unless manually stopped |
| `on-failure` | Restart only on non-zero exit code |

`unless-stopped` is generally recommended—it auto-starts on boot but respects manual `docker stop` commands.

### Verify your setup

Before creating a snapshot, confirm containers will auto-start:

```bash
# Check Docker is enabled
sudo systemctl is-enabled docker

# Check container restart policies
docker inspect --format '{{.Name}}: {{.HostConfig.RestartPolicy.Name}}' $(docker ps -aq)
```

### Cloudflare Tunnels

If you're using `cloudflared` for tunnels, the same rules apply. Ensure it has `restart: unless-stopped` in your compose file or was started with `--restart=unless-stopped`. The tunnel will automatically reconnect when the restored droplet boots—no IP address updates needed since traffic routes through Cloudflare.

### If you forgot to set restart policies

If you restored a droplet and your containers didn't start automatically, you have a few options:

**Option 1: Start containers manually**

SSH into the droplet and start your containers:

```bash
# For docker-compose
cd /path/to/your/compose/directory
docker compose up -d

# For standalone containers (if you remember the run command)
docker start container_name
```

**Option 2: Start all stopped containers**

```bash
docker start $(docker ps -aq)
```

**Option 3: Fix it for next time**

Update running containers to have the correct restart policy without recreating them:

```bash
docker update --restart=unless-stopped $(docker ps -aq)
```

Or update your `docker-compose.yml` and recreate:

```bash
# Add restart: unless-stopped to each service, then:
docker compose up -d
```

**Option 4: Find your original run commands**

If you don't remember how containers were started:

```bash
# Show the original command for a container
docker inspect --format '{{.Config.Cmd}}' container_name

# Or use docker-autocompose to regenerate a compose file
pip install docker-autocompose
docker-autocompose container_name
```

After fixing, create a new snapshot so future restores work automatically.

---

## Typical Workflow

### Cost-saving on-demand usage

1. **Create and configure** your droplet with Docker containers, apps, etc.

2. **Snapshot and delete** when not needed:
   ```bash
   ./do-snapshot.sh
   # Select droplet → name snapshot → choose "delete"
   ```
   Now you're only paying ~$0.06/GB/month for snapshot storage.

3. **Restore when needed**:
   ```bash
   ./do-restore.sh
   # Select snapshot → choose size → assign reserved IP
   ```
   Your server is back with the same reserved IP.

4. **Repeat** as needed.

### Tips

- **Reserved IPs** let you maintain the same IP address across snapshot/restore cycles—useful for DNS, firewalls, etc.
- **Docker containers** start automatically if you used `--restart=unless-stopped` or `restart: unless-stopped` in compose files.
- **Snapshot while off** ensures filesystem consistency—both scripts handle this automatically.
- **Min disk size** is locked when you create a snapshot. Use the smallest disk droplet you can for maximum restore flexibility.

---

## Troubleshooting

### "No compatible droplet sizes found"

Your snapshot's minimum disk size exceeds available droplet sizes. This happens when the original droplet had a large disk. Options:
- Look for premium/dedicated droplet types (may not be available)
- Create a new smaller droplet and migrate data manually
- Future snapshots: use smaller disk droplets

### "Cannot create a droplet with a smaller disk than the image"

Same issue as above—the snapshot requires a larger disk than the selected size.

### Script hangs after "Created droplet: null"

The API returned an error. Add error checking or run the curl command manually to see the response. Common causes: invalid IDs, wrong region, insufficient permissions.

### fzf not working

The script falls back to numbered menus automatically. If you want arrow-key selection, install fzf:
```bash
brew install fzf   # macOS
sudo apt install fzf   # Ubuntu/Debian
```

---

## License

MIT — use freely.
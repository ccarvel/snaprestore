# DigitalOcean Snapshot Restore Tools

Two bash scripts for parking and restoring intermittent-use DigitalOcean Droplets:

- `do-snapshot.sh` creates a clean Droplet snapshot and then starts, leaves off, or deletes the original Droplet.
- `do-restore.sh` creates a new Droplet from a snapshot and optionally assigns a reserved IP, tags, VPC, SSH keys, and cloud-init/user-data.

The workflow is designed for Brown University Library digital humanities projects that need stable DNS/Cloudflare configuration through a reserved IP while avoiding compute charges when a Droplet is not in use.

## Install

macOS:

```bash
brew install doctl jq
brew install fzf          # optional, nicer selection menus
brew install --cask 1password-cli  # optional, token loading from 1Password
```

Ubuntu/Debian equivalents:

```bash
sudo apt update
sudo apt install jq fzf
```

Install `doctl` on Ubuntu/Debian using DigitalOcean's current package instructions.

## Security Model

Preferred token loading order:

1. Script variable `DO_TOKEN` if you intentionally set it.
2. Environment variable `DO_API_TOKEN`.
3. Environment variable `DIGITALOCEAN_ACCESS_TOKEN`.
4. 1Password reference in `OP_DO_TOKEN_REF`.
5. Hidden terminal prompt using `read -rs`.

Do not commit real API tokens. If you paste a token into either script for temporary local use, redact it before sharing config, screenshots, logs, or commits.

Recommended 1Password setup:

```bash
export OP_DO_TOKEN_REF='op://Private/DigitalOcean API Token/credential'
./do-snapshot.sh
```

The scripts pass the token directly to `doctl` with `--access-token`; they do not write it to disk.

You can also use a `doctl` context:

```bash
doctl auth init --context brown-dh
```

Then set `DOCTL_CONTEXT="brown-dh"` in the script or your environment. If a token is also provided, the token remains the primary auth path.

## Required DigitalOcean Scopes

For `do-snapshot.sh`:

| Resource | Permissions | Purpose |
| --- | --- | --- |
| Droplet | read, update/action, delete | List Droplets, shut down, power on, snapshot, optional delete |
| Snapshot | read | Fetch created snapshot details |
| Reserved IP | read | Detect assigned reserved IP |

For `do-restore.sh`:

| Resource | Permissions | Purpose |
| --- | --- | --- |
| Droplet | read, create | Create and inspect restored Droplet |
| Snapshot | read | List and inspect snapshots |
| SSH Key | read | Select SSH keys |
| Reserved IP | read, update | Validate and assign reserved IP |
| VPC | read | Select non-default VPC |

## Shared Options

Both scripts support:

```bash
--dry-run        # Show planned mutating actions without running them
--json           # Print final machine-readable JSON summary
--verbose        # Print extra detail
--quiet          # Suppress non-error progress output
--log-file PATH  # Append redacted logs to PATH
--help           # Show usage
```

Example log path:

```bash
./do-restore.sh --log-file "$HOME/.config/do-snap-tool/logs/restore.log"
```

Logs intentionally avoid tokens. They may still contain Droplet names, IDs, IPs, and snapshot names.

## `do-snapshot.sh`

Creates a snapshot from an existing Droplet.

What it does:

1. Lists Droplets for selection unless `DROPLET_ID` is configured.
2. Displays Droplet specs and any assigned reserved IP.
3. Prompts for a snapshot name.
4. Gracefully shuts down the Droplet with `doctl compute droplet-action shutdown --wait`.
5. Falls back to `power-off --wait` only if graceful shutdown fails.
6. Creates the snapshot with `doctl compute droplet-action snapshot --wait`.
7. Lets you start, leave off, or delete the original Droplet.

List Droplets:

```bash
# Edit config:
DROPLET_ID="list"

./do-snapshot.sh
```

Interactive run:

```bash
./do-snapshot.sh
```

Dry run:

```bash
./do-snapshot.sh --dry-run
```

Preconfigured run:

```bash
DO_API_TOKEN="$(op read 'op://Private/DigitalOcean API Token/credential')" \
./do-snapshot.sh --json
```

### Delete Safety

The script preserves the cost-saving delete workflow, but deletion is strongly gated:

1. You must choose or configure `POST_ACTION="delete"`.
2. The script prints the exact Droplet name, ID, and reserved IP warning.
3. You must type the exact Droplet name.
4. Only then does it run `doctl compute droplet delete --force`.

Reserved IPs are unassigned by DigitalOcean when the Droplet is deleted, but the reserved IP itself is not deleted.

## `do-restore.sh`

Creates a new Droplet from an existing snapshot.

What it does:

1. Lists Droplet snapshots for selection unless `SNAPSHOT_ID` is configured.
2. Shows snapshot size, minimum disk size, age, and all available regions.
3. Prompts for region if the snapshot is available in multiple regions.
4. Lists compatible Droplet sizes by minimum disk size.
5. Optionally selects SSH key, reserved IP, VPC, tags, and user-data.
6. Creates the Droplet with `doctl compute droplet create --wait`.
7. Assigns the reserved IP and polls the assignment action to completion.
8. Prints connection details and optional JSON summary.

List snapshots:

```bash
SNAPSHOT_ID="list"
./do-restore.sh
```

List SSH keys:

```bash
SSH_KEY_ID="list"
./do-restore.sh
```

List reserved IPs:

```bash
RESERVED_IP="list"
./do-restore.sh
```

List VPCs:

```bash
VPC_UUID="list"
./do-restore.sh
```

List compatible sizes for a snapshot:

```bash
SNAPSHOT_ID="123456789"
SIZE_SLUG="list"
./do-restore.sh
```

Interactive restore:

```bash
./do-restore.sh
```

Preconfigured restore:

```bash
SNAPSHOT_ID="123456789"
SSH_KEY_ID="11111111,22222222"
SIZE_SLUG="s-2vcpu-4gb"
DROPLET_NAME="dh-project-web"
RESERVED_IP="203.0.113.25"
TAGS="brown-dh,on-demand"
VPC_UUID="00000000-0000-0000-0000-000000000000"
USER_DATA_FILE="./cloud-init.yaml"
./do-restore.sh --json
```

### Reserved IP Safety

Interactive reserved IP selection only shows unassigned IPs in the restore region.

If you preconfigure a reserved IP:

- The script verifies the reserved IP exists.
- The script verifies the reserved IP region matches the selected restore region.
- If the IP is already assigned to another Droplet, the script requires typing `reassign` before moving it.

## Docker Auto-Start Checklist

Before taking a snapshot, configure services on the original Droplet so they start after restore.

Enable Docker on boot:

```bash
sudo systemctl enable docker
sudo systemctl is-enabled docker
```

Use restart policies:

```bash
docker run -d --restart=unless-stopped myapp
```

For Compose:

```yaml
services:
  myapp:
    image: myapp:latest
    restart: unless-stopped
```

Verify policies:

```bash
docker inspect --format '{{.Name}}: {{.HostConfig.RestartPolicy.Name}}' $(docker ps -aq)
```

If you need to reconstruct a Compose file from a running container, prefer `uvx` for one-off Python tools:

```bash
uvx docker-autocompose container_name
```

## Typical Workflow

1. Create and configure the Droplet.
2. Confirm Docker, cloudflared, and project services auto-start.
3. Run `./do-snapshot.sh`.
4. Choose `delete` only after confirming the snapshot completed.
5. Later, run `./do-restore.sh`.
6. Assign the same reserved IP.
7. SSH to the final connection target printed by the script.

## Troubleshooting

### `Required command not found`

Install the missing command with Homebrew on macOS:

```bash
brew install doctl jq fzf
```

For 1Password token loading:

```bash
brew install --cask 1password-cli
```

### `No compatible droplet sizes found`

The snapshot requires a Droplet disk at least as large as `MinDiskSize`. Use a larger Droplet size or rebuild a smaller source Droplet for future snapshots.

### Reserved IP region mismatch

Reserved IPs are regional. Restore the Droplet in the reserved IP's region or choose a different reserved IP.

### Restore completes but app is not reachable

Check the Droplet:

```bash
ssh root@IP_ADDRESS
systemctl status docker
docker ps
```

If using Cloudflare tunnels, confirm the tunnel service/container is configured with `restart: unless-stopped` and has valid credentials inside the snapshot.

### Need more detail

Run with:

```bash
./do-restore.sh --verbose --log-file "$HOME/.config/do-snap-tool/logs/restore.log"
```

## License

MIT

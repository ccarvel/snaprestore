# Snaprestore

Snaprestore is a small operations toolkit for parking and restoring intermittent-use DigitalOcean Droplets.

- `do-snapshot.sh` creates a clean DigitalOcean Droplet snapshot and then starts, leaves off, or deletes the original Droplet.
- `do-restore.sh` creates a new Droplet from a snapshot and can assign a reserved IP, tags, VPC, SSH keys, and cloud-init user data.
- `slack/` contains the optional Slack control plane: Slack slash commands, a Cloudflare Worker, a GitHub Actions dispatch workflow, threaded Slack updates, and a welcome-page health check.

The main workflow is designed for projects that need stable DNS and Cloudflare configuration through a reserved IP while avoiding ongoing Droplet compute charges when the Droplet is not in use.

## Start Here

Use these files in this order:

1. Read this README for the repo map and the short setup path.
2. Follow [docs/setup-codex.md](docs/setup-codex.md) for a full first-time setup and test plan.
3. Follow [slack/README-slack.md](slack/README-slack.md) when configuring or debugging the Slack control plane.
4. Keep [docs/prompt-codex.md](docs/prompt-codex.md) as historical project context for the branch.

## Repository Map

```text
.
├── do-snapshot.sh
├── do-restore.sh
├── .env.example
├── .github/workflows/snaprestore-dispatch.yml
├── docs/
│   ├── setup-codex.md
│   └── prompt-codex.md
└── slack/
    ├── README-slack.md
    ├── app/manifest.yaml
    ├── cloudflare-worker/worker.js
    ├── cloudflare-worker/wrangler.toml
    ├── post-update.sh
    └── welcome-page/cloud-init.yaml
```

## Required Tools

macOS:

```bash
brew install doctl jq
brew install gum
brew install fzf
brew install node
brew install --cask 1password-cli
```

Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install -y jq fzf curl
sudo snap install doctl
```

`gum` and `fzf` are optional for the local terminal UI. The scripts fall back to plain numbered menus when neither is available.

For Cloudflare Worker deployment, use Wrangler from the Worker directory:

```bash
cd slack/cloudflare-worker
npx wrangler --version
```

## Standard Secret Names

Use the same secret names everywhere:

```text
op://Automation/DigitalOcean API Token/credential
op://Automation/Snaprestore Slack Signing Secret/credential
op://Automation/Snaprestore Slack Bot Token/credential
op://Automation/Snaprestore Slack Allowed User IDs/credential
op://Automation/Snaprestore GitHub Token/credential
op://Automation/1Password Service Account Token/credential
```

Never commit real token values. `.env.example` documents variable names and secret references only.

## DigitalOcean Setup

Create or identify:

- A DigitalOcean API token with Droplet, Snapshot, SSH Key, Reserved IP, and VPC access needed by the scripts.
- A Droplet to snapshot.
- A reserved IP in the same region you plan to restore into.
- SSH keys in the DigitalOcean account if restored Droplets need SSH access.
- Optional tags and a VPC for restored Droplets.

Validate local DigitalOcean access:

```bash
export OP_DO_TOKEN_REF='op://Automation/DigitalOcean API Token/credential'
./do-snapshot.sh --no-install --ui plain --dry-run
SNAPSHOT_ID="list" ./do-restore.sh --no-install --ui plain
RESERVED_IP="list" ./do-restore.sh --no-install --ui plain
```

## Local Script Usage

Interactive snapshot:

```bash
export OP_DO_TOKEN_REF='op://Automation/DigitalOcean API Token/credential'
./do-snapshot.sh
```

Non-interactive snapshot that leaves the Droplet off:

```bash
export OP_DO_TOKEN_REF='op://Automation/DigitalOcean API Token/credential'
DROPLET_ID="123456789" \
SNAPSHOT_NAME="dh-web-$(date +%Y%m%d-%H%M)" \
POST_ACTION="leave" \
./do-snapshot.sh --yes --no-install --ui plain --json
```

Interactive restore:

```bash
export OP_DO_TOKEN_REF='op://Automation/DigitalOcean API Token/credential'
./do-restore.sh
```

Non-interactive restore with reserved IP and welcome-page user data:

```bash
export OP_DO_TOKEN_REF='op://Automation/DigitalOcean API Token/credential'
SNAPSHOT_ID="123456789" \
RESTORE_REGION="nyc3" \
SSH_KEY_ID="11111111,22222222" \
SIZE_SLUG="s-2vcpu-4gb" \
DROPLET_NAME="dh-web" \
RESERVED_IP="203.0.113.25" \
TAGS="brown-dh,on-demand" \
USER_DATA_FILE="slack/welcome-page/cloud-init.yaml" \
./do-restore.sh --yes --no-install --ui plain --json
```

## Slack Control Plane

The Slack path is:

```text
Slack slash command
  -> Cloudflare Worker
  -> GitHub Actions workflow_dispatch
  -> do-snapshot.sh or do-restore.sh
  -> Slack thread updates
```

The Cloudflare Worker verifies Slack signatures, checks an allow-list of Slack user IDs, posts the first Slack thread message, dispatches `.github/workflows/snaprestore-dispatch.yml`, and can cancel active runs. GitHub Actions runs the scripts with secrets loaded from 1Password and posts final status with `slack/post-update.sh`.

See [slack/README-slack.md](slack/README-slack.md) for the detailed Slack setup.

## Cloudflare Setup

1. Log in to Cloudflare Wrangler:

   ```bash
   cd slack/cloudflare-worker
   npx wrangler login
   ```

2. Confirm `slack/cloudflare-worker/wrangler.toml` points to the intended GitHub repository, branch, and workflow file.

3. Set Worker secrets from 1Password:

   ```bash
   op read 'op://Automation/Snaprestore Slack Signing Secret/credential' | npx wrangler secret put SLACK_SIGNING_SECRET
   op read 'op://Automation/Snaprestore Slack Bot Token/credential' | npx wrangler secret put SLACK_BOT_TOKEN
   op read 'op://Automation/Snaprestore Slack Allowed User IDs/credential' | npx wrangler secret put SLACK_ALLOWED_USER_IDS
   op read 'op://Automation/Snaprestore GitHub Token/credential' | npx wrangler secret put GITHUB_TOKEN
   ```

4. Deploy the Worker:

   ```bash
   npx wrangler deploy
   ```

5. Copy the deployed Worker URL into each Slack slash command request URL.

## GitHub Actions Setup

The repo includes `.github/workflows/snaprestore-dispatch.yml`. It expects one repository secret:

```text
OP_SERVICE_ACCOUNT_TOKEN
```

Create a 1Password service account that can read these items:

```text
op://Automation/DigitalOcean API Token/credential
op://Automation/Snaprestore Slack Bot Token/credential
```

Add the service account token to the GitHub repository as `OP_SERVICE_ACCOUNT_TOKEN`. The Cloudflare Worker also needs a GitHub token stored as the Worker secret `GITHUB_TOKEN`; that token must be able to create workflow dispatches and cancel workflow runs for this repository.

Validate GitHub Actions before using Slack slash commands, but after Slack bot credentials exist:

1. Open the `Snaprestore Dispatch` workflow in GitHub Actions.
2. Create a scratch Slack message in the channel where the bot is installed.
3. Run the workflow manually with a non-destructive restore or snapshot input, plus the scratch message's `slack_channel_id` and `slack_thread_ts`.
4. Confirm it installs `doctl` and `jq`, loads 1Password secrets, runs the script, and posts to that Slack thread.

## Slack App Setup

1. Create a Slack app from `slack/app/manifest.yaml`.
2. Install the app to the workspace.
3. Store the app signing secret and bot token in 1Password using the standard paths above.
4. Add comma-separated Slack user IDs to `op://Automation/Snaprestore Slack Allowed User IDs/credential`.
5. Set each slash command request URL to the deployed Cloudflare Worker URL.

Supported commands:

```text
/do-snapshot droplet_id=123456789 snapshot_name=dh-web-20260526 post_action=leave
/do-snapshot droplet_id=123456789 snapshot_name=dh-web-20260526 post_action=delete confirm_delete_name=dh-web
/do-restore snapshot_id=123456789 restore_region=nyc3 size_slug=s-2vcpu-4gb droplet_name=dh-web reserved_ip=203.0.113.25 user_data_file=slack/welcome-page/cloud-init.yaml
/do-deploy-cancel <job_id>
```

## Cloudflare And DNS Validation

Snaprestore does not directly edit Cloudflare DNS records. It relies on a stable DigitalOcean reserved IP so Cloudflare DNS can keep pointing at the same address before and after restore.

Before a full test:

1. Confirm the Cloudflare DNS record points to the reserved IP you will assign during restore.
2. If the record is proxied, confirm the restored service can serve the expected HTTP or HTTPS traffic through Cloudflare.
3. If the Droplet uses `cloudflared`, confirm the tunnel credentials and systemd or Docker restart policy are already inside the snapshot.
4. After restore, verify the reserved IP, direct HTTP endpoint, and Cloudflare-hosted hostname.

Useful checks:

```bash
dig +short example.org
curl -I http://203.0.113.25/
curl -I https://example.org/
```

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

## Full Test Path

Use [docs/setup-codex.md](docs/setup-codex.md) for the complete checklist. The minimum full test is:

1. Validate local tools and 1Password access.
2. Validate DigitalOcean list commands.
3. Run `do-snapshot.sh --dry-run`.
4. Run a real snapshot with `POST_ACTION="leave"`.
5. Run `do-restore.sh --dry-run`.
6. Run a real restore with a test Droplet name, reserved IP, and `slack/welcome-page/cloud-init.yaml`.
7. Confirm the welcome page returns HTTP 200.
8. Confirm Cloudflare DNS still points at the reserved IP.
9. Deploy the Cloudflare Worker.
10. Run Slack `/do-snapshot` with `post_action=leave`.
11. Run Slack `/do-restore` with the welcome-page user data.
12. Confirm threaded Slack updates and final readiness.
13. Test `/do-deploy-cancel` with a queued or in-progress test job.

## Troubleshooting

Missing command:

```bash
brew install doctl jq gum fzf node
brew install --cask 1password-cli
```

No compatible Droplet sizes:

Use a size whose disk is at least the snapshot `MinDiskSize`, or rebuild a smaller source Droplet before future snapshots.

Reserved IP region mismatch:

Restore into the reserved IP's region or use a different reserved IP.

Restore completes but the app is not reachable:

```bash
ssh root@IP_ADDRESS
systemctl status docker
docker ps
systemctl status nginx
```

Need more script detail:

```bash
./do-restore.sh --verbose --log-file "$HOME/.config/do-snap-tool/logs/restore.log"
```

## External Setup References

- [DigitalOcean doctl install and configure](https://docs.digitalocean.com/docs/apis-clis/doctl/how-to/install/)
- [Cloudflare Workers secrets](https://developers.cloudflare.com/workers/configuration/secrets/)
- [Cloudflare Wrangler deploy](https://developers.cloudflare.com/workers/wrangler/commands/workers/#deploy)
- [Slack app manifests](https://docs.slack.dev/app-manifests/)
- [Slack slash commands](https://docs.slack.dev/interactivity/implementing-slash-commands/)
- [Slack request verification](https://docs.slack.dev/authentication/verifying-requests-from-slack/)
- [GitHub Actions workflow dispatch API](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)
- [GitHub Actions secrets](https://docs.github.com/actions/how-tos/security-for-github-actions/security-guides/using-secrets-in-github-actions)
- [1Password GitHub Actions secret loading](https://developer.1password.com/docs/ci-cd/github-actions/)

## License

MIT

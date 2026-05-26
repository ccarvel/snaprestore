# Snaprestore Setup And Full Test Guide

This guide is the first-time setup path for testing `do-snapshot.sh`, `do-restore.sh`, and the integrated Slack control plane on the `next-codex` branch.

The full control-plane path is:

```text
Slack slash command
  -> Cloudflare Worker
  -> GitHub Actions workflow_dispatch
  -> do-snapshot.sh or do-restore.sh
  -> Slack thread updates
```

Do not commit real tokens. Store long-lived secrets in 1Password, GitHub repository secrets, or Cloudflare Worker secrets.

## 1. Clone And Select The Branch

```bash
git clone git@github.com:ccarvel/snaprestore.git
cd snaprestore
git switch next-codex
```

Confirm the branch:

```bash
git status --short --branch
```

Expected branch prefix:

```text
## next-codex...origin/next-codex
```

## 2. Install Local Tools

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

Validate the tools:

```bash
doctl version
jq --version
op --version
node --version
npx wrangler --version
```

`gum` and `fzf` are optional for local terminal UI. The scripts fall back to plain numbered menus when neither is available.

## 3. Create The Standard 1Password Items

Create an `Automation` vault or use the existing vault your team uses for automation secrets.

Use these exact item paths for consistency across local scripts, GitHub Actions, and Cloudflare Worker deployment:

```text
op://Automation/DigitalOcean API Token/credential
op://Automation/Snaprestore Slack Signing Secret/credential
op://Automation/Snaprestore Slack Bot Token/credential
op://Automation/Snaprestore Slack Allowed User IDs/credential
op://Automation/Snaprestore GitHub Token/credential
op://Automation/1Password Service Account Token/credential
```

The allowed user IDs value is a comma-separated list:

```text
U0123456789,U9876543210
```

Sign in to 1Password CLI:

```bash
op signin
op whoami
```

Validate each reference without printing secrets to logs:

```bash
op read 'op://Automation/DigitalOcean API Token/credential' >/dev/null
op read 'op://Automation/Snaprestore Slack Signing Secret/credential' >/dev/null
op read 'op://Automation/Snaprestore Slack Bot Token/credential' >/dev/null
op read 'op://Automation/Snaprestore Slack Allowed User IDs/credential' >/dev/null
op read 'op://Automation/Snaprestore GitHub Token/credential' >/dev/null
```

## 4. Configure DigitalOcean

Create or identify:

- A DigitalOcean API token with Droplet, Snapshot, SSH Key, Reserved IP, and VPC access needed by the scripts.
- A source Droplet to snapshot.
- A reserved IP in the same region you plan to restore into.
- SSH keys in the DigitalOcean account if restored Droplets need SSH access.
- Optional tags and a VPC for restored Droplets.

Store the DigitalOcean API token at:

```text
op://Automation/DigitalOcean API Token/credential
```

Validate local DigitalOcean access through the scripts:

```bash
export OP_DO_TOKEN_REF='op://Automation/DigitalOcean API Token/credential'
DROPLET_ID="list" ./do-snapshot.sh --no-install --ui plain
SNAPSHOT_ID="list" ./do-restore.sh --no-install --ui plain
SSH_KEY_ID="list" ./do-restore.sh --no-install --ui plain
RESERVED_IP="list" ./do-restore.sh --no-install --ui plain
VPC_UUID="list" ./do-restore.sh --no-install --ui plain
```

If you prefer `doctl` contexts for manual work:

```bash
doctl auth init --context snaprestore-test
doctl auth switch --context snaprestore-test
doctl account get
```

The scripts still prefer `DO_TOKEN`, `DO_API_TOKEN`, `DIGITALOCEAN_ACCESS_TOKEN`, or `OP_DO_TOKEN_REF` when provided.

## 5. Prepare The Source Droplet

Before snapshot testing, make sure restored services will start without manual intervention.

Enable Docker on boot if the project uses Docker:

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

If the restored site depends on Cloudflare Tunnel, confirm tunnel credentials and the `cloudflared` service or container are already inside the source Droplet before creating the snapshot.

## 6. Configure Cloudflare DNS

Snaprestore does not directly edit Cloudflare DNS records. It relies on a stable DigitalOcean reserved IP so Cloudflare DNS can keep pointing at the same address before and after restore.

Before a full test:

1. Confirm the Cloudflare DNS record points to the reserved IP you will assign during restore.
2. If the record is proxied, confirm the restored service can serve the expected HTTP or HTTPS traffic through Cloudflare.
3. If the Droplet uses `cloudflared`, confirm the tunnel credentials and restart policy are already inside the snapshot.
4. After restore, verify the reserved IP, direct HTTP endpoint, and Cloudflare-hosted hostname.

Useful checks:

```bash
dig +short example.org
curl -I http://203.0.113.25/
curl -I https://example.org/
```

## 7. Configure GitHub Actions

The repo includes:

```text
.github/workflows/snaprestore-dispatch.yml
```

Add this GitHub repository secret:

```text
OP_SERVICE_ACCOUNT_TOKEN
```

Create a 1Password service account that can read:

```text
op://Automation/DigitalOcean API Token/credential
op://Automation/Snaprestore Slack Bot Token/credential
```

Store the service account token in both places if you use the standard paths:

1. 1Password item: `op://Automation/1Password Service Account Token/credential`
2. GitHub repository secret: `OP_SERVICE_ACCOUNT_TOKEN`

The workflow loads runtime secrets with `1password/load-secrets-action@v2`, installs `doctl` and `jq`, runs the selected script, and posts updates through `slack/post-update.sh`.

Validate the workflow before using Slack slash commands, but after Slack bot credentials exist:

1. Open GitHub Actions for this repository.
2. Select `Snaprestore Dispatch`.
3. Create a scratch Slack message in the channel where the bot is installed.
4. Run the workflow manually against `next-codex`.
5. Use a non-destructive `snapshot` run first with `post_action=leave`.
6. Provide the scratch message's `slack_channel_id` and `slack_thread_ts`.
7. Confirm the workflow installs dependencies, loads 1Password secrets, runs the script, and posts to that Slack thread.

## 8. Create The GitHub Token For Cloudflare Worker

The Cloudflare Worker needs a GitHub token stored as the Worker secret `GITHUB_TOKEN`.

The token must be able to:

- Create workflow dispatches for `.github/workflows/snaprestore-dispatch.yml`.
- List workflow runs.
- Cancel queued or in-progress workflow runs.

For a fine-grained personal access token, scope it to this repository only and grant Actions read/write access plus metadata read access. Store it at:

```text
op://Automation/Snaprestore GitHub Token/credential
```

## 9. Configure The Slack App

Create a Slack app from:

```text
slack/app/manifest.yaml
```

The manifest defines:

- Bot display name: `Snaprestore`
- Slash commands: `/do-snapshot`, `/do-restore`, `/do-deploy-cancel`
- Bot scopes: `chat:write`, `commands`, `users:read`

After app creation:

1. Install the app to the workspace.
2. Copy the signing secret into `op://Automation/Snaprestore Slack Signing Secret/credential`.
3. Copy the bot token into `op://Automation/Snaprestore Slack Bot Token/credential`.
4. Add authorized Slack user IDs to `op://Automation/Snaprestore Slack Allowed User IDs/credential`.
5. Leave slash command request URLs blank until the Cloudflare Worker is deployed, or set them to the Worker URL later.

## 10. Configure And Deploy The Cloudflare Worker

The Worker lives in:

```text
slack/cloudflare-worker/
```

Confirm `wrangler.toml` matches the target repository and branch:

```toml
GITHUB_OWNER = "ccarvel"
GITHUB_REPO = "snaprestore"
GITHUB_REF = "next-codex"
GITHUB_WORKFLOW_FILE = "snaprestore-dispatch.yml"
```

Log in to Cloudflare:

```bash
cd slack/cloudflare-worker
npx wrangler login
```

Set Worker secrets from 1Password:

```bash
op read 'op://Automation/Snaprestore Slack Signing Secret/credential' | npx wrangler secret put SLACK_SIGNING_SECRET
op read 'op://Automation/Snaprestore Slack Bot Token/credential' | npx wrangler secret put SLACK_BOT_TOKEN
op read 'op://Automation/Snaprestore Slack Allowed User IDs/credential' | npx wrangler secret put SLACK_ALLOWED_USER_IDS
op read 'op://Automation/Snaprestore GitHub Token/credential' | npx wrangler secret put GITHUB_TOKEN
```

Deploy:

```bash
npx wrangler deploy
```

Copy the deployed Worker URL into each Slack slash command request URL:

```text
/do-snapshot
/do-restore
/do-deploy-cancel
```

## 11. Run Local Script Tests

Set shared local auth:

```bash
export OP_DO_TOKEN_REF='op://Automation/DigitalOcean API Token/credential'
```

List available resources:

```bash
DROPLET_ID="list" ./do-snapshot.sh --no-install --ui plain
SNAPSHOT_ID="list" ./do-restore.sh --no-install --ui plain
SSH_KEY_ID="list" ./do-restore.sh --no-install --ui plain
RESERVED_IP="list" ./do-restore.sh --no-install --ui plain
VPC_UUID="list" ./do-restore.sh --no-install --ui plain
```

Dry-run snapshot:

```bash
DROPLET_ID="123456789" \
SNAPSHOT_NAME="snaprestore-test-$(date +%Y%m%d-%H%M)" \
POST_ACTION="leave" \
./do-snapshot.sh --dry-run --yes --no-install --ui plain --json
```

Real snapshot that does not delete the source Droplet:

```bash
DROPLET_ID="123456789" \
SNAPSHOT_NAME="snaprestore-test-$(date +%Y%m%d-%H%M)" \
POST_ACTION="leave" \
./do-snapshot.sh --yes --no-install --ui plain --json
```

List compatible sizes for the new snapshot:

```bash
SNAPSHOT_ID="123456789" SIZE_SLUG="list" ./do-restore.sh --no-install --ui plain
```

Dry-run restore:

```bash
SNAPSHOT_ID="123456789" \
RESTORE_REGION="nyc3" \
SSH_KEY_ID="11111111" \
SIZE_SLUG="s-2vcpu-4gb" \
DROPLET_NAME="snaprestore-test" \
RESERVED_IP="203.0.113.25" \
TAGS="snaprestore,test" \
USER_DATA_FILE="slack/welcome-page/cloud-init.yaml" \
./do-restore.sh --dry-run --yes --no-install --ui plain --json
```

Real restore:

```bash
SNAPSHOT_ID="123456789" \
RESTORE_REGION="nyc3" \
SSH_KEY_ID="11111111" \
SIZE_SLUG="s-2vcpu-4gb" \
DROPLET_NAME="snaprestore-test" \
RESERVED_IP="203.0.113.25" \
TAGS="snaprestore,test" \
USER_DATA_FILE="slack/welcome-page/cloud-init.yaml" \
./do-restore.sh --yes --no-install --ui plain --json
```

Validate the welcome page:

```bash
curl -fsS http://203.0.113.25/ | head
```

## 12. Run GitHub Actions Tests

Run `Snaprestore Dispatch` manually from GitHub Actions.

Snapshot test inputs:

```text
operation: snapshot
droplet_id: 123456789
snapshot_name: snaprestore-gha-test
post_action: leave
```

Restore test inputs:

```text
operation: restore
snapshot_id: 123456789
restore_region: nyc3
ssh_key_id: 11111111
size_slug: s-2vcpu-4gb
droplet_name: snaprestore-gha-test
reserved_ip: 203.0.113.25
tags: snaprestore,test
user_data_file: slack/welcome-page/cloud-init.yaml
```

The workflow is Slack-integrated. Manual workflow tests must include a real Slack channel ID and thread timestamp because `slack/post-update.sh` requires `INPUT_SLACK_CHANNEL_ID` and `INPUT_SLACK_THREAD_TS`.

## 13. Run Slack End-To-End Tests

Snapshot without deletion:

```text
/do-snapshot droplet_id=123456789 snapshot_name=snaprestore-slack-test post_action=leave
```

Restore with welcome page:

```text
/do-restore snapshot_id=123456789 restore_region=nyc3 ssh_key_id=11111111 size_slug=s-2vcpu-4gb droplet_name=snaprestore-slack-test reserved_ip=203.0.113.25 tags=snaprestore,test user_data_file=slack/welcome-page/cloud-init.yaml
```

Expected Slack behavior:

1. The slash command returns an ephemeral queued response.
2. The Worker posts a threaded public message: `on it, <user>.`
3. GitHub Actions posts a running update.
4. A successful restore posts either `ready: <droplet> at http://<ip>/` or a message that the Droplet is active but HTTP readiness did not pass.
5. The final Slack message includes the `job_id`.

Cancel test:

```text
/do-deploy-cancel <job_id>
```

Use a queued or in-progress test job. The Worker searches recent workflow runs on `next-codex` and requests cancellation for the run whose name includes the job ID.

## 14. Verify Cloudflare After Restore

After the restore succeeds:

```bash
dig +short example.org
curl -I http://203.0.113.25/
curl -I https://example.org/
```

Expected results:

- DNS returns the reserved IP or the expected Cloudflare proxy address depending on proxy mode.
- Direct reserved-IP HTTP returns `200` when using `slack/welcome-page/cloud-init.yaml`.
- The Cloudflare hostname returns the expected project response when the application or tunnel is running.

## 15. Cleanup After Tests

Use DigitalOcean intentionally after tests:

1. Keep the restored Droplet if it is now the active project Droplet.
2. Delete only disposable test Droplets.
3. Keep the reserved IP if DNS points to it.
4. Remove disposable test snapshots if they are no longer needed.

The scripts gate Droplet deletion strongly. Snapshot deletion is not automated by this repo.

## Troubleshooting

Missing command:

```bash
brew install doctl jq gum fzf node
brew install --cask 1password-cli
```

1Password item not found:

1. Confirm `op signin` succeeded.
2. Confirm the vault is named `Automation`.
3. Confirm the item and field names match the standard references.

Worker returns `invalid_signature`:

1. Confirm the Slack slash command request URL points to the deployed Worker URL.
2. Confirm `SLACK_SIGNING_SECRET` was set with `npx wrangler secret put`.
3. Reinstall the Slack app if the signing secret changed.

Worker returns `Not authorized`:

1. Confirm your Slack user ID is in `SLACK_ALLOWED_USER_IDS`.
2. Store IDs as comma-separated values with no display names.
3. Re-run `npx wrangler secret put SLACK_ALLOWED_USER_IDS`.

GitHub dispatch fails:

1. Confirm `GITHUB_OWNER`, `GITHUB_REPO`, `GITHUB_REF`, and `GITHUB_WORKFLOW_FILE` in `wrangler.toml`.
2. Confirm the GitHub token can dispatch and cancel Actions runs.
3. Confirm `.github/workflows/snaprestore-dispatch.yml` exists on `next-codex`.

Restore completes but app is not reachable:

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

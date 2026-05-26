# Snaprestore Slack Control Plane

This directory contains the optional Slack integration for running Snaprestore from slash commands.

The control-plane path is:

```text
Slack slash command
  -> Cloudflare Worker
  -> GitHub Actions workflow_dispatch
  -> do-snapshot.sh or do-restore.sh
  -> Slack thread updates
```

The Worker exists to verify Slack requests, enforce a Slack user allow-list, acknowledge the slash command quickly, post the first thread message, dispatch GitHub Actions, and cancel active jobs. GitHub Actions runs the scripts and posts threaded updates through `slack/post-update.sh`.

## Directory Map

```text
slack/
├── README-slack.md
├── app/
│   └── manifest.yaml
├── cloudflare-worker/
│   ├── worker.js
│   └── wrangler.toml
├── post-update.sh
└── welcome-page/
    └── cloud-init.yaml
```

## Files

`app/manifest.yaml`

Defines the Slack app, bot user, slash commands, and bot scopes.

`cloudflare-worker/worker.js`

Handles Slack slash commands. It verifies `X-Slack-Signature`, rejects stale timestamps, checks `SLACK_ALLOWED_USER_IDS`, posts the initial Slack thread message, dispatches `.github/workflows/snaprestore-dispatch.yml`, and cancels active workflow runs.

`cloudflare-worker/wrangler.toml`

Configures the Worker name, entrypoint, compatibility date, and non-secret GitHub variables:

```toml
GITHUB_OWNER = "ccarvel"
GITHUB_REPO = "snaprestore"
GITHUB_REF = "next-codex"
GITHUB_WORKFLOW_FILE = "snaprestore-dispatch.yml"
```

`post-update.sh`

Posts a message to an existing Slack thread. GitHub Actions calls this script with `SLACK_BOT_TOKEN`, `INPUT_SLACK_CHANNEL_ID`, and `INPUT_SLACK_THREAD_TS`.

`welcome-page/cloud-init.yaml`

Installs nginx on a restored Droplet and writes a simple readiness page. The GitHub workflow polls this page after restore and posts `ready` only after HTTP 200.

## Required Secrets

Use the same secret names everywhere:

```text
op://Automation/DigitalOcean API Token/credential
op://Automation/Snaprestore Slack Signing Secret/credential
op://Automation/Snaprestore Slack Bot Token/credential
op://Automation/Snaprestore Slack Allowed User IDs/credential
op://Automation/Snaprestore GitHub Token/credential
op://Automation/1Password Service Account Token/credential
```

Cloudflare Worker secrets:

```text
SLACK_SIGNING_SECRET
SLACK_BOT_TOKEN
SLACK_ALLOWED_USER_IDS
GITHUB_TOKEN
```

GitHub repository secret:

```text
OP_SERVICE_ACCOUNT_TOKEN
```

GitHub Actions runtime secrets loaded from 1Password:

```text
DO_API_TOKEN = op://Automation/DigitalOcean API Token/credential
SLACK_BOT_TOKEN = op://Automation/Snaprestore Slack Bot Token/credential
```

Never commit real token values. `wrangler.toml` should contain only non-secret variables.

## Slack App Setup

1. Create a Slack app from `slack/app/manifest.yaml`.
2. Install the app to the workspace.
3. Copy the app signing secret into `op://Automation/Snaprestore Slack Signing Secret/credential`.
4. Copy the bot token into `op://Automation/Snaprestore Slack Bot Token/credential`.
5. Add comma-separated Slack user IDs to `op://Automation/Snaprestore Slack Allowed User IDs/credential`.
6. Set each slash command request URL to the deployed Cloudflare Worker URL after deployment.

The manifest includes these bot scopes:

```text
chat:write
commands
users:read
```

The manifest includes these slash commands:

```text
/do-snapshot
/do-restore
/do-deploy-cancel
```

## GitHub Setup

The Worker dispatches:

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

Create a GitHub token for the Cloudflare Worker. The token must be able to:

- Create workflow dispatches for `.github/workflows/snaprestore-dispatch.yml`.
- List workflow runs.
- Cancel queued or in-progress workflow runs.

For a fine-grained personal access token, scope it to this repository only and grant Actions read/write access plus metadata read access. Store it at:

```text
op://Automation/Snaprestore GitHub Token/credential
```

## Cloudflare Worker Setup

Install local tools on macOS:

```bash
brew install node
brew install --cask 1password-cli
```

Log in to Cloudflare:

```bash
cd slack/cloudflare-worker
npx wrangler login
```

Confirm `wrangler.toml` points to the intended repository and branch:

```bash
cat wrangler.toml
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

Copy the deployed Worker URL into each slash command request URL in the Slack app settings.

## Command Usage

Snapshot without deleting the source Droplet:

```text
/do-snapshot droplet_id=123456789 snapshot_name=dh-web-20260526 post_action=leave
```

Snapshot and delete the source Droplet:

```text
/do-snapshot droplet_id=123456789 snapshot_name=dh-web-20260526 post_action=delete confirm_delete_name=dh-web
```

Restore:

```text
/do-restore snapshot_id=123456789 restore_region=nyc3 ssh_key_id=11111111 size_slug=s-2vcpu-4gb droplet_name=dh-web reserved_ip=203.0.113.25 tags=brown-dh,on-demand
```

Restore with the included welcome page:

```text
/do-restore snapshot_id=123456789 restore_region=nyc3 ssh_key_id=11111111 size_slug=s-2vcpu-4gb droplet_name=dh-web reserved_ip=203.0.113.25 tags=brown-dh,on-demand user_data_file=slack/welcome-page/cloud-init.yaml
```

Cancel:

```text
/do-deploy-cancel <job_id>
```

## Argument Names

Use `key=value` pairs. The Worker normalizes dashes to underscores.

Snapshot arguments:

```text
droplet_id
snapshot_name
post_action
confirm_delete_name
```

Restore arguments:

```text
snapshot_id
restore_region
ssh_key_id
size_slug
droplet_name
reserved_ip
tags
vpc_uuid
user_data_file
reassign_reserved_ip
```

Use `reassign_reserved_ip=true` only when you intentionally want the restore workflow to move an already assigned reserved IP.

## Expected Slack Behavior

1. The slash command returns an ephemeral queued response.
2. The Worker posts a threaded public message: `on it, <user>.`
3. GitHub Actions posts a running update.
4. A successful restore posts either `ready: <droplet> at http://<ip>/` or a message that the Droplet is active but HTTP readiness did not pass.
5. The final Slack message includes the `job_id`.

## Welcome Page Health Check

Use the included cloud-init file during restore:

```text
user_data_file=slack/welcome-page/cloud-init.yaml
```

The restored Droplet installs nginx and serves a page at:

```text
http://<reserved-ip>/
```

The GitHub workflow checks that URL for up to five minutes. It posts `ready` only after HTTP 200.

Manual check:

```bash
curl -fsS http://203.0.113.25/ | head
```

## Test Plan

Run these tests in order:

1. Validate the local scripts outside Slack:

   ```bash
   export OP_DO_TOKEN_REF='op://Automation/DigitalOcean API Token/credential'
   DROPLET_ID="list" ./do-snapshot.sh --no-install --ui plain
   SNAPSHOT_ID="list" ./do-restore.sh --no-install --ui plain
   ```

2. Validate the GitHub workflow manually from the GitHub Actions UI with a real Slack channel ID and thread timestamp.

3. Deploy the Worker:

   ```bash
   cd slack/cloudflare-worker
   npx wrangler deploy
   ```

4. Run a Slack snapshot with `post_action=leave`.

5. Run a Slack restore with `user_data_file=slack/welcome-page/cloud-init.yaml`.

6. Confirm the Slack thread reaches a final success or clear failure message.

7. Test cancellation with a queued or in-progress job:

   ```text
   /do-deploy-cancel <job_id>
   ```

## Troubleshooting

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

GitHub workflow fails while posting Slack updates:

1. Confirm `OP_SERVICE_ACCOUNT_TOKEN` exists as a GitHub repository secret.
2. Confirm the 1Password service account can read `op://Automation/Snaprestore Slack Bot Token/credential`.
3. Confirm the workflow received a real `slack_channel_id` and `slack_thread_ts`.

Restore succeeds but Slack never posts `ready`:

1. Confirm `user_data_file=slack/welcome-page/cloud-init.yaml` was passed.
2. Confirm the reserved IP is assigned to the restored Droplet.
3. Confirm port 80 is reachable from GitHub Actions.
4. Check the Droplet:

   ```bash
   ssh root@IP_ADDRESS
   systemctl status nginx
   cat /var/www/html/index.html
   ```

## External Setup References

- [Cloudflare Workers secrets](https://developers.cloudflare.com/workers/configuration/secrets/)
- [Cloudflare Wrangler deploy](https://developers.cloudflare.com/workers/wrangler/commands/workers/#deploy)
- [Slack app manifests](https://docs.slack.dev/app-manifests/)
- [Slack slash commands](https://docs.slack.dev/interactivity/implementing-slash-commands/)
- [Slack request verification](https://docs.slack.dev/authentication/verifying-requests-from-slack/)
- [GitHub Actions workflow dispatch API](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)
- [GitHub Actions secrets](https://docs.github.com/actions/how-tos/security-for-github-actions/security-guides/using-secrets-in-github-actions)
- [1Password GitHub Actions secret loading](https://developer.1password.com/docs/ci-cd/github-actions/)

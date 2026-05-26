# Slack Integration Architecture Setup Guide

This guide walks you through setting up a serverless, highly secure Slack slash command integration for the DigitalOcean snapshot/restore scripts using AWS Lambda, API Gateway, and Systems Manager (SSM).

## Overview
1. **Slack** sends a slash command (`/do-snap web-server-prod`) to AWS API Gateway.
2. **API Gateway** triggers an **AWS Lambda** (Python).
3. **Lambda** validates the signature using your Slack secret, preventing unauthorized access.
4. **Lambda** immediately returns a 200 OK ("Job Queued") to satisfy Slack's 3-second timeout.
5. **Lambda** async-triggers an **AWS SSM Run Command** to your backend runner (bastion).
6. **Runner** executes the bash script with `--force` non-interactive mode.
7. **Runner** posts the script's stdout/stderr back to Slack using the temporary `response_url`.

---

## Secrets & Credentials Reference

The following secrets are created during this setup. Store all of them in 1Password before or immediately after creation.

| Secret | Where it comes from | 1Password Path | `op read` command |
|--------|--------------------|-----------------|--------------------|
| `SLACK_SIGNING_SECRET` | Slack App → Basic Information → App Credentials | `op://Private/SnapRestore Slack App/signing_secret` | `op read "op://Private/SnapRestore Slack App/signing_secret"` |
| `DO_API_TOKEN` | DigitalOcean → API → Personal Access Tokens | `op://Private/DigitalOcean PAT/credential` | `op read "op://Private/DigitalOcean PAT/credential"` |
| `SSM_INSTANCE_ID` | AWS Systems Manager → Fleet Manager (your runner's ID) | `op://Private/SnapRestore Runner/instance_id` | `op read "op://Private/SnapRestore Runner/instance_id"` |

### Store secrets in 1Password (run once)

```bash
# 1. DigitalOcean Personal Access Token
op item create \
  --category login \
  --title "DigitalOcean PAT" \
  --vault Private \
  username="snaprestore" \
  credential="dop_v1_YOUR_TOKEN_HERE"

# 2. Slack App Signing Secret (retrieve from Slack FIRST, then store)
op item create \
  --category login \
  --title "SnapRestore Slack App" \
  --vault Private \
  username="snaprestore-slack" \
  signing_secret="YOUR_SLACK_SIGNING_SECRET_HERE"

# 3. SSM Runner Instance ID (retrieve from AWS FIRST, then store)
op item create \
  --category login \
  --title "SnapRestore Runner" \
  --vault Private \
  username="snaprestore-runner" \
  instance_id="i-0abcdef1234567890"
```

### Update an existing 1Password item

```bash
# Update the Slack signing secret after rotating it
op item edit "SnapRestore Slack App" --vault Private signing_secret="NEW_SIGNING_SECRET"

# Update the runner instance ID if the runner changes
op item edit "SnapRestore Runner" --vault Private instance_id="i-NEW_INSTANCE_ID"
```

---

## Step 1: Prepare the Runner Machine

You need a machine (EC2, Droplet, or on-prem) with the bash scripts and dependencies (`doctl`, `jq`, `1Password CLI`).

1. Install the **AWS Systems Manager (SSM) Agent** on the runner.
   - If using AWS EC2, the agent is pre-installed on Amazon Linux and Ubuntu AMIs. Just attach an IAM role with the `AmazonSSMManagedInstanceCore` policy.
   - If using a DigitalOcean Droplet, use [SSM Hybrid Activations](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-managedinstances.html) to register the droplet into AWS SSM.
2. Ensure the scripts are located at `/opt/snaprestore` (or update `app.py` to match your directory).
3. **Install 1Password CLI on the runner** so the `ssm-user` can securely fetch the DO token at runtime:
   ```bash
   # Ubuntu/Debian runner
   curl -sS https://downloads.1password.com/linux/keys/1password.asc | sudo gpg --dearmor -o /usr/share/keyrings/1password-archive-keyring.gpg
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | sudo tee /etc/apt/sources.list.d/1password.list
   sudo apt update && sudo apt install -y 1password-cli
   ```
4. **Configure the DigitalOcean token on the runner** using one of these approaches:

   **Option A — 1Password Service Account (Recommended for servers/CI):**
   Create a Service Account at [1password.com](https://1password.com) → Settings → Developer → Service Accounts with read-only access to your vault, then:
   ```bash
   # Set the service account token on the runner (only this token is stored — no real secrets)
   echo 'export OP_SERVICE_ACCOUNT_TOKEN="ops_YOUR_SERVICE_ACCOUNT_TOKEN"' | sudo tee /etc/profile.d/op_service.sh
   sudo chmod 600 /etc/profile.d/op_service.sh

   # Verify: the runner can now resolve DO token on demand
   source /etc/profile.d/op_service.sh
   op read "op://Private/DigitalOcean PAT/credential"
   ```

   **Option B — Pre-resolved environment variable (simpler for testing):**
   ```bash
   # Resolve the token locally, then write it to the runner's profile
   DO_API_TOKEN=$(op read "op://Private/DigitalOcean PAT/credential")
   echo "export DO_API_TOKEN=\"${DO_API_TOKEN}\"" | sudo tee /etc/profile.d/do_api.sh
   sudo chmod 600 /etc/profile.d/do_api.sh
   ```

5. Note the **Instance ID** of the runner (visible in AWS Systems Manager → Fleet Manager, or shown during SSM Hybrid Activation registration, e.g., `i-0abcdef1234567890` or `mi-0123456789abcdef0`). Store it immediately:
   ```bash
   op item edit "SnapRestore Runner" --vault Private instance_id="i-0abcdef1234567890"
   ```

---

## Step 2: Create the AWS Lambda

1. Go to AWS Lambda → **Create function**.
2. Name it `SlackSnapRestore`, runtime **Python 3.12**.
3. Under Execution role, let it create a new basic IAM role.
4. Copy the contents of `slack-integration/app.py` into the inline code editor and Deploy.

---

## Step 3: Configure Lambda IAM Permissions

Your Lambda needs permission to trigger SSM commands.
1. Go to Configuration → Permissions → Click the Role name to open IAM.
2. Add an inline policy:
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "ssm:SendCommand",
            "Resource": [
                "arn:aws:ec2:*:*:instance/*",
                "arn:aws:ssm:*:*:managed-instance/*",
                "arn:aws:ssm:*:*:document/AWS-RunShellScript"
            ]
        }
    ]
}
```
3. Name it `SSMInvokePolicy` and save.

---

## Step 4: Configure API Gateway

1. Go to API Gateway → **Create API** → HTTP API.
2. Add Integration → Lambda → select `SlackSnapRestore`.
3. Give it an API name (e.g., `SlackWebhookAPI`) and create it.
4. Go to **Routes**, ensure there is a `POST` route mapped to your Lambda.
5. Note the **Invoke URL** (e.g., `https://abcdefg.execute-api.us-east-1.amazonaws.com/`).

---

## Step 5: Configure the Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and **Create New App**.
2. Go to **Slash Commands** → Create New Command.
   - Command: `/do-snap`
   - Request URL: *Your API Gateway Invoke URL*
   - Description: Take a snapshot of a Droplet
3. Repeat for `/do-restore`.
4. Go to **Basic Information** → App Credentials.
   - Copy the **Signing Secret**, then immediately store it in 1Password:
     ```bash
     op item edit "SnapRestore Slack App" --vault Private signing_secret="YOUR_SIGNING_SECRET"
     # Verify:
     op read "op://Private/SnapRestore Slack App/signing_secret"
     ```
5. Go to **Install App** → **Install to Workspace** and authorize.

---

## Step 6: Set Lambda Environment Variables

Go to AWS Lambda → Configuration → Environment variables → Edit. Add:
- `SLACK_SIGNING_SECRET` — retrieve from 1Password, do not paste from memory:
  ```bash
  op read "op://Private/SnapRestore Slack App/signing_secret"
  ```
- `SSM_INSTANCE_ID` — retrieve from 1Password:
  ```bash
  op read "op://Private/SnapRestore Runner/instance_id"
  ```

Or set both via AWS CLI with secrets resolved by `op` (nothing sensitive in shell history):
```bash
SLACK_SIGNING_SECRET=$(op read "op://Private/SnapRestore Slack App/signing_secret")
SSM_INSTANCE_ID=$(op read "op://Private/SnapRestore Runner/instance_id")

aws lambda update-function-configuration \
  --function-name SlackSnapRestore \
  --environment "Variables={SLACK_SIGNING_SECRET=${SLACK_SIGNING_SECRET},SSM_INSTANCE_ID=${SSM_INSTANCE_ID}}"
```

---

## Step 7: Test

Go into your Slack workspace and type:
`/do-snap my-droplet-id`

The Lambda will queue the job, SSM will execute the bash script in non-interactive mode on your secure runner, and within a few minutes, the final output log will be delivered right back into your Slack channel.

### Troubleshooting

- **Unauthorized error**: Verify `SLACK_SIGNING_SECRET` in Lambda matches Slack exactly:
  `op read "op://Private/SnapRestore Slack App/signing_secret"`
- **DO token missing on runner**: Check `/etc/profile.d/do_api.sh` or verify the 1Password Service Account token is set and `op read` resolves on the runner.
- **SSM command fails**: Check AWS Systems Manager → Run Command → Command history for stdout/stderr.
- **`op` not found on runner**: Install 1Password CLI — see Step 1 above.

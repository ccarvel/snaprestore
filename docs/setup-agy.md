# Setup Guide for Testing SnapRestore with Slack Integration

Welcome to the **SnapRestore** repository! This guide will help you get fully set up to test the `do-snapshot` and `do-restore` scripts, and importantly, ensure that the Slack integration is properly configured and ready to be used during your testing.

## Prerequisites

Before you begin, ensure you have access to the following:
1. **DigitalOcean Account**: You need an active DO account and a Personal Access Token with read/write permissions.
2. **Slack Workspace**: Permission to create and install Slack Apps in your workspace.
3. **AWS Account**: The Slack integration relies on AWS Lambda, API Gateway, and Systems Manager (SSM) to securely trigger the scripts.
4. **A Runner Server**: An AWS EC2 instance or a DigitalOcean Droplet registered with AWS SSM Hybrid Activations. This machine will execute the bash scripts.
5. **1Password CLI** (`op`): Strongly recommended for secure secret management. Install with `brew install 1password-cli`. Sign in with `op signin`.

---

## Secret Management with 1Password

All credentials for this project should be stored in 1Password and retrieved via the `op` CLI. This avoids hardcoding secrets in scripts, environment files, or shell profiles.

### Recommended 1Password Vault Structure

Store all SnapRestore secrets under a single vault (e.g., `Private` or a dedicated `SnapRestore` vault) using the following item names and field paths:

| Secret | 1Password Path | `op read` Command |
|--------|---------------|-------------------|
| DigitalOcean API Token | `op://Private/DigitalOcean PAT/credential` | `op read "op://Private/DigitalOcean PAT/credential"` |
| Slack Signing Secret | `op://Private/SnapRestore Slack App/signing_secret` | `op read "op://Private/SnapRestore Slack App/signing_secret"` |
| AWS SSM Instance ID | `op://Private/SnapRestore Runner/instance_id` | `op read "op://Private/SnapRestore Runner/instance_id"` |

> **Tip**: You can use any vault and item names you prefer — just update the paths consistently across all the commands below.

### Storing Secrets in 1Password

Run these `op` commands once to create the items. You will be prompted to paste the actual secret values.

```bash
# 1. Store the DigitalOcean Personal Access Token
op item create \
  --category login \
  --title "DigitalOcean PAT" \
  --vault Private \
  username="snaprestore" \
  credential="dop_v1_YOUR_TOKEN_HERE"

# 2. Store the Slack App Signing Secret
op item create \
  --category login \
  --title "SnapRestore Slack App" \
  --vault Private \
  username="snaprestore-slack" \
  signing_secret="YOUR_SLACK_SIGNING_SECRET_HERE"

# 3. Store the AWS SSM Runner Instance ID
op item create \
  --category login \
  --title "SnapRestore Runner" \
  --vault Private \
  username="snaprestore-runner" \
  instance_id="i-0abcdef1234567890"
```

### Reading Secrets with `op read`

```bash
# Read the DO token into a variable (never printed to terminal)
DO_API_TOKEN=$(op read "op://Private/DigitalOcean PAT/credential")

# Read the Slack signing secret
SLACK_SIGNING_SECRET=$(op read "op://Private/SnapRestore Slack App/signing_secret")

# Read the SSM instance ID
SSM_INSTANCE_ID=$(op read "op://Private/SnapRestore Runner/instance_id")
```

### Injecting Secrets into a Shell Session

Use `op run` to inject secrets from a `.env`-style file without ever touching the filesystem in plaintext:

```bash
# Run a script with secrets auto-injected from 1Password
op run --env-file=".env.op" -- ./do-snapshot.sh
```

Where `.env.op` (gitignored) contains `op://` references instead of real values:

```bash
DO_API_TOKEN=op://Private/DigitalOcean PAT/credential
SLACK_SIGNING_SECRET=op://Private/SnapRestore Slack App/signing_secret
SSM_INSTANCE_ID=op://Private/SnapRestore Runner/instance_id
```

---

## Part 1: Setting up the Runner Machine

The runner is the machine where the snapshot and restore bash scripts will actually execute.

1. **Provision a Test Runner**: Spin up a small EC2 instance (Amazon Linux 2023 or Ubuntu) or a DO Droplet.
2. **Install SSM Agent**:
   - *EC2*: Generally pre-installed. Ensure you attach an IAM Role to the instance containing the `AmazonSSMManagedInstanceCore` policy.
   - *Droplet*: Follow [AWS SSM Hybrid Activations](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-managedinstances.html) to register your Droplet with SSM.
3. **Install Dependencies** on the runner:
   ```bash
   sudo apt-get update
   sudo apt-get install -y jq curl

   # Install doctl (DigitalOcean CLI)
   wget https://github.com/digitalocean/doctl/releases/download/v1.101.0/doctl-1.101.0-linux-amd64.tar.gz
   tar xf doctl-1.101.0-linux-amd64.tar.gz
   sudo mv doctl /usr/local/bin

   # Install 1Password CLI on the runner (recommended)
   curl -sS https://downloads.1password.com/linux/keys/1password.asc | sudo gpg --dearmor -o /usr/share/keyrings/1password-archive-keyring.gpg
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | sudo tee /etc/apt/sources.list.d/1password.list
   sudo apt update && sudo apt install -y 1password-cli
   ```
4. **Deploy the Scripts**:
   The Slack integration expects the scripts to reside in `/opt/snaprestore`.
   ```bash
   sudo mkdir -p /opt/snaprestore
   sudo chown -R $USER:$USER /opt/snaprestore
   git clone <your-repo-url> /opt/snaprestore
   cd /opt/snaprestore
   git checkout next-agy
   chmod +x do-snapshot.sh do-restore.sh
   ```
5. **Configure Credentials on the Runner**:

   The SSM agent (which runs as `ssm-user` or `root`) needs access to the DigitalOcean token. Choose one of these approaches:

   **Option A — 1Password Service Account (Most Secure, Recommended for CI/servers):**
   Create a 1Password Service Account with read access to the `Private` vault, then set the token on the runner:
   ```bash
   # On the runner machine — store the service account token securely
   echo 'OP_SERVICE_ACCOUNT_TOKEN="ops_your_service_account_token_here"' | sudo tee /etc/profile.d/op_service.sh
   sudo chmod 600 /etc/profile.d/op_service.sh

   # The scripts will then resolve the DO token at runtime via:
   # DO_API_TOKEN=$(op read "op://Private/DigitalOcean PAT/credential")
   ```
   To create a Service Account: go to [1password.com](https://1password.com) → Settings → Developer → Service Accounts → New Service Account. Grant it read access to the relevant vault.

   **Option B — Environment variable (simpler for local testing):**
   ```bash
   DO_API_TOKEN=$(op read "op://Private/DigitalOcean PAT/credential")
   echo "export DO_API_TOKEN=\"${DO_API_TOKEN}\"" | sudo tee /etc/profile.d/do_api.sh
   sudo chmod 600 /etc/profile.d/do_api.sh
   ```

   **Option C — Directly in the SSM command (via `app.py`):**
   The Lambda function (`slack-integration/app.py`) can inject the token into the SSM shell command at dispatch time if it is available as a Lambda environment variable. See Part 3.

*Make note of your Runner's Instance ID (e.g., `i-0abcdef1234567890` or `mi-0123456789abcdef0`) — you will store this in 1Password in the step below.*

```bash
# Store the runner instance ID in 1Password
op item edit "SnapRestore Runner" --vault Private instance_id="i-0abcdef1234567890"
```

---

## Part 2: Setting up the Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App** (From scratch).
2. Name it `SnapRestore Test` and pick your workspace.
3. Under **Basic Information** → **App Credentials**, find the **Signing Secret**. Copy this — then immediately store it in 1Password:
   ```bash
   op item edit "SnapRestore Slack App" --vault Private signing_secret="xoxb-YOUR-SIGNING-SECRET"
   # Verify it was stored correctly:
   op read "op://Private/SnapRestore Slack App/signing_secret"
   ```
4. (Hold off on creating the Slash Commands until Part 4, when we have the AWS API Gateway URL).

---

## Part 3: Deploying the AWS Lambda Function

The Lambda function bridges the gap between Slack and your Runner machine.

1. In the AWS Console, navigate to **Lambda** and click **Create function**.
2. **Name**: `SlackSnapRestoreTest`
3. **Runtime**: Python 3.12
4. **Architecture**: x86_64 or arm64 (doesn't matter).
5. Click **Create function**.
6. In the code editor, copy the contents of `slack-integration/app.py` from this repository and paste it in. Click **Deploy**.
7. **Set Environment Variables** (use `op read` to retrieve the values — never paste from memory):
   Go to Configuration → Environment variables → Edit and add:
   - `SLACK_SIGNING_SECRET`: Retrieved via `op read "op://Private/SnapRestore Slack App/signing_secret"`
   - `SSM_INSTANCE_ID`: Retrieved via `op read "op://Private/SnapRestore Runner/instance_id"`

   Or use the AWS CLI with `op run` to set them without the values ever appearing in your terminal history:
   ```bash
   # Set Lambda environment variables via AWS CLI, secrets resolved by 1Password at runtime
   SLACK_SIGNING_SECRET=$(op read "op://Private/SnapRestore Slack App/signing_secret")
   SSM_INSTANCE_ID=$(op read "op://Private/SnapRestore Runner/instance_id")

   aws lambda update-function-configuration \
     --function-name SlackSnapRestoreTest \
     --environment "Variables={SLACK_SIGNING_SECRET=${SLACK_SIGNING_SECRET},SSM_INSTANCE_ID=${SSM_INSTANCE_ID}}"
   ```

8. **Configure Permissions**:
   - Go to Configuration → Permissions and click the Role name.
   - Click **Add permissions** → **Create inline policy**.
   - Use the JSON editor to add SSM permissions:
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
   - Name it `SSMInvokePolicy` and save.

---

## Part 4: Exposing Lambda via API Gateway

1. In the AWS Console, navigate to **API Gateway** and click **Create API**.
2. Select **HTTP API** → Build.
3. Click **Add integration**, select **Lambda**, and choose the `SlackSnapRestoreTest` function.
4. Name the API (e.g., `SlackSnapRestoreAPI`) and click Next.
5. Configure Routes:
   - Method: `POST`
   - Resource path: `/slack`
   - Integration target: `SlackSnapRestoreTest`
6. Keep clicking Next and then **Create**.
7. Find the **Invoke URL** for your API (e.g., `https://xyz.execute-api.region.amazonaws.com/slack`). Copy this URL — you will use it for both Slack slash commands in Part 5.

---

## Part 5: Finalizing the Slack Integration

1. Go back to your Slack App configuration at [api.slack.com/apps](https://api.slack.com/apps).
2. Navigate to **Slash Commands** → **Create New Command**.
3. **Configure `/do-snap`**:
   - Command: `/do-snap`
   - Request URL: Paste the API Gateway Invoke URL.
   - Short Description: Take a snapshot of a DO droplet.
   - Save.
4. **Configure `/do-restore`**:
   - Command: `/do-restore`
   - Request URL: Paste the API Gateway Invoke URL.
   - Short Description: Restore a DO droplet from a snapshot.
   - Save.
5. Navigate to **Install App** on the left menu and click **Install to Workspace**. Authorize the app.

---

## Part 6: Testing the Workflow

Now that everything is wired up, let's test it.

### 1. Test the scripts locally on the Runner
Before invoking via Slack, verify the scripts work standalone on your Runner.
SSH into your Runner machine and run:
```bash
cd /opt/snaprestore

# Fetch the token securely from 1Password (if op CLI is configured on the runner)
export DO_API_TOKEN=$(op read "op://Private/DigitalOcean PAT/credential")

# Or use the environment variable if set via /etc/profile.d/do_api.sh
./do-snapshot.sh --dry-run
./do-restore.sh --dry-run
```
Ensure you do not see any missing dependency errors.

### 2. Test via Slack
Go to any channel in your Slack workspace and type:

```text
/do-snap list
```
*(Wait a moment)*
You should see Slack respond with a message indicating the job has been queued, followed shortly by a message containing the list of droplets from your DO account.

Next, try initiating a snapshot (using an actual Droplet ID):
```text
/do-snap 123456789
```
If you want to be cautious during initial testing, you can modify `slack-integration/app.py` to append `--dry-run` to the shell command instead of `--force` while you verify the pipeline.

### Troubleshooting
- **No response in Slack after "Job Queued"**: The SSM command failed to execute or the runner didn't have internet access to curl the `response_url`. Check AWS Systems Manager → Run Command → Command history to see the stdout/stderr of the execution.
- **Unauthorized error in Slack**: Ensure the `SLACK_SIGNING_SECRET` environment variable in Lambda matches exactly what is in your Slack App credentials. Verify with `op read "op://Private/SnapRestore Slack App/signing_secret"`.
- **Command fails with DO token missing**: The SSM agent environment may not have access to the DO token. Verify the runner's `/etc/profile.d/do_api.sh` is set, or configure a 1Password Service Account on the runner and update the scripts to call `op read` at runtime.
- **1Password `op` not found**: Install with `brew install 1password-cli` (macOS) or follow the [Linux install guide](https://developer.1password.com/docs/cli/get-started/). Authenticate with `op signin`.

# Setup Guide for Testing SnapRestore with Slack Integration

Welcome to the **SnapRestore** repository! This guide will help you get fully set up to test the `do-snapshot` and `do-restore` scripts, and importantly, ensure that the Slack integration is properly configured and ready to be used during your testing.

## Prerequisites

Before you begin, ensure you have access to the following:
1. **DigitalOcean Account**: You need an active DO account and a Personal Access Token with read/write permissions.
2. **Slack Workspace**: Permission to create and install Slack Apps in your workspace.
3. **AWS Account**: The Slack integration relies on AWS Lambda, API Gateway, and Systems Manager (SSM) to securely trigger the scripts.
4. **A Runner Server**: An AWS EC2 instance or a DigitalOcean Droplet registered with AWS SSM Hybrid Activations. This machine will execute the bash scripts.

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
5. **Configure Credentials**:
   To allow the SSM agent to authenticate with DigitalOcean without user intervention, export the token globally or set it up in a location accessible by the SSM agent (often runs as `ssm-user` or `root`). A simple way for testing is to add the token to the system-wide environment variables or hardcode it locally for the test run:
   ```bash
   echo 'export DO_API_TOKEN="your_do_personal_access_token_here"' | sudo tee /etc/profile.d/do_api.sh
   ```

*Make note of your Runner's Instance ID (e.g., `i-0abcdef1234567890` or `mi-0123456789abcdef0`).*

---

## Part 2: Setting up the Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App** (From scratch).
2. Name it `SnapRestore Test` and pick your workspace.
3. Under **Basic Information** -> **App Credentials**, find the **Signing Secret**. Copy this; you will need it for the Lambda function.
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
7. **Set Environment Variables**:
   Go to Configuration -> Environment variables -> Edit:
   - `SLACK_SIGNING_SECRET`: Paste the Signing Secret from Slack.
   - `SSM_INSTANCE_ID`: Paste the Instance ID of your runner machine.
8. **Configure Permissions**:
   - Go to Configuration -> Permissions and click the Role name.
   - Click **Add permissions** -> **Create inline policy**.
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
2. Select **HTTP API** -> Build.
3. Click **Add integration**, select **Lambda**, and choose the `SlackSnapRestoreTest` function.
4. Name the API (e.g., `SlackSnapRestoreAPI`) and click Next.
5. Configure Routes:
   - Method: `POST`
   - Resource path: `/slack`
   - Integration target: `SlackSnapRestoreTest`
6. Keep clicking Next and then **Create**.
7. Find the **Invoke URL** for your API (e.g., `https://xyz.execute-api.region.amazonaws.com/slack`). Copy this URL.

---

## Part 5: Finalizing the Slack Integration

1. Go back to your Slack App configuration at [api.slack.com/apps](https://api.slack.com/apps).
2. Navigate to **Slash Commands** -> **Create New Command**.
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
export DO_API_TOKEN="your_do_token"
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
- **No response in Slack after "Job Queued"**: The SSM command failed to execute or the runner didn't have internet access to curl the `response_url`. Check AWS Systems Manager -> Run Command -> Command history to see the stdout/stderr of the execution.
- **Unauthorized error in Slack**: Ensure the `SLACK_SIGNING_SECRET` environment variable in Lambda matches exactly what is in your Slack App credentials.
- **Command fails with DO token missing**: Ensure the SSM agent environment has access to the DO token. You might need to directly inject it into the SSM command within `app.py` or ensure it's loaded securely in `/etc/profile.d/`.

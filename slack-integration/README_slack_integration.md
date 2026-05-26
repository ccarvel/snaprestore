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

## Step 1: Prepare the Runner Machine

You need a machine (EC2, Droplet, or on-prem) with the bash scripts and dependencies (`doctl`, `jq`, `1Password CLI`). 

1. Install the **AWS Systems Manager (SSM) Agent** on the runner.
   - If using AWS EC2, the agent is pre-installed on Amazon Linux and Ubuntu AMIs. Just attach an IAM role with the `AmazonSSMManagedInstanceCore` policy.
   - If using a DigitalOcean Droplet, use [SSM Hybrid Activations](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-managedinstances.html) to register the droplet into AWS SSM.
2. Ensure the scripts are located at `/opt/snaprestore` (or update `app.py` to match your directory).
3. Ensure the `ssm-user` (or `root`) has access to execute the scripts and read the 1Password `op` CLI tokens securely.

*Make note of the Instance ID (e.g., `i-0abcdef1234567890` or `mi-0123456789abcdef0`).*

## Step 2: Create the AWS Lambda

1. Go to AWS Lambda -> **Create function**.
2. Name it `SlackSnapRestore`, runtime **Python 3.12**.
3. Under Execution role, let it create a new basic IAM role.
4. Copy the contents of `slack-integration/app.py` into the inline code editor and Deploy.

## Step 3: Configure Lambda IAM Permissions

Your Lambda needs permission to trigger SSM commands.
1. Go to Configuration -> Permissions -> Click the Role name to open IAM.
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

## Step 4: Configure API Gateway

1. Go to API Gateway -> **Create API** -> HTTP API.
2. Add Integration -> Lambda -> select `SlackSnapRestore`.
3. Give it an API name (e.g., `SlackWebhookAPI`) and create it.
4. Go to **Routes**, ensure there is a `POST` route mapped to your Lambda.
5. Note the **Invoke URL** (e.g., `https://abcdefg.execute-api.us-east-1.amazonaws.com/`).

## Step 5: Configure the Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and **Create New App**.
2. Go to **Slash Commands** -> Create New Command.
   - Command: `/do-snap`
   - Request URL: *Your API Gateway Invoke URL*
   - Description: Take a snapshot of a Droplet
3. Repeat for `/do-restore`.
4. Go to **Basic Information** -> App Credentials. 
   - Copy the **Signing Secret**.

## Step 6: Environment Variables

Go back to AWS Lambda -> Configuration -> Environment variables. Add:
- `SLACK_SIGNING_SECRET` = (paste from Slack)
- `SSM_INSTANCE_ID` = (your runner's instance ID, e.g., `i-xxx`)

## Step 7: Test

Go into your Slack workspace and type:
`/do-snap my-droplet-id`

The Lambda will queue the job, SSM will execute the bash script in non-interactive mode on your secure runner, and within a few minutes, the final output log will be delivered right back into your Slack channel.

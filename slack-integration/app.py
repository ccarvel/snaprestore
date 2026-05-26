import os
import hmac
import hashlib
import time
import json
import urllib.parse
import boto3

def verify_slack_request(headers, body, signing_secret):
    timestamp = headers.get('x-slack-request-timestamp')
    slack_signature = headers.get('x-slack-signature')
    
    if not timestamp or not slack_signature:
        return False
        
    # Prevent replay attacks (5 minute threshold)
    if abs(time.time() - int(timestamp)) > 60 * 5:
        return False
        
    sig_basestring = f"v0:{timestamp}:{body}"
    my_signature = 'v0=' + hmac.new(
        signing_secret.encode('utf-8'),
        sig_basestring.encode('utf-8'),
        hashlib.sha256
    ).hexdigest()
    
    return hmac.compare_digest(my_signature, slack_signature)

def lambda_handler(event, context):
    signing_secret = os.environ.get('SLACK_SIGNING_SECRET')
    instance_id = os.environ.get('SSM_INSTANCE_ID')
    
    if not signing_secret or not instance_id:
        return {'statusCode': 500, 'body': 'Server misconfiguration'}
        
    headers = event.get('headers', {})
    body = event.get('body', '')
    
    # API Gateway might base64 encode the body
    if event.get('isBase64Encoded'):
        import base64
        body = base64.b64decode(body).decode('utf-8')
        
    # Lowercase headers for consistent lookup
    headers = {k.lower(): v for k, v in headers.items()}
    
    if not verify_slack_request(headers, body, signing_secret):
        return {'statusCode': 401, 'body': 'Unauthorized'}
        
    # Parse x-www-form-urlencoded body
    parsed_body = urllib.parse.parse_qs(body)
    command = parsed_body.get('command', [''])[0]
    text = parsed_body.get('text', [''])[0].strip()
    response_url = parsed_body.get('response_url', [''])[0]
    
    if not text:
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({
                'response_type': 'ephemeral',
                'text': 'Please provide a droplet ID or snapshot ID.'
            })
        }
        
    ssm = boto3.client('ssm')
    
    # Map slash command to script
    if command == '/do-snap':
        shell_cmd = f"export DROPLET_ID='{text}' && ./do-snapshot_sh.sh --force"
    elif command == '/do-restore':
        shell_cmd = f"export SNAPSHOT_ID='{text}' && ./do-restore_sh.sh --force"
    else:
        return {'statusCode': 200, 'body': 'Unknown command'}
        
    # Command array for SSM execution
    # NO_COLOR=1 ensures the output doesn't contain unreadable ANSI escape codes in Slack
    # We use jq to safely escape the command output into a JSON payload
    full_cmd = [
        "cd /opt/snaprestore",
        "export NO_COLOR=1",
        f"{shell_cmd} > /tmp/do_out 2>&1",
        f"jq -n --arg text \"*Result for {text}*\\n\\`\\`\\`\\n$(cat /tmp/do_out)\\n\\`\\`\\`\" '{{text: $text, response_type: \"in_channel\"}}' | curl -sS -X POST -H 'Content-Type: application/json' -d @- \"{response_url}\""
    ]

    try:
        ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={'commands': full_cmd}
        )
    except Exception as e:
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({
                'response_type': 'ephemeral',
                'text': f"Failed to trigger SSM command: {str(e)}"
            })
        }

    return {
        'statusCode': 200,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps({
            'response_type': 'in_channel',
            'text': f"⏳ Job queued for `{text}`. Running securely via SSM on the runner machine. You will receive a reply here shortly."
        })
    }

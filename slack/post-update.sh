#!/bin/bash
set -Eeuo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: post-update.sh MESSAGE" >&2
  exit 2
fi

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Missing required env var: $name" >&2
    exit 2
  fi
}

require_env SLACK_BOT_TOKEN
require_env INPUT_SLACK_CHANNEL_ID
require_env INPUT_SLACK_THREAD_TS

jq -n \
  --arg channel "$INPUT_SLACK_CHANNEL_ID" \
  --arg thread_ts "$INPUT_SLACK_THREAD_TS" \
  --arg text "$1" \
  '{channel:$channel, thread_ts:$thread_ts, text:$text}' |
  curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data-binary @- |
  jq -e '.ok == true' >/dev/null

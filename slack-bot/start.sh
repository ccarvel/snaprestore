#!/usr/bin/env bash
# Start the DO Snap Bot using 1Password secret injection.
# Requires: op CLI, uv, .env.op (copied from .env.op.example and populated)
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.op"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  echo "  Copy .env.op.example to .env.op and fill in your 1Password paths." >&2
  exit 1
fi

if ! command -v op &>/dev/null; then
  echo "ERROR: 1Password CLI (op) not found." >&2
  echo "  Install: https://developer.1password.com/docs/cli/get-started/" >&2
  exit 1
fi

if ! command -v uv &>/dev/null; then
  echo "ERROR: uv not found." >&2
  echo "  Install: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi

exec op run --env-file="$ENV_FILE" -- uv run --project "$SCRIPT_DIR" python "$SCRIPT_DIR/bot.py"

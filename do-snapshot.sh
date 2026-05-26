#!/bin/bash
set -Eeuo pipefail

#-----------------------------------------
# CONFIGURATION - Set these or use "list" to fetch
#-----------------------------------------
DO_TOKEN=""                 # Optional: prefer DO_API_TOKEN, DIGITALOCEAN_ACCESS_TOKEN, or OP_DO_TOKEN_REF
OP_DO_TOKEN_REF=""          # Optional: 1Password secret reference, for example op://Vault/Item/credential
DOCTL_CONTEXT=""            # Optional: doctl auth context name
DROPLET_ID=""               # Use "list" to see available droplets
SNAPSHOT_NAME=""            # Optional: defaults to {droplet-name}-snapshot-{date}
POST_ACTION=""              # Optional: start, leave, or delete
LOG_FILE=""                 # Optional: defaults off; use --log-file or set path
POLL_TIMEOUT_SECONDS=900
HTTP_RETRY_MAX=5
#-----------------------------------------

DRY_RUN=0
JSON_OUTPUT=0
VERBOSE=0
QUIET=0
HAS_FZF="no"
DOCTL_ARGS=()
FINAL_STATUS="not-run"
FINAL_JSON="{}"

usage() {
  cat <<'USAGE'
Usage: ./do-snapshot.sh [options]

Options:
  --dry-run             Show planned destructive or mutating actions without running them.
  --json                Print a final machine-readable JSON summary.
  --verbose             Print extra operational detail.
  --quiet               Suppress non-error progress output.
  --log-file PATH       Append redacted run logs to PATH.
  --help                Show this help text.

Config variables still supported:
  DO_TOKEN, OP_DO_TOKEN_REF, DOCTL_CONTEXT, DROPLET_ID, SNAPSHOT_NAME, POST_ACTION

Set DROPLET_ID="list" or "get" to list droplets and exit.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --json) JSON_OUTPUT=1 ;;
    --verbose) VERBOSE=1 ;;
    --quiet) QUIET=1 ;;
    --log-file)
      shift
      if [ "$#" -eq 0 ]; then
        echo "ERROR: --log-file requires a path" >&2
        exit 2
      fi
      LOG_FILE="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

log_line() {
  if [ -n "$LOG_FILE" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"
  fi
}

say() {
  if [ "$QUIET" -eq 0 ]; then
    printf '%s\n' "$*"
  fi
  log_line "$*"
}

verbose() {
  if [ "$VERBOSE" -eq 1 ]; then
    say "$*"
  fi
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
  log_line "WARN: $*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  log_line "ERROR: $*"
  exit 1
}

on_error() {
  local exit_code=$?
  printf 'ERROR: Snapshot workflow failed near line %s.\n' "$1" >&2
  log_line "ERROR: Snapshot workflow failed near line $1"
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

join_by_comma() {
  local IFS=,
  printf '%s' "$*"
}

load_token() {
  DO_TOKEN="${DO_TOKEN:-${DO_API_TOKEN:-${DIGITALOCEAN_ACCESS_TOKEN:-}}}"

  if [ -z "$DO_TOKEN" ] && [ -n "${OP_DO_TOKEN_REF:-}" ]; then
    require_command op
    verbose "Loading DigitalOcean token from 1Password reference."
    DO_TOKEN="$(op read "$OP_DO_TOKEN_REF")"
  fi

  if [ -z "$DO_TOKEN" ]; then
    printf 'DigitalOcean API Token: ' >&2
    IFS= read -rs DO_TOKEN || die "No token read from stdin"
    printf '\n' >&2
  fi

  if [ -z "$DO_TOKEN" ]; then
    die "DigitalOcean API token is required"
  fi

  DOCTL_ARGS=(--access-token "$DO_TOKEN" --http-retry-max "$HTTP_RETRY_MAX")
  if [ -n "$DOCTL_CONTEXT" ]; then
    DOCTL_ARGS+=(--context "$DOCTL_CONTEXT")
  fi
}

doctl_json() {
  doctl "${DOCTL_ARGS[@]}" --output json "$@"
}

doctl_text() {
  doctl "${DOCTL_ARGS[@]}" "$@"
}

select_option() {
  local prompt="$1"
  shift
  local options=("$@")
  local selected=""
  local selection=""
  local i=1

  if [ "${#options[@]}" -eq 0 ]; then
    return 1
  fi

  if [ "$HAS_FZF" = "yes" ]; then
    selected="$(printf '%s\n' "${options[@]}" | fzf --height=15 --prompt="$prompt " || true)"
    if [ -z "$selected" ]; then
      die "Selection cancelled"
    fi
    printf '%s\n' "$selected"
    return 0
  fi

  printf '\n%s\n-------------------\n' "$prompt" >&2
  for opt in "${options[@]}"; do
    printf '  %s) %s\n' "$i" "$opt" >&2
    i=$((i + 1))
  done
  printf '\n' >&2

  while true; do
    printf 'Enter number: ' >&2
    IFS= read -r selection || die "Selection cancelled"
    case "$selection" in
      ''|*[!0-9]*)
        printf 'Enter a number from 1 to %s.\n' "${#options[@]}" >&2
        ;;
      *)
        if [ "$selection" -ge 1 ] && [ "$selection" -le "${#options[@]}" ]; then
          printf '%s\n' "${options[$((selection - 1))]}"
          return 0
        fi
        printf 'Enter a number from 1 to %s.\n' "${#options[@]}" >&2
        ;;
    esac
  done
}

list_droplets() {
  say "Fetching droplets..."
  doctl_json compute droplet list | jq -r '.[] | "\(.ID // .id)  \(.Name // .name)  \(.Status // .status)  \(.Region // .region.slug // .region)  \(.Disk // .disk)GB disk  ip:\(.PublicIPv4 // .networks.v4[0].ip_address // "-")"'
}

get_droplet_by_id() {
  local droplet_id="$1"
  doctl_json compute droplet get "$droplet_id" | jq 'if type == "array" then .[0] else . end'
}

get_droplet_status() {
  local droplet_id="$1"
  get_droplet_by_id "$droplet_id" | jq -r '.Status // .status // "unknown"'
}

wait_for_status() {
  local droplet_id="$1"
  local desired="$2"
  local label="$3"
  local start now elapsed status
  start="$(date +%s)"

  while true; do
    status="$(get_droplet_status "$droplet_id")"
    now="$(date +%s)"
    elapsed=$((now - start))
    if [ "$status" = "$desired" ]; then
      say "$label complete after ${elapsed}s."
      return 0
    fi
    if [ "$elapsed" -ge "$POLL_TIMEOUT_SECONDS" ]; then
      die "$label timed out after ${POLL_TIMEOUT_SECONDS}s; last status: $status"
    fi
    say "  Status: $status (${elapsed}s elapsed)..."
    sleep 5
  done
}

find_reserved_ip_for_droplet() {
  local droplet_id="$1"
  doctl_json compute reserved-ip list | jq -r --arg droplet_id "$droplet_id" '.[] | select((.DropletID // .droplet.id // "")|tostring == $droplet_id) | .IP // .ip' | head -1
}

latest_snapshot_by_name() {
  local snapshot_name="$1"
  doctl_json compute snapshot list --resource droplet | jq --arg name "$snapshot_name" '[.[] | select((.Name // .name) == $name)] | sort_by(.CreatedAt // .created_at // "") | last // {}'
}

confirm_exact() {
  local prompt="$1"
  local expected="$2"
  local actual=""
  printf '%s' "$prompt" >&2
  IFS= read -r actual || die "Confirmation cancelled"
  [ "$actual" = "$expected" ]
}

run_or_dry() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "DRY RUN: doctl $*"
    return 0
  fi
  doctl_text "$@"
}

require_command doctl
require_command jq
if command -v fzf >/dev/null 2>&1; then
  HAS_FZF="yes"
fi

load_token

DROPLET_ID_LOWER="$(lowercase "$DROPLET_ID")"
case "$DROPLET_ID_LOWER" in
  list|get)
    list_droplets
    exit 0
    ;;
esac

say "Fetching droplets..."
DROPLETS_JSON="$(doctl_json compute droplet list)"

if [ -z "$DROPLET_ID" ]; then
  DROPLET_OPTIONS=()
  while IFS= read -r line; do
    [ -n "$line" ] && DROPLET_OPTIONS+=("$line")
  done < <(printf '%s\n' "$DROPLETS_JSON" | jq -r '.[] | "\(.ID // .id)|\(.Name // .name)|\(.Status // .status)|\(.Region // .region.slug // .region)|\(.Disk // .disk)GB|ip:\(.PublicIPv4 // "-")"')

  if [ "${#DROPLET_OPTIONS[@]}" -eq 0 ]; then
    die "No droplets found"
  fi

  SELECTED="$(select_option "Select droplet to snapshot:" "${DROPLET_OPTIONS[@]}")"
  DROPLET_ID="$(printf '%s' "$SELECTED" | cut -d'|' -f1)"
fi

DROPLET="$(printf '%s\n' "$DROPLETS_JSON" | jq --arg id "$DROPLET_ID" '[.[] | select((.ID // .id)|tostring == $id)] | .[0] // {}')"
if [ "$DROPLET" = "{}" ]; then
  DROPLET="$(get_droplet_by_id "$DROPLET_ID")"
fi

DROPLET_NAME="$(printf '%s\n' "$DROPLET" | jq -r '.Name // .name // empty')"
DROPLET_STATUS="$(printf '%s\n' "$DROPLET" | jq -r '.Status // .status // "unknown"')"
DROPLET_REGION="$(printf '%s\n' "$DROPLET" | jq -r '.Region // .region.slug // .region // "unknown"')"
DROPLET_DISK="$(printf '%s\n' "$DROPLET" | jq -r '.Disk // .disk // "unknown"')"
DROPLET_VCPUS="$(printf '%s\n' "$DROPLET" | jq -r '.VCPUs // .vcpus // "unknown"')"
DROPLET_MEMORY="$(printf '%s\n' "$DROPLET" | jq -r '.Memory // .memory // "unknown"')"
DROPLET_IP="$(printf '%s\n' "$DROPLET" | jq -r '.PublicIPv4 // (.networks.v4[]? | select(.type == "public") | .ip_address) // empty' | head -1)"

if [ -z "$DROPLET_NAME" ]; then
  die "Could not resolve droplet details for ID: $DROPLET_ID"
fi

say "Checking for reserved IP..."
DROPLET_RESERVED_IP="$(find_reserved_ip_for_droplet "$DROPLET_ID" || true)"

say ""
say "========================================"
say "Droplet Details"
say "========================================"
say "  ID: $DROPLET_ID"
say "  Name: $DROPLET_NAME"
say "  Status: $DROPLET_STATUS"
say "  Region: $DROPLET_REGION"
say "  vCPUs: $DROPLET_VCPUS"
say "  Memory: ${DROPLET_MEMORY}MB"
say "  Disk: ${DROPLET_DISK}GB"
say "  Public IP: ${DROPLET_IP:-none}"
say "  Reserved IP: ${DROPLET_RESERVED_IP:-none}"
say "========================================"

if [ -z "$SNAPSHOT_NAME" ]; then
  DEFAULT_SNAPSHOT_NAME="${DROPLET_NAME}-snapshot-$(date +%Y%m%d-%H%M)"
  printf 'Snapshot name [%s]: ' "$DEFAULT_SNAPSHOT_NAME" >&2
  IFS= read -r SNAPSHOT_NAME || die "Snapshot name prompt cancelled"
  SNAPSHOT_NAME="${SNAPSHOT_NAME:-$DEFAULT_SNAPSHOT_NAME}"
fi

say ""
say "Snapshot will be named: $SNAPSHOT_NAME"
printf 'Proceed with snapshot? (y/n): ' >&2
IFS= read -r CONFIRM || die "Confirmation cancelled"
if [ "$CONFIRM" != "y" ]; then
  say "Aborted."
  exit 0
fi

if [ "$DROPLET_STATUS" = "active" ]; then
  say ""
  say "Shutting down droplet for clean snapshot..."
  if [ "$DRY_RUN" -eq 1 ]; then
    say "DRY RUN: doctl compute droplet-action shutdown $DROPLET_ID --wait"
  else
    if ! doctl_text compute droplet-action shutdown "$DROPLET_ID" --wait >/dev/null; then
      warn "Graceful shutdown did not complete; using power-off fallback."
      doctl_text compute droplet-action power-off "$DROPLET_ID" --wait >/dev/null
    fi
    wait_for_status "$DROPLET_ID" "off" "Droplet shutdown"
  fi
else
  say ""
  say "Droplet is already off."
fi

say ""
say "Creating snapshot '$SNAPSHOT_NAME'..."
if [ "$DRY_RUN" -eq 1 ]; then
  say "DRY RUN: doctl compute droplet-action snapshot $DROPLET_ID --snapshot-name \"$SNAPSHOT_NAME\" --wait"
else
  doctl_text compute droplet-action snapshot "$DROPLET_ID" --snapshot-name "$SNAPSHOT_NAME" --wait >/dev/null
fi

say "Fetching snapshot details..."
if [ "$DRY_RUN" -eq 1 ]; then
  NEW_SNAPSHOT_ID="dry-run"
  NEW_SNAPSHOT_SIZE="unknown"
  NEW_SNAPSHOT_MIN_DISK="$DROPLET_DISK"
else
  NEW_SNAPSHOT="$(latest_snapshot_by_name "$SNAPSHOT_NAME")"
  NEW_SNAPSHOT_ID="$(printf '%s\n' "$NEW_SNAPSHOT" | jq -r '.ID // .id // empty')"
  NEW_SNAPSHOT_SIZE="$(printf '%s\n' "$NEW_SNAPSHOT" | jq -r '.Size // .size_gigabytes // "unknown"')"
  NEW_SNAPSHOT_MIN_DISK="$(printf '%s\n' "$NEW_SNAPSHOT" | jq -r '.MinDiskSize // .min_disk_size // "unknown"')"
  if [ -z "$NEW_SNAPSHOT_ID" ]; then
    die "Snapshot action completed, but the new snapshot could not be found by name"
  fi
fi

say ""
say "========================================"
say "Snapshot Created Successfully"
say "========================================"
say "  ID: $NEW_SNAPSHOT_ID"
say "  Name: $SNAPSHOT_NAME"
say "  Size: ${NEW_SNAPSHOT_SIZE}GB"
say "  Min Disk: ${NEW_SNAPSHOT_MIN_DISK}GB"
say "========================================"

if [ -z "$POST_ACTION" ]; then
  POST_OPTIONS=("start|Start it back up" "leave|Leave it shut down" "delete|Delete/destroy it")
  SELECTED="$(select_option "Select action:" "${POST_OPTIONS[@]}")"
  POST_ACTION="$(printf '%s' "$SELECTED" | cut -d'|' -f1)"
fi

case "$POST_ACTION" in
  start)
    say ""
    say "Starting droplet..."
    if [ "$DRY_RUN" -eq 1 ]; then
      run_or_dry compute droplet-action power-on "$DROPLET_ID" --wait
    else
      run_or_dry compute droplet-action power-on "$DROPLET_ID" --wait >/dev/null
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
      wait_for_status "$DROPLET_ID" "active" "Droplet start"
    fi
    FINAL_STATUS="started"
    ;;
  leave)
    say ""
    say "Droplet left shut down. You are still billed while the droplet exists."
    FINAL_STATUS="left-off"
    ;;
  delete)
    say ""
    warn "This will permanently delete droplet '$DROPLET_NAME' (ID: $DROPLET_ID)."
    if [ -n "$DROPLET_RESERVED_IP" ]; then
      warn "Reserved IP $DROPLET_RESERVED_IP will be unassigned but not deleted."
    fi
    if ! confirm_exact "Type the exact droplet name to delete it: " "$DROPLET_NAME"; then
      say "Deletion cancelled. Droplet left shut down."
      FINAL_STATUS="delete-cancelled"
    else
      say "Deleting droplet..."
      if [ "$DRY_RUN" -eq 1 ]; then
        run_or_dry compute droplet delete "$DROPLET_ID" --force
      else
        run_or_dry compute droplet delete "$DROPLET_ID" --force >/dev/null
      fi
      FINAL_STATUS="deleted"
    fi
    ;;
  *)
    die "Unknown post-snapshot action: $POST_ACTION"
    ;;
esac

CONNECT_IP="$DROPLET_IP"
if [ -n "$DROPLET_RESERVED_IP" ]; then
  CONNECT_IP="$DROPLET_RESERVED_IP"
fi

FINAL_JSON="$(jq -n \
  --arg status "$FINAL_STATUS" \
  --arg droplet_id "$DROPLET_ID" \
  --arg droplet_name "$DROPLET_NAME" \
  --arg snapshot_id "$NEW_SNAPSHOT_ID" \
  --arg snapshot_name "$SNAPSHOT_NAME" \
  --arg reserved_ip "${DROPLET_RESERVED_IP:-}" \
  --arg connect_ip "${CONNECT_IP:-}" \
  '{status:$status,droplet_id:$droplet_id,droplet_name:$droplet_name,snapshot_id:$snapshot_id,snapshot_name:$snapshot_name,reserved_ip:$reserved_ip,connect_ip:$connect_ip}')"

say ""
say "Done."
if [ "$JSON_OUTPUT" -eq 1 ]; then
  printf '%s\n' "$FINAL_JSON"
fi

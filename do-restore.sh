#!/bin/bash
set -Eeuo pipefail

#-----------------------------------------
# CONFIGURATION - Set these or use "list" to fetch
#-----------------------------------------
DO_TOKEN=""                 # Optional: prefer DO_API_TOKEN, DIGITALOCEAN_ACCESS_TOKEN, or OP_DO_TOKEN_REF
OP_DO_TOKEN_REF=""          # Optional: 1Password secret reference, for example op://Vault/Item/credential
DOCTL_CONTEXT=""            # Optional: doctl auth context name
SNAPSHOT_ID=""              # Use "list" to see available snapshots
SSH_KEY_ID=""               # Use "list" to see available SSH keys; comma-separated IDs are accepted
SIZE_SLUG=""                # Use "list" to see available sizes after setting SNAPSHOT_ID
DROPLET_NAME=""             # Optional: defaults to restored-{snapshot}-{date}
RESERVED_IP=""              # Use "list" to see reserved IPs, or set IP to assign
TAGS=""                     # Optional: comma-separated tag names
VPC_UUID=""                 # Optional: use "list" to see VPCs
USER_DATA_FILE=""           # Optional: cloud-init or shell script file for first boot
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
FINAL_JSON="{}"
RESERVED_IPS_JSON=""
VPCS_JSON=""

usage() {
  cat <<'USAGE'
Usage: ./do-restore.sh [options]

Options:
  --dry-run             Show planned mutating actions without running them.
  --json                Print a final machine-readable JSON summary.
  --verbose             Print extra operational detail.
  --quiet               Suppress non-error progress output.
  --log-file PATH       Append redacted run logs to PATH.
  --help                Show this help text.

Config variables still supported:
  DO_TOKEN, OP_DO_TOKEN_REF, DOCTL_CONTEXT, SNAPSHOT_ID, SSH_KEY_ID, SIZE_SLUG,
  DROPLET_NAME, RESERVED_IP, TAGS, VPC_UUID, USER_DATA_FILE

Set SNAPSHOT_ID, SSH_KEY_ID, SIZE_SLUG, RESERVED_IP, or VPC_UUID to "list" or "get"
to list the corresponding resource and exit.
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
  printf 'ERROR: Restore workflow failed near line %s.\n' "$1" >&2
  log_line "ERROR: Restore workflow failed near line $1"
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
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

json_string_array_from_csv() {
  local value="$1"
  if [ -z "$value" ]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$value" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

csv_from_json_array() {
  jq -r 'join(",")'
}

age_from_iso() {
  local created="$1"
  local created_epoch=""
  local now_epoch=""
  local age_days=""

  if [ -z "$created" ] || [ "$created" = "null" ]; then
    printf 'unknown'
    return 0
  fi

  created_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null || true)"
  if [ -z "$created_epoch" ]; then
    created_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$created" +%s 2>/dev/null || true)"
  fi
  if [ -z "$created_epoch" ]; then
    printf 'unknown'
    return 0
  fi
  now_epoch="$(date +%s)"
  age_days=$(((now_epoch - created_epoch) / 86400))
  printf '%sd' "$age_days"
}

list_snapshots() {
  say "Fetching snapshots..."
  doctl_json compute snapshot list --resource droplet | jq -r '.[] | "\(.ID // .id)  \(.Name // .name)  \(.Size // .size_gigabytes)GB  min_disk:\(.MinDiskSize // .min_disk_size)GB  regions:\((.Regions // .regions // []) | join(","))  created:\(.CreatedAt // .created_at // "-")"'
}

list_ssh_keys() {
  say "Fetching SSH keys..."
  doctl_json compute ssh-key list | jq -r '.[] | "\(.ID // .id)  \(.Name // .name)  \(.FingerPrint // .fingerprint // "-")"'
}

list_reserved_ips() {
  say "Fetching reserved IPs..."
  doctl_json compute reserved-ip list | jq -r '.[] | "\(.IP // .ip)  \(.Region // .region.slug // .region)  droplet:\(.DropletID // .droplet.id // "unassigned")"'
}

list_vpcs() {
  say "Fetching VPCs..."
  doctl_json vpcs list | jq -r '.[] | "\(.ID // .id)|\(.Name // .name)|\(.Region // .region)|default:\(.Default // .default // false)|\(.IPRange // .ip_range // "-")"'
}

load_snapshot() {
  local snapshot_id="$1"
  doctl_json compute snapshot get "$snapshot_id" | jq 'if type == "array" then .[0] else . end'
}

load_droplet() {
  local droplet_id="$1"
  doctl_json compute droplet get "$droplet_id" | jq 'if type == "array" then .[0] else . end'
}

wait_for_reserved_ip_action() {
  local reserved_ip="$1"
  local action_id="$2"
  local start now elapsed status
  start="$(date +%s)"

  while true; do
    status="$(doctl_json compute reserved-ip-action get "$reserved_ip" "$action_id" | jq -r '(if type == "array" then .[0] else . end) | .Status // .status // "unknown"')"
    now="$(date +%s)"
    elapsed=$((now - start))
    case "$status" in
      completed)
        say "Reserved IP assignment complete after ${elapsed}s."
        return 0
        ;;
      errored)
        die "Reserved IP assignment errored"
        ;;
    esac
    if [ "$elapsed" -ge "$POLL_TIMEOUT_SECONDS" ]; then
      die "Reserved IP assignment timed out after ${POLL_TIMEOUT_SECONDS}s; last status: $status"
    fi
    say "  Reserved IP action status: $status (${elapsed}s elapsed)..."
    sleep 5
  done
}

require_command doctl
require_command jq
if command -v fzf >/dev/null 2>&1; then
  HAS_FZF="yes"
fi

load_token

SNAPSHOT_ID_LOWER="$(lowercase "$SNAPSHOT_ID")"
SSH_KEY_ID_LOWER="$(lowercase "$SSH_KEY_ID")"
SIZE_SLUG_LOWER="$(lowercase "$SIZE_SLUG")"
RESERVED_IP_LOWER="$(lowercase "$RESERVED_IP")"
VPC_UUID_LOWER="$(lowercase "$VPC_UUID")"

case "$SNAPSHOT_ID_LOWER" in
  list|get) list_snapshots; exit 0 ;;
esac
case "$SSH_KEY_ID_LOWER" in
  list|get) list_ssh_keys; exit 0 ;;
esac
case "$RESERVED_IP_LOWER" in
  list|get) list_reserved_ips; exit 0 ;;
esac
case "$VPC_UUID_LOWER" in
  list|get) list_vpcs; exit 0 ;;
esac

if [ "$SIZE_SLUG_LOWER" = "list" ] || [ "$SIZE_SLUG_LOWER" = "get" ]; then
  if [ -z "$SNAPSHOT_ID" ] || [ "$SNAPSHOT_ID_LOWER" = "list" ] || [ "$SNAPSHOT_ID_LOWER" = "get" ]; then
    die "Set SNAPSHOT_ID first to list compatible sizes"
  fi
fi

say "Fetching snapshots..."
SNAPSHOTS_JSON="$(doctl_json compute snapshot list --resource droplet)"

if [ -z "$SNAPSHOT_ID" ]; then
  SNAPSHOT_OPTIONS=()
  while IFS= read -r line; do
    [ -n "$line" ] && SNAPSHOT_OPTIONS+=("$line")
  done < <(printf '%s\n' "$SNAPSHOTS_JSON" | jq -r '.[] | "\(.ID // .id)|\(.Name // .name)|\(.Size // .size_gigabytes)GB|min:\(.MinDiskSize // .min_disk_size)GB|regions:\((.Regions // .regions // []) | join(","))|created:\(.CreatedAt // .created_at // "-")"')

  if [ "${#SNAPSHOT_OPTIONS[@]}" -eq 0 ]; then
    die "No snapshots found"
  fi

  SELECTED="$(select_option "Select snapshot:" "${SNAPSHOT_OPTIONS[@]}")"
  SNAPSHOT_ID="$(printf '%s' "$SELECTED" | cut -d'|' -f1)"
fi

SNAPSHOT="$(printf '%s\n' "$SNAPSHOTS_JSON" | jq --arg id "$SNAPSHOT_ID" '[.[] | select((.ID // .id)|tostring == $id)] | .[0] // {}')"
if [ "$SNAPSHOT" = "{}" ]; then
  SNAPSHOT="$(load_snapshot "$SNAPSHOT_ID")"
fi

SNAPSHOT_NAME="$(printf '%s\n' "$SNAPSHOT" | jq -r '.Name // .name // empty')"
SNAPSHOT_SIZE="$(printf '%s\n' "$SNAPSHOT" | jq -r '.Size // .size_gigabytes // "unknown"')"
SNAPSHOT_MIN_DISK="$(printf '%s\n' "$SNAPSHOT" | jq -r '.MinDiskSize // .min_disk_size // 0')"
SNAPSHOT_CREATED="$(printf '%s\n' "$SNAPSHOT" | jq -r '.CreatedAt // .created_at // ""')"
SNAPSHOT_AGE="$(age_from_iso "$SNAPSHOT_CREATED")"
SNAPSHOT_REGION_LIST="$(printf '%s\n' "$SNAPSHOT" | jq -r '(.Regions // .regions // []) | join(",")')"

if [ -z "$SNAPSHOT_NAME" ]; then
  die "Could not resolve snapshot details for ID: $SNAPSHOT_ID"
fi

say ""
say "Selected snapshot: $SNAPSHOT_NAME"
say "  ID: $SNAPSHOT_ID"
say "  Size: ${SNAPSHOT_SIZE}GB"
say "  Min disk: ${SNAPSHOT_MIN_DISK}GB"
say "  Regions: ${SNAPSHOT_REGION_LIST:-unknown}"
say "  Created: ${SNAPSHOT_CREATED:-unknown} (${SNAPSHOT_AGE})"

if [ -z "$SNAPSHOT_REGION_LIST" ]; then
  die "Snapshot has no available regions"
fi

if printf '%s' "$SNAPSHOT_REGION_LIST" | grep -q ','; then
  REGION_OPTIONS=()
  OLD_IFS="$IFS"
  IFS=','
  for region in $SNAPSHOT_REGION_LIST; do
    REGION_OPTIONS+=("$region")
  done
  IFS="$OLD_IFS"
  SELECTED_REGION="$(select_option "Select restore region:" "${REGION_OPTIONS[@]}")"
else
  SELECTED_REGION="$SNAPSHOT_REGION_LIST"
fi

if [ "$SIZE_SLUG_LOWER" = "list" ] || [ "$SIZE_SLUG_LOWER" = "get" ]; then
  say "Fetching sizes compatible with snapshot (min disk: ${SNAPSHOT_MIN_DISK}GB, region: $SELECTED_REGION)..."
  doctl_json compute size list | jq -r --arg region "$SELECTED_REGION" --argjson min_disk "$SNAPSHOT_MIN_DISK" '.[] | select(((.Regions // .regions // []) | length == 0) or (((.Regions // .regions // []) | index($region)) != null)) | select((.Disk // .disk) >= $min_disk) | "\(.Slug // .slug)  \(.VCPUs // .vcpus)vCPU  \(.Memory // .memory)MB RAM  \(.Disk // .disk)GB disk  $\(.PriceMonthly // .price_monthly)/mo"' | sort -t'$' -k2 -n
  exit 0
fi

say ""
say "Fetching droplet sizes..."
SIZES_JSON="$(doctl_json compute size list)"

if [ -z "$SIZE_SLUG" ]; then
  SIZE_OPTIONS=()
  while IFS= read -r line; do
    [ -n "$line" ] && SIZE_OPTIONS+=("$line")
  done < <(printf '%s\n' "$SIZES_JSON" | jq -r --arg region "$SELECTED_REGION" --argjson min_disk "$SNAPSHOT_MIN_DISK" '.[] | select(((.Regions // .regions // []) | length == 0) or (((.Regions // .regions // []) | index($region)) != null)) | select((.Disk // .disk) >= $min_disk) | "\(.Slug // .slug)|\(.VCPUs // .vcpus)vCPU|\(.Memory // .memory)MB|\(.Disk // .disk)GB|$\(.PriceMonthly // .price_monthly)/mo"' | sort -t'$' -k2 -n)

  if [ "${#SIZE_OPTIONS[@]}" -eq 0 ]; then
    die "No compatible droplet sizes found; need >= ${SNAPSHOT_MIN_DISK}GB disk"
  fi

  SELECTED="$(select_option "Select droplet size:" "${SIZE_OPTIONS[@]}")"
  SIZE_SLUG="$(printf '%s' "$SELECTED" | cut -d'|' -f1)"
fi
say "Selected size: $SIZE_SLUG"

if [ -z "$SSH_KEY_ID" ]; then
  printf 'Does this droplet require SSH keys? (y/n): ' >&2
  IFS= read -r NEED_SSH_KEY || die "SSH key prompt cancelled"
  if [ "$NEED_SSH_KEY" = "y" ] || [ "$NEED_SSH_KEY" = "Y" ]; then
    say "Fetching SSH keys..."
    KEYS_JSON="$(doctl_json compute ssh-key list)"
    KEY_OPTIONS=()
    while IFS= read -r line; do
      [ -n "$line" ] && KEY_OPTIONS+=("$line")
    done < <(printf '%s\n' "$KEYS_JSON" | jq -r '.[] | "\(.ID // .id)|\(.Name // .name)|\(.FingerPrint // .fingerprint // "-")"')
    if [ "${#KEY_OPTIONS[@]}" -eq 0 ]; then
      die "No SSH keys found in your account"
    fi
    SELECTED="$(select_option "Select SSH key:" "${KEY_OPTIONS[@]}")"
    SSH_KEY_ID="$(printf '%s' "$SELECTED" | cut -d'|' -f1)"
  fi
fi

SSH_KEYS_JSON="$(json_string_array_from_csv "$SSH_KEY_ID")"
if [ -n "$SSH_KEY_ID" ]; then
  say "Selected SSH key IDs: $SSH_KEY_ID"
else
  say "No SSH key selected."
fi

if [ -z "$RESERVED_IP" ]; then
  printf 'Assign a reserved IP? (y/n): ' >&2
  IFS= read -r NEED_RESERVED_IP || die "Reserved IP prompt cancelled"
  if [ "$NEED_RESERVED_IP" = "y" ] || [ "$NEED_RESERVED_IP" = "Y" ]; then
    say "Fetching reserved IPs..."
    RESERVED_IPS_JSON="$(doctl_json compute reserved-ip list)"
    IP_OPTIONS=()
    while IFS= read -r line; do
      [ -n "$line" ] && IP_OPTIONS+=("$line")
    done < <(printf '%s\n' "$RESERVED_IPS_JSON" | jq -r --arg region "$SELECTED_REGION" '.[] | select((.Region // .region.slug // .region) == $region) | select((.DropletID // .droplet.id // null) == null or (.DropletID // .droplet.id // "") == "") | "\(.IP // .ip)|unassigned|\(.Region // .region.slug // .region)"')
    if [ "${#IP_OPTIONS[@]}" -eq 0 ]; then
      warn "No unassigned reserved IPs found in $SELECTED_REGION."
      RESERVED_IP=""
    else
      SELECTED="$(select_option "Select reserved IP:" "${IP_OPTIONS[@]}")"
      RESERVED_IP="$(printf '%s' "$SELECTED" | cut -d'|' -f1)"
    fi
  fi
fi

RESERVED_IP_DROPLET=""
if [ -n "$RESERVED_IP" ]; then
  RESERVED_IPS_JSON="${RESERVED_IPS_JSON:-$(doctl_json compute reserved-ip list)}"
  RESERVED_RECORD="$(printf '%s\n' "$RESERVED_IPS_JSON" | jq --arg ip "$RESERVED_IP" '[.[] | select((.IP // .ip) == $ip)] | .[0] // {}')"
  if [ "$RESERVED_RECORD" = "{}" ]; then
    die "Reserved IP not found: $RESERVED_IP"
  fi
  RESERVED_REGION="$(printf '%s\n' "$RESERVED_RECORD" | jq -r '.Region // .region.slug // .region // empty')"
  RESERVED_IP_DROPLET="$(printf '%s\n' "$RESERVED_RECORD" | jq -r '.DropletID // .droplet.id // empty')"
  if [ "$RESERVED_REGION" != "$SELECTED_REGION" ]; then
    die "Reserved IP $RESERVED_IP is in $RESERVED_REGION, but restore region is $SELECTED_REGION"
  fi
  if [ -n "$RESERVED_IP_DROPLET" ] && [ "$RESERVED_IP_DROPLET" != "null" ]; then
    warn "Reserved IP $RESERVED_IP is currently assigned to droplet $RESERVED_IP_DROPLET."
    printf 'Type reassign to move this reserved IP: ' >&2
    IFS= read -r REASSIGN_CONFIRM || die "Reserved IP reassignment cancelled"
    if [ "$REASSIGN_CONFIRM" != "reassign" ]; then
      die "Reserved IP reassignment cancelled"
    fi
  fi
fi

if [ -z "$VPC_UUID" ]; then
  printf 'Select a non-default VPC? (y/n): ' >&2
  IFS= read -r NEED_VPC || die "VPC prompt cancelled"
  if [ "$NEED_VPC" = "y" ] || [ "$NEED_VPC" = "Y" ]; then
    VPCS_JSON="$(doctl_json vpcs list)"
    VPC_OPTIONS=()
    while IFS= read -r line; do
      [ -n "$line" ] && VPC_OPTIONS+=("$line")
    done < <(printf '%s\n' "$VPCS_JSON" | jq -r --arg region "$SELECTED_REGION" '.[] | select((.Region // .region) == $region) | "\(.ID // .id)|\(.Name // .name)|default:\(.Default // .default // false)|\(.IPRange // .ip_range // "-")"')
    if [ "${#VPC_OPTIONS[@]}" -eq 0 ]; then
      warn "No VPCs found in $SELECTED_REGION."
    else
      SELECTED="$(select_option "Select VPC:" "${VPC_OPTIONS[@]}")"
      VPC_UUID="$(printf '%s' "$SELECTED" | cut -d'|' -f1)"
    fi
  fi
fi

if [ -n "$VPC_UUID" ]; then
  VPCS_JSON="${VPCS_JSON:-$(doctl_json vpcs list)}"
  VPC_REGION="$(printf '%s\n' "$VPCS_JSON" | jq -r --arg id "$VPC_UUID" '[.[] | select((.ID // .id) == $id)] | .[0] | .Region // .region // empty')"
  if [ -z "$VPC_REGION" ]; then
    die "VPC not found: $VPC_UUID"
  fi
  if [ "$VPC_REGION" != "$SELECTED_REGION" ]; then
    die "VPC $VPC_UUID is in $VPC_REGION, but restore region is $SELECTED_REGION"
  fi
fi

if [ -n "$USER_DATA_FILE" ] && [ ! -f "$USER_DATA_FILE" ]; then
  die "USER_DATA_FILE does not exist: $USER_DATA_FILE"
fi

if [ -z "$DROPLET_NAME" ]; then
  SAFE_SNAPSHOT_NAME="$(printf '%s' "$SNAPSHOT_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
  DEFAULT_NAME="restored-${SAFE_SNAPSHOT_NAME}-$(date +%Y%m%d)"
  printf 'Droplet name [%s]: ' "$DEFAULT_NAME" >&2
  IFS= read -r DROPLET_NAME || die "Droplet name prompt cancelled"
  DROPLET_NAME="${DROPLET_NAME:-$DEFAULT_NAME}"
fi

TAGS_JSON="$(json_string_array_from_csv "$TAGS")"
TAGS_CSV="$(printf '%s\n' "$TAGS_JSON" | csv_from_json_array)"

say ""
say "========================================"
say "Creating droplet"
say "========================================"
say "  Name: $DROPLET_NAME"
say "  Size: $SIZE_SLUG"
say "  Region: $SELECTED_REGION"
say "  Image: $SNAPSHOT_ID ($SNAPSHOT_NAME)"
say "  SSH Keys: $SSH_KEYS_JSON"
say "  Reserved IP: ${RESERVED_IP:-none}"
say "  Tags: ${TAGS_CSV:-none}"
say "  VPC UUID: ${VPC_UUID:-default}"
say "  User data file: ${USER_DATA_FILE:-none}"
say "========================================"
printf 'Proceed? (y/n): ' >&2
IFS= read -r CONFIRM || die "Confirmation cancelled"
if [ "$CONFIRM" != "y" ]; then
  say "Aborted."
  exit 0
fi

CREATE_ARGS=(compute droplet create "$DROPLET_NAME" --size "$SIZE_SLUG" --image "$SNAPSHOT_ID" --region "$SELECTED_REGION" --wait)
if [ -n "$SSH_KEY_ID" ]; then
  CREATE_ARGS+=(--ssh-keys "$SSH_KEY_ID")
fi
if [ -n "$TAGS_CSV" ]; then
  CREATE_ARGS+=(--tag-names "$TAGS_CSV")
fi
if [ -n "$VPC_UUID" ]; then
  CREATE_ARGS+=(--vpc-uuid "$VPC_UUID")
fi
if [ -n "$USER_DATA_FILE" ]; then
  CREATE_ARGS+=(--user-data-file "$USER_DATA_FILE")
fi

if [ "$DRY_RUN" -eq 1 ]; then
  say "DRY RUN: doctl ${CREATE_ARGS[*]}"
  DROPLET_ID="dry-run"
  PUBLIC_IP=""
else
  say "Creating droplet and waiting for active status..."
  CREATE_RESPONSE="$(doctl_json "${CREATE_ARGS[@]}")"
  DROPLET_ID="$(printf '%s\n' "$CREATE_RESPONSE" | jq -r '(if type == "array" then .[0] else . end) | .ID // .id // empty')"
  if [ -z "$DROPLET_ID" ]; then
    die "Droplet create command returned no droplet ID"
  fi
  DROPLET="$(load_droplet "$DROPLET_ID")"
  PUBLIC_IP="$(printf '%s\n' "$DROPLET" | jq -r '.PublicIPv4 // (.networks.v4[]? | select(.type == "public") | .ip_address) // empty' | head -1)"
fi

CONNECT_IP="$PUBLIC_IP"
ASSIGN_ACTION_ID=""
if [ -n "$RESERVED_IP" ]; then
  say ""
  say "Assigning reserved IP $RESERVED_IP to droplet $DROPLET_ID..."
  if [ "$DRY_RUN" -eq 1 ]; then
    say "DRY RUN: doctl compute reserved-ip-action assign $RESERVED_IP $DROPLET_ID"
    CONNECT_IP="$RESERVED_IP"
  else
    ASSIGN_RESPONSE="$(doctl_json compute reserved-ip-action assign "$RESERVED_IP" "$DROPLET_ID")"
    ASSIGN_ACTION_ID="$(printf '%s\n' "$ASSIGN_RESPONSE" | jq -r '(if type == "array" then .[0] else . end) | .ID // .id // empty')"
    if [ -z "$ASSIGN_ACTION_ID" ]; then
      die "Reserved IP assignment returned no action ID"
    fi
    wait_for_reserved_ip_action "$RESERVED_IP" "$ASSIGN_ACTION_ID"
    CONNECT_IP="$RESERVED_IP"
  fi
fi

say ""
say "========================================"
say "Restore Complete"
say "========================================"
say "  Droplet ID: $DROPLET_ID"
say "  Name: $DROPLET_NAME"
say "  Region: $SELECTED_REGION"
say "  Public IP: ${PUBLIC_IP:-pending}"
say "  Reserved IP: ${RESERVED_IP:-none}"
if [ -n "$CONNECT_IP" ]; then
  say "  SSH: ssh root@$CONNECT_IP"
else
  say "  SSH: pending public IP assignment"
fi
say "========================================"

FINAL_JSON="$(jq -n \
  --arg status "restored" \
  --arg droplet_id "$DROPLET_ID" \
  --arg droplet_name "$DROPLET_NAME" \
  --arg snapshot_id "$SNAPSHOT_ID" \
  --arg snapshot_name "$SNAPSHOT_NAME" \
  --arg region "$SELECTED_REGION" \
  --arg size "$SIZE_SLUG" \
  --arg public_ip "${PUBLIC_IP:-}" \
  --arg reserved_ip "${RESERVED_IP:-}" \
  --arg connect_ip "${CONNECT_IP:-}" \
  --arg vpc_uuid "${VPC_UUID:-}" \
  --arg user_data_file "${USER_DATA_FILE:-}" \
  --argjson ssh_keys "$SSH_KEYS_JSON" \
  --argjson tags "$TAGS_JSON" \
  '{status:$status,droplet_id:$droplet_id,droplet_name:$droplet_name,snapshot_id:$snapshot_id,snapshot_name:$snapshot_name,region:$region,size:$size,public_ip:$public_ip,reserved_ip:$reserved_ip,connect_ip:$connect_ip,vpc_uuid:$vpc_uuid,user_data_file:$user_data_file,ssh_keys:$ssh_keys,tags:$tags}')"

if [ "$JSON_OUTPUT" -eq 1 ]; then
  printf '%s\n' "$FINAL_JSON"
fi

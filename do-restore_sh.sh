#!/bin/bash
set -eo pipefail

#-----------------------------------------
# CONFIGURATION - Edit these or use flags/env vars
#-----------------------------------------
SNAPSHOT_ID=""      # Snapshot ID, or leave blank for interactive selection
SSH_KEY_ID=""       # SSH key ID (comma-separated for multiple), or blank to prompt
SIZE_SLUG=""        # Droplet size slug, or blank to prompt
DROPLET_NAME=""     # Optional: defaults to restored-{snapshot-name}-{date}
RESERVED_IP=""      # Reserved IP to assign, or blank to prompt
OP_ITEM=""          # Optional: 1Password path, e.g. op://Private/DigitalOcean/token
DOCTL_CONTEXT=""    # Optional: doctl auth context name, e.g. "snaprestore"
#-----------------------------------------

# --- Flag parsing ---
DRY_RUN=false
QUIET=false
JSON_OUT=false
LOG_FILE=""
TAGS=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --dry-run       Print operations without executing any API calls
  --quiet         Suppress all non-error output
  --json          Emit final state as JSON on stdout
  --log FILE      Tee all output to FILE (appends)
  --tags TAGS     Comma-separated tags to apply to the new droplet
  --help          Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --quiet)   QUIET=true ;;
    --json)    JSON_OUT=true ;;
    --log)     LOG_FILE="$2"; shift ;;
    --tags)    TAGS="$2"; shift ;;
    --help)    usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# --- Logging setup ---
if [[ -n "$LOG_FILE" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

# --- Output helpers ---
info() { [[ "$QUIET" == true ]] && return 0; echo "  $*"; }
ok()   { [[ "$QUIET" == true ]] && return 0; echo "  ✓ $*"; }
warn() { echo "  ⚠ $*" >&2; }
err()  { echo "  ✗ $*" >&2; }

header() {
  [[ "$QUIET" == true ]] && return 0
  echo ""
  echo "========================================"
  echo "  $*"
  echo "========================================"
}

# --- Cleanup trap ---
CURRENT_OP=""
NEW_DROPLET_ID=""

cleanup() {
  local code=$?
  if [[ $code -ne 0 && -n "$CURRENT_OP" ]]; then
    echo "" >&2
    warn "Interrupted during: $CURRENT_OP"
    [[ -n "$NEW_DROPLET_ID" ]] && warn "Partially provisioned droplet ID: $NEW_DROPLET_ID — check console"
    warn "Check console: https://cloud.digitalocean.com/droplets"
  fi
}
trap cleanup EXIT

# --- fzf check ---
HAS_FZF=$(command -v fzf &>/dev/null && echo "yes" || echo "no")

# Generic selection: fzf if available, numbered menu otherwise
select_option() {
  local prompt="$1"
  shift
  local options=("$@")

  if [[ "$HAS_FZF" == "yes" ]]; then
    printf '%s\n' "${options[@]}" | fzf \
      --height=15 \
      --prompt="$prompt " \
      --header="↑↓ navigate  Enter select  Ctrl-C abort"
  else
    echo "" >&2
    echo "$prompt" >&2
    echo "-------------------" >&2
    local i=1
    for opt in "${options[@]}"; do
      echo "  $i) $opt" >&2
      ((i++))
    done
    echo "" >&2
    local selection
    read -rp "Enter number: " selection
    [[ -z "$selection" ]] && { err "No selection made."; exit 1; }
    echo "${options[$((selection - 1))]}"
  fi
}

# --- Token loading: op → env var → prompt ---
load_token() {
  local token=""

  if [[ -n "$OP_ITEM" ]]; then
    if command -v op &>/dev/null; then
      token=$(op read "$OP_ITEM" 2>/dev/null) || warn "op read failed for '$OP_ITEM' — falling back"
    else
      warn "'op' CLI not found — falling back to env var"
    fi
  fi

  [[ -z "$token" && -n "$DIGITALOCEAN_ACCESS_TOKEN" ]] && token="$DIGITALOCEAN_ACCESS_TOKEN"
  [[ -z "$token" && -n "$DO_API_TOKEN" ]]              && token="$DO_API_TOKEN"

  if [[ -z "$token" && -z "$DOCTL_CONTEXT" ]]; then
    read -rsp "DigitalOcean API Token: " token
    echo
    [[ -z "$token" ]] && { err "Token required."; exit 1; }
  fi

  [[ -n "$token" ]] && export DIGITALOCEAN_ACCESS_TOKEN="$token"
}

# --- doctl checks ---
check_doctl() {
  if ! command -v doctl &>/dev/null; then
    err "doctl is required but not installed."
    err "  Install:  brew install doctl"
    err "  Auth:     doctl auth init --context snaprestore"
    exit 1
  fi
}

# Wraps doctl with optional --context
doctl_cmd() {
  if [[ -n "$DOCTL_CONTEXT" ]]; then
    doctl --context "$DOCTL_CONTEXT" "$@"
  else
    doctl "$@"
  fi
}

check_doctl
load_token

# --- list|get dispatch ---
SNAPSHOT_ID_LOWER=$(echo "$SNAPSHOT_ID"   | tr '[:upper:]' '[:lower:]')
SSH_KEY_ID_LOWER=$(echo "$SSH_KEY_ID"     | tr '[:upper:]' '[:lower:]')
SIZE_SLUG_LOWER=$(echo "$SIZE_SLUG"       | tr '[:upper:]' '[:lower:]')
RESERVED_IP_LOWER=$(echo "$RESERVED_IP"   | tr '[:upper:]' '[:lower:]')

case "$SNAPSHOT_ID_LOWER" in
  list|get)
    doctl_cmd compute snapshot list --resource droplet \
      --format "ID,Name,MinDiskSize,SizeGigaBytes,Created,Regions"
    exit 0 ;;
esac

case "$SSH_KEY_ID_LOWER" in
  list|get)
    doctl_cmd compute ssh-key list --format "ID,Name,Fingerprint"
    exit 0 ;;
esac

case "$SIZE_SLUG_LOWER" in
  list|get)
    [[ -z "$SNAPSHOT_ID" ]] && { err "Set SNAPSHOT_ID first to list compatible sizes."; exit 1; }
    SNAP_INFO=$(doctl_cmd compute snapshot list --resource droplet --output json | \
      jq -r --arg id "$SNAPSHOT_ID" '.[] | select(.id == $id)')
    MIN_DISK=$(echo "$SNAP_INFO" | jq -r '.min_disk_size')
    REGION=$(echo "$SNAP_INFO"   | jq -r '.regions[0]')
    info "Compatible sizes (min disk: ${MIN_DISK}GB, region: $REGION)..."
    doctl_cmd compute size list --output json | \
      jq -r --arg region "$REGION" --argjson min_disk "$MIN_DISK" \
      '.[] | select(.available==true) | select(.regions[] == $region) | select(.disk >= $min_disk) |
       "\(.slug)  \(.vcpus)vCPU  \(.memory)MB RAM  \(.disk)GB disk  $\(.price_monthly)/mo"' | \
      sort -t'$' -k2 -n
    exit 0 ;;
esac

case "$RESERVED_IP_LOWER" in
  list|get)
    doctl_cmd compute reserved-ip list \
      --format "IP,Region,DropletID,DropletName"
    exit 0 ;;
esac

# --- Fetch snapshots ---
info "Fetching snapshots..."
SNAPSHOTS_JSON=$(doctl_cmd compute snapshot list --resource droplet --output json)

# --- Select snapshot (with age display) ---
if [[ -z "$SNAPSHOT_ID" ]]; then
  mapfile -t SNAPSHOT_OPTIONS < <(
    echo "$SNAPSHOTS_JSON" | jq -r \
      '.[] |
       (now - (.created_at | fromdateiso8601) | . / 86400 | floor | tostring) as $age |
       "\(.id)|\(.name)|\(.size_gigabytes)GB|min:\(.min_disk_size)GB|\(.regions | join(","))|\($age)d ago"'
  )
  [[ ${#SNAPSHOT_OPTIONS[@]} -eq 0 ]] && { err "No snapshots found."; exit 1; }

  SELECTED=$(select_option "Select snapshot:" "${SNAPSHOT_OPTIONS[@]}")
  [[ -z "$SELECTED" ]] && { err "No selection made."; exit 1; }
  SNAPSHOT_ID=$(echo "$SELECTED" | cut -d'|' -f1)
fi

# --- Get snapshot details (single jq pass) ---
SNAPSHOT_JSON=$(echo "$SNAPSHOTS_JSON" | jq --arg id "$SNAPSHOT_ID" '.[] | select(.id == $id)')
[[ -z "$SNAPSHOT_JSON" ]] && { err "Snapshot $SNAPSHOT_ID not found."; exit 1; }

SNAPSHOT_NAME=$(echo "$SNAPSHOT_JSON"     | jq -r '.name')
SNAPSHOT_SIZE=$(echo "$SNAPSHOT_JSON"     | jq -r '.size_gigabytes')
SNAPSHOT_MIN_DISK=$(echo "$SNAPSHOT_JSON" | jq -r '.min_disk_size')
SNAPSHOT_REGION=$(echo "$SNAPSHOT_JSON"   | jq -r '.regions[0]')
SNAPSHOT_REGIONS_ALL=$(echo "$SNAPSHOT_JSON" | jq -r '.regions | join(", ")')
SNAPSHOT_CREATED=$(echo "$SNAPSHOT_JSON"  | jq -r '.created_at')
SNAPSHOT_AGE=$(echo "$SNAPSHOT_JSON" | jq -r \
  '(now - (.created_at | fromdateiso8601) | . / 86400 | floor | tostring) + " days"')

echo ""
info "Selected:     $SNAPSHOT_NAME"
info "Compressed:   ${SNAPSHOT_SIZE}GB  (source disk: ${SNAPSHOT_MIN_DISK}GB)"
info "Created:      $SNAPSHOT_CREATED  ($SNAPSHOT_AGE ago)"
info "Regions:      $SNAPSHOT_REGIONS_ALL"

# --- Fetch compatible sizes ---
echo ""
info "Fetching compatible droplet sizes..."
SIZES_JSON=$(doctl_cmd compute size list --output json)

if [[ -z "$SIZE_SLUG" ]]; then
  mapfile -t SIZE_OPTIONS < <(
    echo "$SIZES_JSON" | jq -r \
      --arg region "$SNAPSHOT_REGION" \
      --argjson min_disk "$SNAPSHOT_MIN_DISK" \
      '.[] | select(.available==true) | select(.regions[] == $region) | select(.disk >= $min_disk) |
       "\(.slug)|\(.vcpus)vCPU|\(.memory)MB|\(.disk)GB disk|$\(.price_monthly)/mo"' | \
      sort -t'$' -k2 -n
  )
  [[ ${#SIZE_OPTIONS[@]} -eq 0 ]] && {
    err "No compatible sizes found (need >= ${SNAPSHOT_MIN_DISK}GB disk in $SNAPSHOT_REGION)."
    exit 1
  }
  SELECTED=$(select_option "Select droplet size:" "${SIZE_OPTIONS[@]}")
  [[ -z "$SELECTED" ]] && { err "No selection made."; exit 1; }
  SIZE_SLUG=$(echo "$SELECTED" | cut -d'|' -f1)
fi
info "Size: $SIZE_SLUG"

# --- Fetch SSH keys ---
echo ""
info "Fetching SSH keys..."
KEYS_JSON=$(doctl_cmd compute ssh-key list --output json)

if [[ -z "$SSH_KEY_ID" ]]; then
  read -rp "  Attach an SSH key? (y/n): " NEED_KEY
  if [[ "$NEED_KEY" == "y" || "$NEED_KEY" == "Y" ]]; then
    mapfile -t KEY_OPTIONS < <(
      echo "$KEYS_JSON" | jq -r '.[] | "\(.id)|\(.name)"'
    )
    [[ ${#KEY_OPTIONS[@]} -eq 0 ]] && { err "No SSH keys found in your account."; exit 1; }
    SELECTED=$(select_option "Select SSH key:" "${KEY_OPTIONS[@]}")
    [[ -z "$SELECTED" ]] && { err "No selection made."; exit 1; }
    SSH_KEY_ID=$(echo "$SELECTED" | cut -d'|' -f1)
    info "SSH key: $SSH_KEY_ID"
  fi
fi

# --- Reserved IP ---
if [[ -z "$RESERVED_IP" ]]; then
  echo ""
  read -rp "  Assign a reserved IP? (y/n): " NEED_IP
  if [[ "$NEED_IP" == "y" || "$NEED_IP" == "Y" ]]; then
    RESERVED_IPS_JSON=$(doctl_cmd compute reserved-ip list --output json)
    mapfile -t IP_OPTIONS < <(
      echo "$RESERVED_IPS_JSON" | jq -r \
        --arg region "$SNAPSHOT_REGION" \
        '.[] | select(.region.slug == $region) | select(.droplet == null) |
         "\(.ip)|unassigned|\(.region.slug)"'
    )
    if [[ ${#IP_OPTIONS[@]} -eq 0 ]]; then
      warn "No unassigned reserved IPs found in $SNAPSHOT_REGION."
    else
      SELECTED=$(select_option "Select reserved IP:" "${IP_OPTIONS[@]}")
      RESERVED_IP=$(echo "$SELECTED" | cut -d'|' -f1)
      info "Reserved IP: $RESERVED_IP"
    fi
  fi
else
  # Validate region and current assignment for hardcoded IPs
  RESERVED_IPS_JSON=$(doctl_cmd compute reserved-ip list --output json)
  HARDCODED_REGION=$(echo "$RESERVED_IPS_JSON" | jq -r \
    --arg ip "$RESERVED_IP" '.[] | select(.ip == $ip) | .region.slug')
  HARDCODED_CURRENT=$(echo "$RESERVED_IPS_JSON" | jq -r \
    --arg ip "$RESERVED_IP" '.[] | select(.ip == $ip) | (.droplet.name // "unassigned")')

  if [[ -n "$HARDCODED_REGION" && "$HARDCODED_REGION" != "$SNAPSHOT_REGION" ]]; then
    err "Reserved IP $RESERVED_IP is in region $HARDCODED_REGION but snapshot is in $SNAPSHOT_REGION."
    err "Set RESERVED_IP to an IP in $SNAPSHOT_REGION or leave blank."
    exit 1
  fi

  if [[ "$HARDCODED_CURRENT" != "unassigned" ]]; then
    warn "Reserved IP $RESERVED_IP is currently assigned to: $HARDCODED_CURRENT"
    read -rp "  Reassign away from '$HARDCODED_CURRENT'? (yes/no): " REASSIGN_CONFIRM
    [[ "$REASSIGN_CONFIRM" != "yes" ]] && { info "Aborted."; exit 0; }
  fi
fi

# --- Droplet name ---
if [[ -z "$DROPLET_NAME" ]]; then
  DEFAULT_NAME="restored-$(echo "$SNAPSHOT_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')-$(date +%Y%m%d)"
  read -rp "  Droplet name [$DEFAULT_NAME]: " DROPLET_NAME
  DROPLET_NAME="${DROPLET_NAME:-$DEFAULT_NAME}"
fi

# --- Confirm summary ---
header "Creating Droplet"
info "Name:        $DROPLET_NAME"
info "Size:        $SIZE_SLUG"
info "Region:      $SNAPSHOT_REGION"
info "Image:       $SNAPSHOT_ID ($SNAPSHOT_NAME)"
[[ -n "$SSH_KEY_ID"  ]] && info "SSH Key:     $SSH_KEY_ID"
[[ -n "$RESERVED_IP" ]] && info "Reserved IP: $RESERVED_IP"
[[ -n "$TAGS"        ]] && info "Tags:        $TAGS"
echo ""
read -rp "Proceed? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && { info "Aborted."; exit 0; }

# --- Build doctl create args ---
CREATE_ARGS=(
  compute droplet create "$DROPLET_NAME"
  --image   "$SNAPSHOT_ID"
  --size    "$SIZE_SLUG"
  --region  "$SNAPSHOT_REGION"
  --wait
)
[[ -n "$SSH_KEY_ID" ]] && CREATE_ARGS+=(--ssh-keys "$SSH_KEY_ID")
[[ -n "$TAGS"       ]] && CREATE_ARGS+=(--tag-names "$TAGS")

# --- Create droplet ---
CURRENT_OP="create droplet '$DROPLET_NAME' from snapshot $SNAPSHOT_ID"
echo ""

if [[ "$DRY_RUN" == true ]]; then
  info "[DRY-RUN] doctl ${CREATE_ARGS[*]}"
  NEW_DROPLET_ID="(dry-run)"
  NEW_DROPLET_IP="(dry-run)"
else
  info "Creating droplet (this may take 1–2 minutes)..."
  CREATE_OUTPUT=$(doctl_cmd "${CREATE_ARGS[@]}" --output json)
  NEW_DROPLET_ID=$(echo "$CREATE_OUTPUT" | jq -r 'if type=="array" then .[0].id else .id end')
  NEW_DROPLET_IP=$(echo "$CREATE_OUTPUT" | jq -r '
    (if type=="array" then .[0] else . end) |
    first(.networks.v4[] | select(.type=="public") | .ip_address)')
  ok "Droplet active.  ID: $NEW_DROPLET_ID  IP: $NEW_DROPLET_IP"
fi
CURRENT_OP=""

# --- Assign reserved IP ---
CONNECT_IP="${NEW_DROPLET_IP}"

if [[ -n "$RESERVED_IP" ]]; then
  echo ""
  info "Assigning reserved IP $RESERVED_IP to droplet $NEW_DROPLET_ID..."
  CURRENT_OP="assign reserved IP $RESERVED_IP to droplet $NEW_DROPLET_ID"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] doctl compute reserved-ip-action assign $RESERVED_IP $NEW_DROPLET_ID"
    CONNECT_IP="$RESERVED_IP"
  else
    ASSIGN_OUTPUT=$(doctl_cmd compute reserved-ip-action assign "$RESERVED_IP" "$NEW_DROPLET_ID" \
      --output json)
    ASSIGN_ACTION_ID=$(echo "$ASSIGN_OUTPUT" | jq -r '.action.id // .[0].id')

    # Poll for completion — bounded at 2 minutes (24 × 5 s)
    ASSIGN_STATUS=""
    for _ in $(seq 1 24); do
      ASSIGN_STATUS=$(doctl_cmd compute action get "$ASSIGN_ACTION_ID" --output json | \
        jq -r 'if type=="array" then .[0].status else .status end')
      [[ "$ASSIGN_STATUS" == "completed" ]] && break
      [[ "$ASSIGN_STATUS" == "errored"   ]] && break
      sleep 5
    done

    if [[ "$ASSIGN_STATUS" == "completed" ]]; then
      ok "Reserved IP assigned."
      CONNECT_IP="$RESERVED_IP"
    else
      err "Reserved IP assignment did not complete (status: $ASSIGN_STATUS)."
      warn "Connect for now with: ssh root@$NEW_DROPLET_IP"
      warn "Assign manually: doctl compute reserved-ip-action assign $RESERVED_IP $NEW_DROPLET_ID"
    fi
  fi
  CURRENT_OP=""
fi

# --- Final summary ---
header "Done"
info "Droplet ID:    $NEW_DROPLET_ID"
info "Droplet IP:    $NEW_DROPLET_IP"
[[ -n "$RESERVED_IP" ]] && info "Reserved IP:   $RESERVED_IP"
[[ -n "$TAGS"         ]] && info "Tags:          $TAGS"
echo ""
info "Connect:       ssh root@$CONNECT_IP"
echo ""

# --- JSON output ---
if [[ "$JSON_OUT" == true ]]; then
  jq -n \
    --arg droplet_id   "$NEW_DROPLET_ID" \
    --arg droplet_name "$DROPLET_NAME" \
    --arg droplet_ip   "$NEW_DROPLET_IP" \
    --arg reserved_ip  "${RESERVED_IP:-}" \
    --arg connect_ip   "$CONNECT_IP" \
    --arg snapshot_id  "$SNAPSHOT_ID" \
    --arg snapshot_name "$SNAPSHOT_NAME" \
    --arg size         "$SIZE_SLUG" \
    --arg region       "$SNAPSHOT_REGION" \
    --arg tags         "${TAGS:-}" \
    '{
      droplet_id:    $droplet_id,
      droplet_name:  $droplet_name,
      droplet_ip:    $droplet_ip,
      reserved_ip:   $reserved_ip,
      connect_ip:    $connect_ip,
      snapshot_id:   $snapshot_id,
      snapshot_name: $snapshot_name,
      size:          $size,
      region:        $region,
      tags:          ($tags | if . == "" then [] else split(",") end)
    }'
fi

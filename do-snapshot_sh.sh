#!/bin/bash
set -eo pipefail

#-----------------------------------------
# CONFIGURATION - Edit these or use flags/env vars
#-----------------------------------------
DROPLET_ID=""       # Droplet ID, or leave blank for interactive selection
SNAPSHOT_NAME=""    # Optional: defaults to {droplet-name}-snapshot-{date}
OP_ITEM=""          # Optional: 1Password path, e.g. op://Private/DigitalOcean/token
DOCTL_CONTEXT=""    # Optional: doctl auth context name, e.g. "snaprestore"
#-----------------------------------------

# --- Flag parsing ---
DRY_RUN=false
QUIET=false
JSON_OUT=false
LOG_FILE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --dry-run     Print operations without executing any API calls
  --quiet       Suppress all non-error output
  --json        Emit final state as JSON on stdout
  --log FILE    Tee all output to FILE (appends)
  --help        Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --quiet)   QUIET=true ;;
    --json)    JSON_OUT=true ;;
    --log)     LOG_FILE="$2"; shift ;;
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
CREATED_RESOURCE=""

cleanup() {
  local code=$?
  if [[ $code -ne 0 && -n "$CURRENT_OP" ]]; then
    echo "" >&2
    warn "Interrupted during: $CURRENT_OP"
    [[ -n "$CREATED_RESOURCE" ]] && warn "Resource may be in unknown state: $CREATED_RESOURCE"
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
DROPLET_ID_LOWER=$(echo "$DROPLET_ID" | tr '[:upper:]' '[:lower:]')
case "$DROPLET_ID_LOWER" in
  list|get)
    doctl_cmd compute droplet list \
      --format "ID,Name,Status,Size,Region,Disk,Memory,VCPUs"
    exit 0
    ;;
esac

# --- Fetch droplets ---
info "Fetching droplets..."
DROPLETS_JSON=$(doctl_cmd compute droplet list --output json)

# --- Select droplet ---
if [[ -z "$DROPLET_ID" ]]; then
  mapfile -t DROPLET_OPTIONS < <(
    echo "$DROPLETS_JSON" | jq -r \
      '.[] | "\(.id)|\(.name)|\(.status)|\(.size_slug)|\(.region.slug)|\(.disk)GB"'
  )
  [[ ${#DROPLET_OPTIONS[@]} -eq 0 ]] && { err "No droplets found."; exit 1; }

  SELECTED=$(select_option "Select droplet to snapshot:" "${DROPLET_OPTIONS[@]}")
  [[ -z "$SELECTED" ]] && { err "No selection made."; exit 1; }
  DROPLET_ID=$(echo "$SELECTED" | cut -d'|' -f1)
fi

# --- Get droplet details (single jq pass) ---
DROPLET_JSON=$(echo "$DROPLETS_JSON" | jq -r --argjson id "$DROPLET_ID" '.[] | select(.id == $id)')
[[ -z "$DROPLET_JSON" ]] && { err "Droplet $DROPLET_ID not found."; exit 1; }

read -r DROPLET_NAME DROPLET_STATUS DROPLET_SIZE DROPLET_REGION \
       DROPLET_DISK DROPLET_VCPUS DROPLET_MEMORY DROPLET_IP <<EOF
$(echo "$DROPLET_JSON" | jq -r '[
  .name, .status, .size_slug, .region.slug,
  (.disk | tostring), (.vcpus | tostring), (.memory | tostring),
  (first(.networks.v4[] | select(.type == "public") | .ip_address) // "none")
] | @tsv')
EOF

# --- Reserved IP check ---
info "Checking for reserved IP..."
RESERVED_IPS_JSON=$(doctl_cmd compute reserved-ip list --output json)
DROPLET_RESERVED_IP=$(echo "$RESERVED_IPS_JSON" | jq -r \
  --argjson id "$DROPLET_ID" \
  '.[] | select(.droplet.id == $id) | .ip')

# --- Display droplet ---
header "Droplet Details"
info "ID:          $DROPLET_ID"
info "Name:        $DROPLET_NAME"
info "Status:      $DROPLET_STATUS"
info "Region:      $DROPLET_REGION"
info "Size:        $DROPLET_SIZE"
info "vCPUs:       $DROPLET_VCPUS"
info "Memory:      ${DROPLET_MEMORY}MB"
info "Disk:        ${DROPLET_DISK}GB"
info "Public IP:   $DROPLET_IP"
if [[ -n "$DROPLET_RESERVED_IP" ]]; then
  info "Reserved IP: $DROPLET_RESERVED_IP"
else
  info "Reserved IP: (none)"
fi
echo ""

# --- Snapshot name ---
if [[ -z "$SNAPSHOT_NAME" ]]; then
  DEFAULT_SNAPSHOT_NAME="${DROPLET_NAME}-snapshot-$(date +%Y%m%d-%H%M)"
  read -rp "  Snapshot name [$DEFAULT_SNAPSHOT_NAME]: " SNAPSHOT_NAME
  SNAPSHOT_NAME="${SNAPSHOT_NAME:-$DEFAULT_SNAPSHOT_NAME}"
fi

info "Snapshot will be named: $SNAPSHOT_NAME"
echo ""

# --- Confirm ---
read -rp "Proceed with snapshot? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && { info "Aborted."; exit 0; }

# --- Shutdown ---
if [[ "$DROPLET_STATUS" == "active" ]]; then
  echo ""
  info "Shutting down droplet for clean snapshot..."
  CURRENT_OP="shutdown droplet $DROPLET_ID ($DROPLET_NAME)"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] doctl compute droplet-action shutdown $DROPLET_ID --wait"
  else
    if ! doctl_cmd compute droplet-action shutdown "$DROPLET_ID" \
         --wait --output json > /dev/null 2>&1; then
      warn "Graceful shutdown failed — attempting power-off..."
      CURRENT_OP="power-off droplet $DROPLET_ID ($DROPLET_NAME)"
      doctl_cmd compute droplet-action power-off "$DROPLET_ID" \
        --wait --output json > /dev/null || {
        err "Power-off failed. Check droplet state in console before proceeding."
        exit 1
      }
    fi
    ok "Droplet stopped."
  fi
  CURRENT_OP=""
else
  info "Droplet is already off."
fi

# --- Create snapshot ---
echo ""
info "Creating snapshot '$SNAPSHOT_NAME' (this may take several minutes)..."
CURRENT_OP="snapshot droplet $DROPLET_ID ($DROPLET_NAME)"
CREATED_RESOURCE="snapshot of $DROPLET_NAME"

if [[ "$DRY_RUN" == true ]]; then
  info "[DRY-RUN] doctl compute droplet-action snapshot $DROPLET_ID --snapshot-name \"$SNAPSHOT_NAME\" --wait"
  NEW_SNAPSHOT_ID="(dry-run)"
  NEW_SNAPSHOT_SIZE="0"
  NEW_SNAPSHOT_MIN_DISK="$DROPLET_DISK"
  NEW_SNAPSHOT_REGIONS="$DROPLET_REGION"
  COST_EST="0.00"
else
  doctl_cmd compute droplet-action snapshot "$DROPLET_ID" \
    --snapshot-name "$SNAPSHOT_NAME" \
    --wait \
    --output json > /dev/null
  ok "Snapshot complete."

  # Fetch snapshot details — most recently created match avoids name-collision bugs
  echo ""
  info "Fetching snapshot details..."
  SNAP_JSON=$(doctl_cmd compute snapshot list --resource droplet --output json | \
    jq --arg name "$SNAPSHOT_NAME" \
    '[.[] | select(.name == $name)] | sort_by(.created_at) | last')

  NEW_SNAPSHOT_ID=$(echo "$SNAP_JSON"       | jq -r '.id')
  NEW_SNAPSHOT_SIZE=$(echo "$SNAP_JSON"     | jq -r '.size_gigabytes')
  NEW_SNAPSHOT_MIN_DISK=$(echo "$SNAP_JSON" | jq -r '.min_disk_size')
  NEW_SNAPSHOT_REGIONS=$(echo "$SNAP_JSON"  | jq -r '.regions | join(", ")')
  COST_EST=$(echo "$SNAP_JSON" | jq -r '(.size_gigabytes * 0.06 * 100 | round) / 100 | tostring')
fi

CURRENT_OP=""
CREATED_RESOURCE=""

header "Snapshot Created"
info "ID:         $NEW_SNAPSHOT_ID"
info "Name:       $SNAPSHOT_NAME"
info "Compressed: ${NEW_SNAPSHOT_SIZE}GB  (source disk: ${NEW_SNAPSHOT_MIN_DISK}GB)"
info "Regions:    $NEW_SNAPSHOT_REGIONS"
[[ "$DRY_RUN" == false ]] && info "Est. cost:  ~\$${COST_EST}/mo"
echo ""
[[ "$DRY_RUN" == false ]] && info "Restore:    ./do-restore.sh  # select: $SNAPSHOT_NAME"
echo ""

# --- Post-snapshot action ---
POST_OPTIONS=(
  "start|Start it back up"
  "leave|Leave it shut down (billing continues)"
  "delete|Delete/destroy it"
)
SELECTED=$(select_option "What to do with the droplet?" "${POST_OPTIONS[@]}")
POST_ACTION=$(echo "$SELECTED" | cut -d'|' -f1)

case "$POST_ACTION" in
  start)
    echo ""
    info "Starting droplet..."
    CURRENT_OP="power-on droplet $DROPLET_ID ($DROPLET_NAME)"

    if [[ "$DRY_RUN" == true ]]; then
      info "[DRY-RUN] doctl compute droplet-action power-on $DROPLET_ID --wait"
    else
      doctl_cmd compute droplet-action power-on "$DROPLET_ID" \
        --wait --output json > /dev/null
      LIVE_IP=$(doctl_cmd compute droplet get "$DROPLET_ID" --output json | \
        jq -r 'first(.[].networks.v4[] | select(.type == "public") | .ip_address)')
      CONNECT_IP="${DROPLET_RESERVED_IP:-$LIVE_IP}"
      ok "Droplet is active."
      info "Connect: ssh root@$CONNECT_IP"
    fi
    CURRENT_OP=""
    ;;

  leave)
    echo ""
    info "Droplet left shut down."
    warn "Billing continues while the droplet exists."
    ;;

  delete)
    echo ""
    if [[ -n "$DROPLET_RESERVED_IP" ]]; then
      warn "Reserved IP $DROPLET_RESERVED_IP will be unassigned but NOT deleted."
      warn "Reserved IPs continue to accrue charges (~\$5/mo) until deleted."
    fi
    echo ""
    read -rp "  Type the droplet name '$DROPLET_NAME' to confirm deletion: " DELETE_CONFIRM

    if [[ "$DELETE_CONFIRM" == "$DROPLET_NAME" ]]; then
      CURRENT_OP="delete droplet $DROPLET_ID ($DROPLET_NAME)"

      if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] doctl compute droplet delete $DROPLET_ID --force"
      else
        doctl_cmd compute droplet delete "$DROPLET_ID" --force
        ok "Droplet '$DROPLET_NAME' deleted."
        echo ""
        info "Snapshot preserved:  $SNAPSHOT_NAME"
        info "Snapshot ID:         $NEW_SNAPSHOT_ID"
        info "Compressed size:     ${NEW_SNAPSHOT_SIZE}GB"
        info "Source disk:         ${NEW_SNAPSHOT_MIN_DISK}GB"
        info "Storage cost:        ~\$${COST_EST}/mo"
        echo ""
        info "Restore command:     ./do-restore.sh"
      fi
      CURRENT_OP=""
    else
      info "Deletion cancelled. Droplet left shut down."
    fi
    ;;
esac

# --- JSON output ---
if [[ "$JSON_OUT" == true ]]; then
  jq -n \
    --arg  droplet_id      "$DROPLET_ID" \
    --arg  droplet_name    "$DROPLET_NAME" \
    --arg  snapshot_id     "$NEW_SNAPSHOT_ID" \
    --arg  snapshot_name   "$SNAPSHOT_NAME" \
    --arg  snapshot_size   "$NEW_SNAPSHOT_SIZE" \
    --arg  min_disk        "$NEW_SNAPSHOT_MIN_DISK" \
    --arg  regions         "$NEW_SNAPSHOT_REGIONS" \
    --arg  post_action     "$POST_ACTION" \
    --arg  reserved_ip     "$DROPLET_RESERVED_IP" \
    '{
      droplet_id:    $droplet_id,
      droplet_name:  $droplet_name,
      snapshot_id:   $snapshot_id,
      snapshot_name: $snapshot_name,
      snapshot_size_gb: ($snapshot_size | tonumber? // $snapshot_size),
      min_disk_gb:   ($min_disk | tonumber? // $min_disk),
      regions:       ($regions | split(", ")),
      post_action:   $post_action,
      reserved_ip:   $reserved_ip
    }'
fi

echo ""
ok "Done."

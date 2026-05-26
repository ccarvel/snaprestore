#!/usr/bin/env bash
set -eo pipefail

#-----------------------------------------
# CONFIGURATION
#-----------------------------------------
DROPLET_ID=""       # Droplet ID, or leave blank for interactive selection
SNAPSHOT_NAME=""    # Optional: defaults to {droplet-name}-snapshot-{YYYYMMDD-HHMM}
OP_ITEM=""          # Optional: 1Password path, e.g. op://Private/DigitalOcean/token
DOCTL_CONTEXT="snaprestore"    # doctl auth context name (doctl auth list to see yours)
#-----------------------------------------

# ── flag parsing ──────────────────────────────────────────────────────────────

ORIGINAL_ARGS=("$@")
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

# ── logging ───────────────────────────────────────────────────────────────────

_TEE_PID=""
if [[ -n "$LOG_FILE" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  _TEE_PID=$!
fi

# ── bootstrap + UI layer ──────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bootstrap_sh.sh
source "${SCRIPT_DIR}/lib/bootstrap_sh.sh"
bootstrap_ui "$0" "${ORIGINAL_ARGS[@]}"
# shellcheck source=lib/ui_sh.sh
source "${SCRIPT_DIR}/lib/ui_sh.sh"

# ── cleanup trap ──────────────────────────────────────────────────────────────

CURRENT_OP=""
CREATED_RESOURCE=""

cleanup() {
  local code=$?
  ui_spinner_stop  # kills spinner → closes its copy of the pipe write-end
  if [[ $code -ne 0 && -n "$CURRENT_OP" ]]; then
    echo "" >&2
    ui_warn "Interrupted during: $CURRENT_OP"
    [[ -n "$CREATED_RESOURCE" ]] && ui_warn "Resource may be in unknown state: $CREATED_RESOURCE"
    ui_warn "Check console: https://cloud.digitalocean.com/droplets"
  fi
  if [[ -n "$_TEE_PID" ]]; then
    exec 1>&- 2>&-
    wait "$_TEE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── doctl setup ───────────────────────────────────────────────────────────────

check_doctl() {
  if ! command -v doctl &>/dev/null; then
    ui_err "doctl is required but not installed."
    ui_err "  Install:  brew install doctl"
    ui_err "  Auth:     doctl auth init --context snaprestore"
    exit 1
  fi
}

doctl_cmd() {
  if [[ -n "$DOCTL_CONTEXT" ]]; then
    doctl --context "$DOCTL_CONTEXT" "$@"
  else
    doctl "$@"
  fi
}

# ── token loading ─────────────────────────────────────────────────────────────

load_token() {
  local token=""
  if [[ -n "$OP_ITEM" ]]; then
    if command -v op &>/dev/null; then
      token=$(op read "$OP_ITEM" 2>/dev/null) || ui_warn "op read failed for '$OP_ITEM' — falling back"
    else
      ui_warn "'op' CLI not found — falling back to env var"
    fi
  fi
  # When a named doctl context is configured and no OP_ITEM override is set,
  # unset any ambient env-var token (e.g. injected by `op run`) so doctl uses
  # the context's own stored credential instead of the injected one.
  if [[ -n "$DOCTL_CONTEXT" && -z "$token" ]]; then
    unset DIGITALOCEAN_ACCESS_TOKEN
    return 0
  fi
  [[ -z "$token" && -n "$DIGITALOCEAN_ACCESS_TOKEN" ]] && token="$DIGITALOCEAN_ACCESS_TOKEN"
  [[ -z "$token" && -n "$DO_API_TOKEN" ]]              && token="$DO_API_TOKEN"
  if [[ -z "$token" ]]; then
    token=$(ui_input_secret "DigitalOcean API Token")
    [[ -z "$token" ]] && { ui_err "Token required."; exit 1; }
  fi
  [[ -n "$token" ]] && export DIGITALOCEAN_ACCESS_TOKEN="$token"
}

check_doctl
load_token

# ── banner ────────────────────────────────────────────────────────────────────

ui_banner "DO Snapshot Tool"

# ── list|get dispatch ─────────────────────────────────────────────────────────

DROPLET_ID_LOWER=$(echo "$DROPLET_ID" | tr '[:upper:]' '[:lower:]')
case "$DROPLET_ID_LOWER" in
  list|get)
    doctl_cmd compute droplet list \
      --format "ID,Name,Status,Size,Region,Disk,Memory,VCPUs"
    exit 0 ;;
esac

# ── fetch + select droplet ────────────────────────────────────────────────────

ui_info "Fetching droplets…"
DROPLETS_JSON=$(doctl_cmd compute droplet list --output json)

if [[ -z "$DROPLET_ID" ]]; then
  mapfile -t DROPLET_OPTIONS < <(
    echo "$DROPLETS_JSON" | jq -r \
      '.[] | "\(.id)|\(.name)|\(.status)|\(.size_slug)|\(.region.slug)|\(.disk)GB"'
  )
  [[ ${#DROPLET_OPTIONS[@]} -eq 0 ]] && { ui_err "No droplets found."; exit 1; }
  SELECTED=$(ui_choose "Select droplet to snapshot:" "${DROPLET_OPTIONS[@]}")
  [[ -z "$SELECTED" ]] && { ui_err "No selection made."; exit 1; }
  DROPLET_ID=$(echo "$SELECTED" | cut -d'|' -f1)
fi

# ── droplet details (single jq pass) ─────────────────────────────────────────

DROPLET_JSON=$(echo "$DROPLETS_JSON" | jq -r --argjson id "$DROPLET_ID" '.[] | select(.id == $id)')
[[ -z "$DROPLET_JSON" ]] && { ui_err "Droplet $DROPLET_ID not found."; exit 1; }

read -r DROPLET_NAME DROPLET_STATUS DROPLET_SIZE DROPLET_REGION \
       DROPLET_DISK DROPLET_VCPUS DROPLET_MEMORY DROPLET_IP <<EOF
$(echo "$DROPLET_JSON" | jq -r '[
  .name, .status, .size_slug, .region.slug,
  (.disk | tostring), (.vcpus | tostring), (.memory | tostring),
  (first(.networks.v4[] | select(.type == "public") | .ip_address) // "none")
] | @tsv')
EOF

ui_info "Checking for reserved IP…"
RESERVED_IPS_JSON=$(doctl_cmd compute reserved-ip list --output json)
DROPLET_RESERVED_IP=$(echo "$RESERVED_IPS_JSON" | jq -r \
  --argjson id "$DROPLET_ID" '.[] | select(.droplet.id == $id) | .ip')

ui_panel "Droplet Details" \
  "ID"          "$DROPLET_ID" \
  "Name"        "$DROPLET_NAME" \
  "Status"      "$DROPLET_STATUS" \
  "Region"      "$DROPLET_REGION" \
  "Size"        "$DROPLET_SIZE" \
  "vCPUs"       "$DROPLET_VCPUS" \
  "Memory"      "${DROPLET_MEMORY} MB" \
  "Disk"        "${DROPLET_DISK} GB" \
  "Public IP"   "$DROPLET_IP" \
  "Reserved IP" "${DROPLET_RESERVED_IP:-(none)}"

# ── snapshot name ─────────────────────────────────────────────────────────────

if [[ -z "$SNAPSHOT_NAME" ]]; then
  DEFAULT_SNAPSHOT_NAME="${DROPLET_NAME}-snapshot-$(date +%Y%m%d-%H%M)"
  SNAPSHOT_NAME=$(ui_input "Snapshot name" "$DEFAULT_SNAPSHOT_NAME")
fi

ui_info "Snapshot will be named: $SNAPSHOT_NAME"
echo ""

ui_confirm "Proceed with snapshot?" || { ui_info "Aborted."; exit 0; }

# ── shutdown ──────────────────────────────────────────────────────────────────

SKIP_SHUTDOWN=false
if [[ "$DROPLET_STATUS" == "active" ]]; then
  echo ""
  ui_confirm "Shut down droplet before snapshotting? (recommended for consistency)" "Y" || SKIP_SHUTDOWN=true
  if [[ "$SKIP_SHUTDOWN" == true ]]; then
    ui_warn "Snapshotting a running droplet — result may not be crash-consistent."
  fi
fi

if [[ "$DROPLET_STATUS" == "active" && "$SKIP_SHUTDOWN" == false ]]; then
  echo ""
  CURRENT_OP="shutdown droplet $DROPLET_ID ($DROPLET_NAME)"

  if [[ "$DRY_RUN" == true ]]; then
    ui_info "[DRY-RUN] doctl compute droplet-action shutdown $DROPLET_ID --wait"
  else
    local_tmpfile=$(mktemp)
    SHUTDOWN_START=$(date +%s)
    ui_spinner_start "Shutting down droplet"

    doctl_cmd compute droplet-action shutdown "$DROPLET_ID" \
      --wait --output json > "$local_tmpfile" 2>&1 &
    DOCTL_PID=$!

    if ! wait "$DOCTL_PID"; then
      ui_spinner_stop
      ui_warn "Graceful shutdown failed — attempting power-off…"
      CURRENT_OP="power-off droplet $DROPLET_ID ($DROPLET_NAME)"
      rm -f "$local_tmpfile"
      local_tmpfile=$(mktemp)

      ui_spinner_start "Powering off droplet"
      doctl_cmd compute droplet-action power-off "$DROPLET_ID" \
        --wait --output json > "$local_tmpfile" 2>&1 &
      DOCTL_PID=$!

      if ! wait "$DOCTL_PID"; then
        ui_spinner_stop
        ui_err "Power-off failed. Check droplet in console."
        head -5 "$local_tmpfile" >&2
        rm -f "$local_tmpfile"
        exit 1
      fi
      ui_spinner_stop "Powered off."
    else
      ui_spinner_stop "Droplet stopped."
    fi

    record_duration "shutdown" "$(( $(date +%s) - SHUTDOWN_START ))"
    rm -f "$local_tmpfile"
  fi
  CURRENT_OP=""
elif [[ "$DROPLET_STATUS" != "active" ]]; then
  ui_info "Droplet is already off."
fi

# ── create snapshot ───────────────────────────────────────────────────────────

echo ""
CURRENT_OP="snapshot droplet $DROPLET_ID ($DROPLET_NAME)"
CREATED_RESOURCE="snapshot of $DROPLET_NAME"

if [[ "$DRY_RUN" == true ]]; then
  ui_info "[DRY-RUN] doctl compute droplet-action snapshot $DROPLET_ID --snapshot-name \"$SNAPSHOT_NAME\" --wait"
  NEW_SNAPSHOT_ID="(dry-run)"
  NEW_SNAPSHOT_SIZE="0"
  NEW_SNAPSHOT_MIN_DISK="$DROPLET_DISK"
  NEW_SNAPSHOT_REGIONS="$DROPLET_REGION"
  COST_EST="0.00"
else
  local_tmpfile=$(mktemp)
  SNAP_START=$(date +%s)
  SNAP_ETA=$(get_eta "snapshot" "$DROPLET_DISK") || true

  ui_spinner_start "Creating snapshot '$SNAPSHOT_NAME'" "$SNAP_ETA"

  doctl_cmd compute droplet-action snapshot "$DROPLET_ID" \
    --snapshot-name "$SNAPSHOT_NAME" \
    --wait --output json > "$local_tmpfile" 2>&1 &
  DOCTL_PID=$!

  if ! wait "$DOCTL_PID"; then
    ui_spinner_stop
    ui_err "Snapshot failed:"
    head -5 "$local_tmpfile" >&2
    rm -f "$local_tmpfile"
    exit 1
  fi

  SNAP_DURATION=$(( $(date +%s) - SNAP_START ))
  ui_spinner_stop "Snapshot complete."
  record_duration "snapshot" "$SNAP_DURATION" "$DROPLET_DISK"
  rm -f "$local_tmpfile"

  ui_info "Fetching snapshot details…"
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

ui_panel "Snapshot Created" \
  "ID"          "$NEW_SNAPSHOT_ID" \
  "Name"        "$SNAPSHOT_NAME" \
  "Compressed"  "${NEW_SNAPSHOT_SIZE} GB  (source disk: ${NEW_SNAPSHOT_MIN_DISK} GB)" \
  "Regions"     "$NEW_SNAPSHOT_REGIONS" \
  "Est. cost"   "~\$${COST_EST}/mo" \
  "Restore"     "./do-restore.sh"

# ── post-snapshot action ──────────────────────────────────────────────────────

POST_OPTIONS=(
  "start|Start it back up"
  "leave|Leave it shut down (billing continues)"
  "delete|Delete/destroy it"
)
SELECTED=$(ui_choose "What to do with the droplet?" "${POST_OPTIONS[@]}")
POST_ACTION=$(echo "$SELECTED" | cut -d'|' -f1)

case "$POST_ACTION" in
  start)
    echo ""
    CURRENT_OP="power-on droplet $DROPLET_ID ($DROPLET_NAME)"

    if [[ "$DRY_RUN" == true ]]; then
      ui_info "[DRY-RUN] doctl compute droplet-action power-on $DROPLET_ID --wait"
    else
      local_tmpfile=$(mktemp)
      ui_spinner_start "Starting droplet"

      doctl_cmd compute droplet-action power-on "$DROPLET_ID" \
        --wait --output json > "$local_tmpfile" 2>&1 &
      DOCTL_PID=$!

      if ! wait "$DOCTL_PID"; then
        ui_spinner_stop
        ui_err "Power-on failed."
        rm -f "$local_tmpfile"
        exit 1
      fi
      ui_spinner_stop "Droplet is active."
      rm -f "$local_tmpfile"

      LIVE_IP=$(doctl_cmd compute droplet get "$DROPLET_ID" --output json | \
        jq -r 'first(.[].networks.v4[] | select(.type == "public") | .ip_address)')
      CONNECT_IP="${DROPLET_RESERVED_IP:-$LIVE_IP}"
      ui_info "Connect: ssh root@$CONNECT_IP"
    fi
    CURRENT_OP=""
    ;;

  leave)
    echo ""
    ui_info "Droplet left shut down."
    ui_warn "Billing continues while the droplet exists."
    ;;

  delete)
    echo ""
    if [[ -n "$DROPLET_RESERVED_IP" ]]; then
      ui_warn "Reserved IP $DROPLET_RESERVED_IP will be unassigned but NOT deleted."
      ui_warn "Reserved IPs accrue charges (~\$5/mo) until explicitly deleted."
    fi
    echo ""
    DEL_CONFIRM=$(ui_input "Type the droplet name '$DROPLET_NAME' to confirm deletion" "")

    if [[ "$DEL_CONFIRM" == "$DROPLET_NAME" ]]; then
      CURRENT_OP="delete droplet $DROPLET_ID ($DROPLET_NAME)"

      if [[ "$DRY_RUN" == true ]]; then
        ui_info "[DRY-RUN] doctl compute droplet delete $DROPLET_ID --force"
      else
        doctl_cmd compute droplet delete "$DROPLET_ID" --force
        ui_panel "Droplet Deleted" \
          "Snapshot"     "$SNAPSHOT_NAME" \
          "Snapshot ID"  "$NEW_SNAPSHOT_ID" \
          "Compressed"   "${NEW_SNAPSHOT_SIZE} GB" \
          "Source disk"  "${NEW_SNAPSHOT_MIN_DISK} GB" \
          "Storage cost" "~\$${COST_EST}/mo" \
          "Restore"      "./do-restore.sh"
      fi
      CURRENT_OP=""
    else
      ui_info "Deletion cancelled. Droplet left shut down."
    fi
    ;;
esac

# ── JSON output ───────────────────────────────────────────────────────────────

if [[ "$JSON_OUT" == true ]]; then
  jq -n \
    --arg  droplet_id    "$DROPLET_ID" \
    --arg  droplet_name  "$DROPLET_NAME" \
    --arg  snapshot_id   "$NEW_SNAPSHOT_ID" \
    --arg  snapshot_name "$SNAPSHOT_NAME" \
    --arg  snapshot_size "$NEW_SNAPSHOT_SIZE" \
    --arg  min_disk      "$NEW_SNAPSHOT_MIN_DISK" \
    --arg  regions       "$NEW_SNAPSHOT_REGIONS" \
    --arg  post_action   "$POST_ACTION" \
    --arg  reserved_ip   "$DROPLET_RESERVED_IP" \
    '{
      droplet_id:       $droplet_id,
      droplet_name:     $droplet_name,
      snapshot_id:      $snapshot_id,
      snapshot_name:    $snapshot_name,
      snapshot_size_gb: ($snapshot_size | tonumber? // $snapshot_size),
      min_disk_gb:      ($min_disk      | tonumber? // $min_disk),
      regions:          ($regions | split(", ")),
      post_action:      $post_action,
      reserved_ip:      $reserved_ip
    }'
fi

echo ""
ui_ok "Done."

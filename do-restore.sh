#!/usr/bin/env bash
set -eo pipefail

#-----------------------------------------
# CONFIGURATION
#-----------------------------------------
SNAPSHOT_ID=""      # Snapshot ID, or leave blank for interactive selection
SSH_KEY_ID=""       # SSH key ID (comma-separated for multiple), or blank to prompt
SIZE_SLUG=""        # Droplet size slug, or blank to prompt
DROPLET_NAME=""     # Optional: defaults to restored-{snapshot-name}-{YYYYMMDD}
RESERVED_IP=""      # Reserved IP to assign, or blank to prompt
OP_ITEM=""          # Optional: 1Password path, e.g. op://Private/DigitalOcean/token
DOCTL_CONTEXT="default"    # doctl auth context name (doctl auth list to see yours)
#-----------------------------------------

# ── flag parsing ──────────────────────────────────────────────────────────────

ORIGINAL_ARGS=("$@")
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
NEW_DROPLET_ID=""

cleanup() {
  local code=$?
  ui_spinner_stop
  if [[ $code -ne 0 && -n "$CURRENT_OP" ]]; then
    echo "" >&2
    ui_warn "Interrupted during: $CURRENT_OP"
    [[ -n "$NEW_DROPLET_ID" ]] && ui_warn "Partially provisioned droplet ID: $NEW_DROPLET_ID — check console"
    ui_warn "Check console: https://cloud.digitalocean.com/droplets"
  fi
  # wait for tee to drain before the process exits
  [[ -n "$_TEE_PID" ]] && wait "$_TEE_PID" 2>/dev/null || true
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
  [[ -z "$token" && -n "$DIGITALOCEAN_ACCESS_TOKEN" ]] && token="$DIGITALOCEAN_ACCESS_TOKEN"
  [[ -z "$token" && -n "$DO_API_TOKEN" ]]              && token="$DO_API_TOKEN"
  if [[ -z "$token" && -z "$DOCTL_CONTEXT" ]]; then
    token=$(ui_input_secret "DigitalOcean API Token")
    [[ -z "$token" ]] && { ui_err "Token required."; exit 1; }
  fi
  [[ -n "$token" ]] && export DIGITALOCEAN_ACCESS_TOKEN="$token"
}

check_doctl
load_token

# ── banner ────────────────────────────────────────────────────────────────────

ui_banner "DO Restore Tool"

# ── list|get dispatch ─────────────────────────────────────────────────────────

SNAPSHOT_ID_LOWER=$(echo "$SNAPSHOT_ID"  | tr '[:upper:]' '[:lower:]')
SSH_KEY_ID_LOWER=$(echo "$SSH_KEY_ID"    | tr '[:upper:]' '[:lower:]')
SIZE_SLUG_LOWER=$(echo "$SIZE_SLUG"      | tr '[:upper:]' '[:lower:]')
RESERVED_IP_LOWER=$(echo "$RESERVED_IP"  | tr '[:upper:]' '[:lower:]')

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
    [[ -z "$SNAPSHOT_ID" ]] && { ui_err "Set SNAPSHOT_ID first to list compatible sizes."; exit 1; }
    SNAP_INFO=$(doctl_cmd compute snapshot list --resource droplet --output json | \
      jq -r --arg id "$SNAPSHOT_ID" '.[] | select(.id == $id)')
    MIN_DISK=$(echo "$SNAP_INFO" | jq -r '.min_disk_size')
    REGION=$(echo "$SNAP_INFO"   | jq -r '.regions[0]')
    ui_info "Compatible sizes (min disk: ${MIN_DISK} GB, region: $REGION)…"
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

# ── fetch + select snapshot (with age) ───────────────────────────────────────

ui_info "Fetching snapshots…"
SNAPSHOTS_JSON=$(doctl_cmd compute snapshot list --resource droplet --output json)

if [[ -z "$SNAPSHOT_ID" ]]; then
  mapfile -t SNAPSHOT_OPTIONS < <(
    echo "$SNAPSHOTS_JSON" | jq -r \
      '.[] |
       (now - (.created_at | fromdateiso8601) | . / 86400 | floor | tostring) as $age |
       "\(.id)|\(.name)|\(.size_gigabytes)GB|min:\(.min_disk_size)GB|\(.regions | join(","))|\($age)d ago"'
  )
  [[ ${#SNAPSHOT_OPTIONS[@]} -eq 0 ]] && { ui_err "No snapshots found."; exit 1; }
  SELECTED=$(ui_choose "Select snapshot:" "${SNAPSHOT_OPTIONS[@]}")
  [[ -z "$SELECTED" ]] && { ui_err "No selection made."; exit 1; }
  SNAPSHOT_ID=$(echo "$SELECTED" | cut -d'|' -f1)
fi

# ── snapshot details (single jq pass) ────────────────────────────────────────

SNAPSHOT_JSON=$(echo "$SNAPSHOTS_JSON" | jq --arg id "$SNAPSHOT_ID" '.[] | select(.id == $id)')
[[ -z "$SNAPSHOT_JSON" ]] && { ui_err "Snapshot $SNAPSHOT_ID not found."; exit 1; }

SNAPSHOT_NAME=$(echo "$SNAPSHOT_JSON"        | jq -r '.name')
SNAPSHOT_SIZE=$(echo "$SNAPSHOT_JSON"        | jq -r '.size_gigabytes')
SNAPSHOT_MIN_DISK=$(echo "$SNAPSHOT_JSON"    | jq -r '.min_disk_size')
SNAPSHOT_REGION=$(echo "$SNAPSHOT_JSON"      | jq -r '.regions[0]')
SNAPSHOT_REGIONS_ALL=$(echo "$SNAPSHOT_JSON" | jq -r '.regions | join(", ")')
SNAPSHOT_CREATED=$(echo "$SNAPSHOT_JSON"     | jq -r '.created_at')
SNAPSHOT_AGE=$(echo "$SNAPSHOT_JSON" | jq -r \
  '(now - (.created_at | fromdateiso8601) | . / 86400 | floor | tostring) + " days"')

ui_panel "Snapshot Details" \
  "Name"        "$SNAPSHOT_NAME" \
  "ID"          "$SNAPSHOT_ID" \
  "Compressed"  "${SNAPSHOT_SIZE} GB  (source disk: ${SNAPSHOT_MIN_DISK} GB)" \
  "Created"     "$SNAPSHOT_CREATED  ($SNAPSHOT_AGE ago)" \
  "Regions"     "$SNAPSHOT_REGIONS_ALL"

# ── size selection ────────────────────────────────────────────────────────────

ui_info "Fetching compatible droplet sizes…"
SIZES_JSON=$(doctl_cmd compute size list --output json)

if [[ -z "$SIZE_SLUG" ]]; then
  mapfile -t SIZE_OPTIONS < <(
    echo "$SIZES_JSON" | jq -r \
      --arg region "$SNAPSHOT_REGION" \
      --argjson min_disk "$SNAPSHOT_MIN_DISK" \
      '.[] | select(.available==true) | select(any(.regions[]?; . == $region)) | select(.disk >= $min_disk) |
       "\(.slug)|\(.vcpus)vCPU|\(.memory)MB|\(.disk)GB disk|$\(.price_monthly)/mo"' | \
      sort -t'$' -k2 -n
  )
  [[ ${#SIZE_OPTIONS[@]} -eq 0 ]] && {
    ui_err "No compatible sizes found (need >= ${SNAPSHOT_MIN_DISK} GB disk in $SNAPSHOT_REGION)."
    exit 1
  }
  SELECTED=$(ui_choose "Select droplet size:" "${SIZE_OPTIONS[@]}")
  [[ -z "$SELECTED" ]] && { ui_err "No selection made."; exit 1; }
  SIZE_SLUG=$(echo "$SELECTED" | cut -d'|' -f1)
fi
ui_info "Size: $SIZE_SLUG"

# ── SSH key ───────────────────────────────────────────────────────────────────

ui_info "Fetching SSH keys…"
KEYS_JSON=$(doctl_cmd compute ssh-key list --output json)

if [[ -z "$SSH_KEY_ID" ]]; then
  ui_confirm "Attach an SSH key?" "Y" && {
    mapfile -t KEY_OPTIONS < <(
      echo "$KEYS_JSON" | jq -r '.[] | "\(.id)|\(.name)"'
    )
    [[ ${#KEY_OPTIONS[@]} -eq 0 ]] && { ui_err "No SSH keys found."; exit 1; }
    SELECTED=$(ui_choose "Select SSH key:" "${KEY_OPTIONS[@]}")
    [[ -z "$SELECTED" ]] && { ui_err "No selection made."; exit 1; }
    SSH_KEY_ID=$(echo "$SELECTED" | cut -d'|' -f1)
    ui_info "SSH key: $SSH_KEY_ID"
  } || true
fi

# ── reserved IP ──────────────────────────────────────────────────────────────

if [[ -z "$RESERVED_IP" ]]; then
  ui_confirm "Assign a reserved IP?" "Y" && {
    RESERVED_IPS_JSON=$(doctl_cmd compute reserved-ip list --output json)
    mapfile -t IP_OPTIONS < <(
      echo "$RESERVED_IPS_JSON" | jq -r \
        --arg region "$SNAPSHOT_REGION" \
        '.[] | select(.region.slug == $region) | select(.droplet == null) |
         "\(.ip)|unassigned|\(.region.slug)"'
    )
    if [[ ${#IP_OPTIONS[@]} -eq 0 ]]; then
      ui_warn "No unassigned reserved IPs found in $SNAPSHOT_REGION."
    else
      SELECTED=$(ui_choose "Select reserved IP:" "${IP_OPTIONS[@]}")
      RESERVED_IP=$(echo "$SELECTED" | cut -d'|' -f1)
      ui_info "Reserved IP: $RESERVED_IP"
    fi
  } || true

elif [[ -n "$RESERVED_IP" ]]; then
  # Validate region + current assignment for hardcoded IPs
  RESERVED_IPS_JSON=$(doctl_cmd compute reserved-ip list --output json)
  HARDCODED_REGION=$(echo "$RESERVED_IPS_JSON" | jq -r \
    --arg ip "$RESERVED_IP" '.[] | select(.ip == $ip) | .region.slug')
  HARDCODED_CURRENT=$(echo "$RESERVED_IPS_JSON" | jq -r \
    --arg ip "$RESERVED_IP" '.[] | select(.ip == $ip) | (.droplet.name // "unassigned")')

  if [[ -n "$HARDCODED_REGION" && "$HARDCODED_REGION" != "$SNAPSHOT_REGION" ]]; then
    ui_err "Reserved IP $RESERVED_IP is in $HARDCODED_REGION but snapshot is in $SNAPSHOT_REGION."
    ui_err "Set RESERVED_IP to an IP in $SNAPSHOT_REGION or leave blank."
    exit 1
  fi
  if [[ "$HARDCODED_CURRENT" != "unassigned" ]]; then
    ui_warn "Reserved IP $RESERVED_IP is currently assigned to: $HARDCODED_CURRENT"
    ui_confirm "Reassign away from '$HARDCODED_CURRENT'?" "N" || { ui_info "Aborted."; exit 0; }
  fi
fi

# ── droplet name ──────────────────────────────────────────────────────────────

if [[ -z "$DROPLET_NAME" ]]; then
  DEFAULT_NAME="restored-$(echo "$SNAPSHOT_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')-$(date +%Y%m%d)"
  DROPLET_NAME=$(ui_input "Droplet name" "$DEFAULT_NAME")
fi

# ── confirm summary ───────────────────────────────────────────────────────────

ui_panel "Creating Droplet" \
  "Name"        "$DROPLET_NAME" \
  "Size"        "$SIZE_SLUG" \
  "Region"      "$SNAPSHOT_REGION" \
  "Image"       "$SNAPSHOT_ID ($SNAPSHOT_NAME)" \
  "SSH Key"     "${SSH_KEY_ID:-(none)}" \
  "Reserved IP" "${RESERVED_IP:-(none)}" \
  "Tags"        "${TAGS:-(none)}"

ui_confirm "Proceed?" || { echo "[restore] user aborted at Proceed prompt" >&2; ui_info "Aborted."; exit 0; }
echo "[restore] user confirmed — starting droplet creation"

# ── build doctl create args ───────────────────────────────────────────────────

CREATE_ARGS=(
  compute droplet create "$DROPLET_NAME"
  --image  "$SNAPSHOT_ID"
  --size   "$SIZE_SLUG"
  --region "$SNAPSHOT_REGION"
  --wait
)
[[ -n "$SSH_KEY_ID" ]] && CREATE_ARGS+=(--ssh-keys  "$SSH_KEY_ID")
[[ -n "$TAGS"       ]] && CREATE_ARGS+=(--tag-names "$TAGS")

# ── create droplet ────────────────────────────────────────────────────────────

CURRENT_OP="create droplet '$DROPLET_NAME' from snapshot $SNAPSHOT_ID"
echo ""

if [[ "$DRY_RUN" == true ]]; then
  ui_info "[DRY-RUN] doctl ${CREATE_ARGS[*]}"
  NEW_DROPLET_ID="(dry-run)"
  NEW_DROPLET_IP="(dry-run)"
else
  local_tmpfile=$(mktemp)
  CREATE_START=$(date +%s)
  CREATE_ETA=$(get_eta "restore")

  ui_spinner_start "Creating droplet from snapshot" "$CREATE_ETA"

  doctl_cmd "${CREATE_ARGS[@]}" --output json > "$local_tmpfile" 2>&1 &
  DOCTL_PID=$!

  if ! wait "$DOCTL_PID"; then
    ui_spinner_stop
    ui_err "Droplet creation failed:"
    head -5 "$local_tmpfile" >&2
    rm -f "$local_tmpfile"
    exit 1
  fi

  CREATE_DURATION=$(( $(date +%s) - CREATE_START ))
  ui_spinner_stop "Droplet active."
  record_duration "restore" "$CREATE_DURATION"

  CREATE_OUTPUT=$(<"$local_tmpfile")
  rm -f "$local_tmpfile"

  NEW_DROPLET_ID=$(echo "$CREATE_OUTPUT" | \
    jq -r 'if type=="array" then .[0].id else .id end')
  NEW_DROPLET_IP=$(echo "$CREATE_OUTPUT" | jq -r '
    (if type=="array" then .[0] else . end) |
    first(.networks.v4[] | select(.type=="public") | .ip_address)')
fi
CURRENT_OP=""

# ── assign reserved IP ────────────────────────────────────────────────────────

CONNECT_IP="$NEW_DROPLET_IP"

if [[ -n "$RESERVED_IP" ]]; then
  echo ""
  CURRENT_OP="assign reserved IP $RESERVED_IP to droplet $NEW_DROPLET_ID"

  if [[ "$DRY_RUN" == true ]]; then
    ui_info "[DRY-RUN] doctl compute reserved-ip-action assign $RESERVED_IP $NEW_DROPLET_ID"
    CONNECT_IP="$RESERVED_IP"
  else
    ui_spinner_start "Assigning reserved IP $RESERVED_IP"

    ASSIGN_OUTPUT=$(doctl_cmd compute reserved-ip-action assign \
      "$RESERVED_IP" "$NEW_DROPLET_ID" --output json)
    ASSIGN_ACTION_ID=$(echo "$ASSIGN_OUTPUT" | jq -r '.action.id // .[0].id')

    ASSIGN_STATUS=""
    for _ in $(seq 1 24); do   # max 2 minutes
      ASSIGN_STATUS=$(doctl_cmd compute action get "$ASSIGN_ACTION_ID" --output json | \
        jq -r 'if type=="array" then .[0].status else .status end')
      [[ "$ASSIGN_STATUS" == "completed" || "$ASSIGN_STATUS" == "errored" ]] && break
      sleep 5
    done

    ui_spinner_stop

    if [[ "$ASSIGN_STATUS" == "completed" ]]; then
      ui_ok "Reserved IP assigned."
      CONNECT_IP="$RESERVED_IP"
    else
      ui_warn "Reserved IP assignment did not complete (status: $ASSIGN_STATUS)."
      ui_warn "Assign manually: doctl compute reserved-ip-action assign $RESERVED_IP $NEW_DROPLET_ID"
    fi
  fi
  CURRENT_OP=""
fi

# ── final summary ─────────────────────────────────────────────────────────────

ui_panel "Done" \
  "Droplet ID"   "$NEW_DROPLET_ID" \
  "Droplet IP"   "$NEW_DROPLET_IP" \
  "Reserved IP"  "${RESERVED_IP:-(none)}" \
  "Tags"         "${TAGS:-(none)}" \
  "Connect"      "ssh root@$CONNECT_IP"

# ── JSON output ───────────────────────────────────────────────────────────────

if [[ "$JSON_OUT" == true ]]; then
  jq -n \
    --arg droplet_id    "$NEW_DROPLET_ID" \
    --arg droplet_name  "$DROPLET_NAME" \
    --arg droplet_ip    "$NEW_DROPLET_IP" \
    --arg reserved_ip   "${RESERVED_IP:-}" \
    --arg connect_ip    "$CONNECT_IP" \
    --arg snapshot_id   "$SNAPSHOT_ID" \
    --arg snapshot_name "$SNAPSHOT_NAME" \
    --arg size          "$SIZE_SLUG" \
    --arg region        "$SNAPSHOT_REGION" \
    --arg tags          "${TAGS:-}" \
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

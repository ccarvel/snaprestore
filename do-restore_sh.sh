#!/bin/bash
set -e

trap 'echo ""; echo "Operation aborted."; exit 1' INT QUIT

#-----------------------------------------
# CONFIGURATION - Set these or use "list" to fetch
#-----------------------------------------
DO_TOKEN=""           # Required: your DigitalOcean API token
SNAPSHOT_ID=""        # Use "list" to see available snapshots
SSH_KEY_ID=""         # Use "list" to see available SSH keys
SIZE_SLUG=""          # Use "list" to see available sizes (requires SNAPSHOT_ID)
DROPLET_NAME=""       # Optional: defaults to restored-{snapshot}-{date}
RESERVED_IP=""        # Use "list" to see available reserved IPs, or set IP to assign
DROPLET_TAGS=""       # Optional: comma-separated list of tags
VPC_UUID=""           # Optional: VPC UUID
USER_DATA_FILE=""     # Optional: Path to cloud-init user-data file
DRY_RUN=0             # Set to 1 to enable dry-run mode
#-----------------------------------------

CACHE_DIR="${HOME}/.config/do-snap-tool"
LOG_DIR="${HOME}/.local/share/do-snap-tool"
LOG_FILE="${LOG_DIR}/action.log"
SIZES_CACHE="${CACHE_DIR}/sizes.json"
REGIONS_CACHE="${CACHE_DIR}/regions.json"

mkdir -p "$CACHE_DIR" "$LOG_DIR"

log_action() {
  local msg="$1"
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $msg" >> "$LOG_FILE"
}

if [[ "$1" == "--dry-run" ]]; then
  DRY_RUN=1
  echo "⚠️ DRY RUN MODE ENABLED. No mutating DO API calls will be executed. ⚠️"
  echo ""
fi

HAS_FZF=$(command -v fzf >/dev/null 2>&1 && echo "yes" || echo "no")

if ! command -v doctl >/dev/null 2>&1; then
  echo "Error: doctl is required but not installed."
  echo "Install with: brew install doctl"
  exit 1
fi

select_option() {
  local prompt="$1"
  shift
  local options=("$@")
  
  if [ "$HAS_FZF" = "yes" ]; then
    local selected
    selected=$(printf '%s\n' "${options[@]}" | fzf --height=15 --prompt="$prompt ")
    if [ -z "$selected" ]; then
      echo "Selection cancelled." >&2
      exit 1
    fi
    echo "$selected"
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
    if ! read -r -p "Enter number: " selection; then
       echo -e "\nSelection cancelled." >&2
       exit 1
    fi
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#options[@]}" ]; then
       echo "Invalid selection." >&2
       exit 1
    fi
    echo "${options[$((selection-1))]}"
  fi
}

if [ -z "$DO_TOKEN" ]; then
  DO_TOKEN="${DO_API_TOKEN:-}"
fi

if [ -z "$DO_TOKEN" ] && command -v op >/dev/null 2>&1; then
  : # DO_TOKEN=$(op read "op://Private/DigitalOcean/credential" 2>/dev/null || echo "")
fi

if [ -z "$DO_TOKEN" ]; then
  if ! read -rs -p "DigitalOcean API Token: " DO_TOKEN; then
    echo -e "\nInput cancelled."
    exit 1
  fi
  echo ""
fi

export DIGITALOCEAN_ACCESS_TOKEN="$DO_TOKEN"

update_cache() {
  local cache_file="$1"
  local cmd="$2"
  # Cache for 24 hours (86400 seconds)
  # using posix compliant stat check for mac/linux
  local mod_time
  if stat -f %m "$cache_file" >/dev/null 2>&1; then
    mod_time=$(stat -f %m "$cache_file")
  elif stat -c %Y "$cache_file" >/dev/null 2>&1; then
    mod_time=$(stat -c %Y "$cache_file")
  else
    mod_time=0
  fi
  
  local now
  now=$(date +%s)
  
  if [ ! -f "$cache_file" ] || [ $((now - mod_time)) -gt 86400 ]; then
    eval "$cmd -o json > \"$cache_file\""
  fi
}

list_snapshots() {
  echo "Fetching snapshots..."
  # Calculate age in jq
  doctl compute snapshot list --resource droplet -o json | jq -r '
    .[] | 
    .created_at as $t |
    (now - ($t | fromdateiso8601)) as $diff |
    if $diff < 86400 then "today"
    elif $diff < 172800 then "1 day ago"
    else "\($diff / 86400 | floor) days ago" end as $age |
    "\(.id)  \(.name)  \(.size_gigabytes)GB  min_disk:\(.min_disk_size)GB  \(.regions[0]) (\($age))"'
}

list_ssh_keys() {
  echo "Fetching SSH keys..."
  doctl compute ssh-key list --format "ID,Name" --no-header | awk '{print $1"  "$2}'
}

list_sizes() {
  SNAPSHOT_ID_CHECK=$(echo "$SNAPSHOT_ID" | tr '[:upper:]' '[:lower:]')
  if [ -z "$SNAPSHOT_ID" ] || [ "$SNAPSHOT_ID_CHECK" = "list" ]; then
    echo "Error: Set SNAPSHOT_ID first to list compatible sizes"
    exit 1
  fi
  
  SNAPSHOT_JSON=$(doctl compute snapshot get "$SNAPSHOT_ID" -o json)
  SNAPSHOT_MIN_DISK=$(echo "$SNAPSHOT_JSON" | jq -r '.[0].min_disk_size')
  SNAPSHOT_REGION=$(echo "$SNAPSHOT_JSON" | jq -r '.[0].regions[0]')
  
  echo "Fetching sizes compatible with snapshot (min disk: ${SNAPSHOT_MIN_DISK}GB, region: $SNAPSHOT_REGION)..."
  update_cache "$SIZES_CACHE" "doctl compute size list"
  jq -r --arg region "$SNAPSHOT_REGION" --argjson min_disk "$SNAPSHOT_MIN_DISK" \
    '.[] | select(.available == true) | select(.regions[] == $region) | select(.disk >= $min_disk) | "\(.slug)  \(.vcpus)vCPU  \(.memory)MB RAM  \(.disk)GB disk  $\(.price_monthly)/mo"' \
    "$SIZES_CACHE" | sort -t'$' -k2 -n
}

list_reserved_ips() {
  echo "Fetching reserved IPs..."
  doctl compute reserved-ip list -o json | jq -r '.[] | "\(.ip)  \(.region.slug)  droplet: \(.droplet.id // "unassigned")"'
}

SNAPSHOT_ID_LOWER=$(echo "$SNAPSHOT_ID" | tr '[:upper:]' '[:lower:]')
SSH_KEY_ID_LOWER=$(echo "$SSH_KEY_ID" | tr '[:upper:]' '[:lower:]')
SIZE_SLUG_LOWER=$(echo "$SIZE_SLUG" | tr '[:upper:]' '[:lower:]')
RESERVED_IP_LOWER=$(echo "$RESERVED_IP" | tr '[:upper:]' '[:lower:]')

case "$SNAPSHOT_ID_LOWER" in list|get) list_snapshots; exit 0 ;; esac
case "$SSH_KEY_ID_LOWER" in list|get) list_ssh_keys; exit 0 ;; esac
case "$SIZE_SLUG_LOWER" in list|get) list_sizes; exit 0 ;; esac
case "$RESERVED_IP_LOWER" in list|get) list_reserved_ips; exit 0 ;; esac

echo "Fetching snapshots..."
SNAPSHOTS_RAW=$(doctl compute snapshot list --resource droplet -o json)

if [ -z "$SNAPSHOT_ID" ]; then
  OIFS="$IFS"
  IFS=$'\n'
  SNAPSHOT_OPTIONS=($(echo "$SNAPSHOTS_RAW" | jq -r '
    .[] | 
    .created_at as $t |
    (now - ($t | fromdateiso8601)) as $diff |
    if $diff < 86400 then "today"
    elif $diff < 172800 then "1d ago"
    else "\($diff / 86400 | floor)d ago" end as $age |
    "\(.id)|\(.name)|\(.size_gigabytes)GB|min:\(.min_disk_size)GB|\(.regions[0])|(\($age))"'))
  IFS="$OIFS"
  
  if [ ${#SNAPSHOT_OPTIONS[@]} -eq 0 ]; then
    echo "No snapshots found."
    exit 1
  fi
  
  SELECTED=$(select_option "Select snapshot:" "${SNAPSHOT_OPTIONS[@]}")
  SNAPSHOT_ID=$(echo "$SELECTED" | cut -d'|' -f1)
fi

SNAPSHOT=$(echo "$SNAPSHOTS_RAW" | jq -r ".[] | select(.id == \"$SNAPSHOT_ID\")")
SNAPSHOT_SIZE=$(echo "$SNAPSHOT" | jq -r '.size_gigabytes')
SNAPSHOT_MIN_DISK=$(echo "$SNAPSHOT" | jq -r '.min_disk_size')
SNAPSHOT_REGION=$(echo "$SNAPSHOT" | jq -r '.regions[0]')
SNAPSHOT_NAME=$(echo "$SNAPSHOT" | jq -r '.name')

echo ""
echo "Selected: $SNAPSHOT_NAME"
echo "Size: ${SNAPSHOT_SIZE}GB (min disk: ${SNAPSHOT_MIN_DISK}GB)"
echo "Region: $SNAPSHOT_REGION"

echo ""
echo "Fetching droplet sizes..."
update_cache "$SIZES_CACHE" "doctl compute size list"

if [ -z "$SIZE_SLUG" ]; then
  OIFS="$IFS"
  IFS=$'\n'
  SIZE_OPTIONS=($(jq -r --arg region "$SNAPSHOT_REGION" --argjson min_disk "$SNAPSHOT_MIN_DISK" \
    '.[] | select(.available == true) | select(.regions[] == $region) | select(.disk >= $min_disk) | "\(.slug)|\(.vcpus)vCPU|\(.memory)MB|\(.disk)GB|$\(.price_monthly)/mo"' \
    "$SIZES_CACHE" | sort -t'$' -k2 -n))
  IFS="$OIFS"
  
  if [ ${#SIZE_OPTIONS[@]} -eq 0 ]; then
    echo "No compatible droplet sizes found (need >= ${SNAPSHOT_MIN_DISK}GB disk in $SNAPSHOT_REGION)."
    exit 1
  fi
  
  SELECTED=$(select_option "Select droplet size:" "${SIZE_OPTIONS[@]}")
  SIZE_SLUG=$(echo "$SELECTED" | cut -d'|' -f1)
fi

echo "Selected size: $SIZE_SLUG"

echo ""
echo "Fetching SSH keys..."
KEYS=$(doctl compute ssh-key list -o json)

if [ -z "$SSH_KEY_ID" ]; then
  echo ""
  if ! read -r -p "Does this droplet require an SSH key? (y/n): " NEED_SSH_KEY; then
    echo -e "\nCancelled."
    exit 1
  fi
  
  if [[ "$NEED_SSH_KEY" =~ ^[Yy] ]]; then
    OIFS="$IFS"
    IFS=$'\n'
    KEY_OPTIONS=($(echo "$KEYS" | jq -r '.[] | "\(.id)|\(.name)"'))
    IFS="$OIFS"
    
    if [ ${#KEY_OPTIONS[@]} -eq 0 ]; then
      echo "No SSH keys found in your account."
      exit 1
    fi
    
    SELECTED=$(select_option "Select SSH key:" "${KEY_OPTIONS[@]}")
    SSH_KEY_ID=$(echo "$SELECTED" | cut -d'|' -f1)
  fi
fi

if [ -n "$SSH_KEY_ID" ]; then
  echo "Selected SSH key: $SSH_KEY_ID"
else
  echo "No SSH key selected."
fi

if [ -z "$RESERVED_IP" ]; then
  echo ""
  if ! read -r -p "Assign a reserved IP? (y/n): " NEED_RESERVED_IP; then
    echo -e "\nCancelled."
    exit 1
  fi
  
  if [[ "$NEED_RESERVED_IP" =~ ^[Yy] ]]; then
    echo "Fetching reserved IPs..."
    RESERVED_IPS=$(doctl compute reserved-ip list -o json)
    
    OIFS="$IFS"
    IFS=$'\n'
    IP_OPTIONS=($(echo "$RESERVED_IPS" | jq -r --arg region "$SNAPSHOT_REGION" \
      '.[] | select(.region.slug == $region) | select(.droplet == null) | "\(.ip)|unassigned|\(.region.slug)"'))
    IFS="$OIFS"
    
    if [ ${#IP_OPTIONS[@]} -eq 0 ]; then
      echo "No unassigned reserved IPs found in $SNAPSHOT_REGION."
      RESERVED_IP=""
    else
      SELECTED=$(select_option "Select reserved IP:" "${IP_OPTIONS[@]}")
      RESERVED_IP=$(echo "$SELECTED" | cut -d'|' -f1)
      echo "Selected reserved IP: $RESERVED_IP"
    fi
  fi
fi

if [ -z "$DROPLET_TAGS" ]; then
  echo ""
  if read -r -p "Comma-separated tags (leave blank for none): " DROPLET_TAGS_INPUT; then
    DROPLET_TAGS="$DROPLET_TAGS_INPUT"
  fi
fi

if [ -z "$VPC_UUID" ]; then
  echo ""
  if read -r -p "VPC UUID (leave blank for default): " VPC_UUID_INPUT; then
    VPC_UUID="$VPC_UUID_INPUT"
  fi
fi

if [ -z "$USER_DATA_FILE" ]; then
  echo ""
  if read -r -p "Cloud-init user-data file path (leave blank for none): " USER_DATA_INPUT; then
    USER_DATA_FILE="$USER_DATA_INPUT"
  fi
fi

if [ -z "$DROPLET_NAME" ]; then
  DEFAULT_NAME="restored-$(echo "$SNAPSHOT_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')-$(date +%Y%m%d)"
  echo ""
  if ! read -r -p "Droplet name [$DEFAULT_NAME]: " DROPLET_NAME; then
    echo -e "\nCancelled."
    exit 1
  fi
  DROPLET_NAME=${DROPLET_NAME:-$DEFAULT_NAME}
fi

echo ""
echo "========================================"
echo "Creating droplet:"
echo "  Name: $DROPLET_NAME"
echo "  Size: $SIZE_SLUG"
echo "  Region: $SNAPSHOT_REGION"
echo "  Image: $SNAPSHOT_ID ($SNAPSHOT_NAME)"
if [ -n "$SSH_KEY_ID" ]; then echo "  SSH Keys: $SSH_KEY_ID"; fi
if [ -n "$RESERVED_IP" ]; then echo "  Reserved IP: $RESERVED_IP"; fi
if [ -n "$DROPLET_TAGS" ]; then echo "  Tags: $DROPLET_TAGS"; fi
if [ -n "$VPC_UUID" ]; then echo "  VPC: $VPC_UUID"; fi
if [ -n "$USER_DATA_FILE" ]; then echo "  User Data: $USER_DATA_FILE"; fi
echo "========================================"
echo ""
if ! read -r -p "Proceed? (y/n): " CONFIRM; then
  echo -e "\nAborted."
  exit 1
fi

if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
  echo "Aborted."
  exit 0
fi

# Build doctl command array
CREATE_CMD=("doctl" "compute" "droplet" "create" "$DROPLET_NAME" "--region" "$SNAPSHOT_REGION" "--size" "$SIZE_SLUG" "--image" "$SNAPSHOT_ID" "--wait")

if [ -n "$SSH_KEY_ID" ]; then CREATE_CMD+=("--ssh-keys" "$SSH_KEY_ID"); fi
if [ -n "$DROPLET_TAGS" ]; then CREATE_CMD+=("--tag-names" "$DROPLET_TAGS"); fi
if [ -n "$VPC_UUID" ]; then CREATE_CMD+=("--vpc-uuid" "$VPC_UUID"); fi
if [ -n "$USER_DATA_FILE" ] && [ -f "$USER_DATA_FILE" ]; then CREATE_CMD+=("--user-data-file" "$USER_DATA_FILE"); fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[DRY RUN] ${CREATE_CMD[*]}"
  DROPLET_ID="dry-run-droplet-id"
  IP="203.0.113.1"
else
  echo "Creating droplet (this may take a few minutes)..."
  if ! CREATE_RESPONSE=$("${CREATE_CMD[@]}" -o json); then
    echo "Failed to create droplet."
    exit 1
  fi
  
  DROPLET_ID=$(echo "$CREATE_RESPONSE" | jq -r '.[0].id')
  IP=$(echo "$CREATE_RESPONSE" | jq -r '.[0].networks.v4[] | select(.type == "public") | .ip_address' | head -1)
  
  echo "Created droplet: $DROPLET_ID"
  log_action "Restored droplet '$DROPLET_NAME' (ID: $DROPLET_ID) from snapshot '$SNAPSHOT_ID'."
fi

if [ -n "$RESERVED_IP" ]; then
  echo ""
  echo "Assigning reserved IP $RESERVED_IP to droplet..."
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY RUN] doctl compute reserved-ip-action assign $RESERVED_IP $DROPLET_ID"
  else
    if doctl compute reserved-ip-action assign "$RESERVED_IP" "$DROPLET_ID"; then
      echo "Reserved IP assigned successfully!"
      echo ""
      echo "Connect with: ssh root@$RESERVED_IP"
      log_action "Assigned reserved IP $RESERVED_IP to droplet '$DROPLET_NAME' (ID: $DROPLET_ID)."
    else
      echo "Failed to assign reserved IP. You may need to assign it manually in the DO console."
      echo "Connect with: ssh root@$IP"
    fi
  fi
else
  echo ""
  echo "Connect with: ssh root@$IP"
fi
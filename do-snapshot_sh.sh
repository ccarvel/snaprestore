#!/bin/bash
set -e

# Catch SIGINT (Ctrl-C) and SIGQUIT (Ctrl-\) gracefully
trap 'echo ""; echo "Operation aborted."; exit 1' INT QUIT

#-----------------------------------------
# CONFIGURATION - Set these or use "list" to fetch
#-----------------------------------------
# If using 1Password, DO_TOKEN can be fetched via 'op read':
# DO_TOKEN=$(op read "op://Private/DigitalOcean/credential" 2>/dev/null)
DO_TOKEN=""           # Required: your DigitalOcean API token
DROPLET_ID=""         # Use "list" to see available droplets
SNAPSHOT_NAME=""      # Optional: defaults to {droplet-name}-snapshot-{date}
DRY_RUN=0             # Set to 1 to enable dry-run mode
#-----------------------------------------

# Paths
CACHE_DIR="${HOME}/.config/do-snap-tool"
LOG_DIR="${HOME}/.local/share/do-snap-tool"
LOG_FILE="${LOG_DIR}/action.log"

mkdir -p "$CACHE_DIR" "$LOG_DIR"

log_action() {
  local msg="$1"
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $msg" >> "$LOG_FILE"
}

# Parse args
if [[ "$1" == "--dry-run" ]]; then
  DRY_RUN=1
  echo "⚠️ DRY RUN MODE ENABLED. No mutating DO API calls will be executed. ⚠️"
  echo ""
fi

# Check if fzf is available
HAS_FZF=$(command -v fzf >/dev/null 2>&1 && echo "yes" || echo "no")

# Check for doctl
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
      # Handled EOF/Ctrl-C
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
       # Handled EOF
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

# Load token from config, environment, or op read, or prompt
if [ -z "$DO_TOKEN" ]; then
  DO_TOKEN="${DO_API_TOKEN:-}"
fi

# If STILL not set, check if op is available and token can be fetched from a predefined path
if [ -z "$DO_TOKEN" ] && command -v op >/dev/null 2>&1; then
  # This is a placeholder path. Update to actual vault path in config.
  # DO_TOKEN=$(op read "op://Private/DigitalOcean/credential" 2>/dev/null || echo "")
  :
fi

if [ -z "$DO_TOKEN" ]; then
  if ! read -rs -p "DigitalOcean API Token: " DO_TOKEN; then
    echo -e "\nInput cancelled."
    exit 1
  fi
  echo ""
fi

# We have the token. Initialize doctl context on-the-fly to ensure it doesn't pollute global config
# DO_TOKEN is passed securely via env variable without echoing it or logging it.
export DIGITALOCEAN_ACCESS_TOKEN="$DO_TOKEN"

list_droplets() {
  echo "Fetching droplets..."
  doctl compute droplet list --format "ID,Name,Status,SizeSlug,Region,Disk" --no-header | awk '{print $1"  "$2"  "$3"  "$4"  "$5"  "$6"GB disk"}'
}

DROPLET_ID_LOWER=$(echo "$DROPLET_ID" | tr '[:upper:]' '[:lower:]')

case "$DROPLET_ID_LOWER" in
  list|get) list_droplets; exit 0 ;;
esac

echo "Fetching droplets..."
DROPLETS_RAW=$(doctl compute droplet list --format "ID,Name,Status,SizeSlug,Region,Disk,VCPUs,Memory,PublicIPv4,PrivateIPv4" -o json)

if [ -z "$DROPLET_ID" ]; then
  # Parse droplets into options
  OIFS="$IFS"
  IFS=$'\n'
  DROPLET_OPTIONS=($(echo "$DROPLETS_RAW" | jq -r '.[] | "\(.id)|\(.name)|\(.status)|\(.size_slug)|\(.region.slug)|\(.disk)GB"'))
  IFS="$OIFS"
  
  if [ ${#DROPLET_OPTIONS[@]} -eq 0 ]; then
    echo "No droplets found."
    exit 1
  fi
  
  SELECTED=$(select_option "Select droplet to snapshot:" "${DROPLET_OPTIONS[@]}")
  DROPLET_ID=$(echo "$SELECTED" | cut -d'|' -f1)
fi

# Extract details for the selected droplet using jq on the raw output
DROPLET_JSON=$(echo "$DROPLETS_RAW" | jq -r ".[] | select(.id == $DROPLET_ID)")
if [ -z "$DROPLET_JSON" ]; then
  echo "Droplet ID $DROPLET_ID not found."
  exit 1
fi

DROPLET_NAME=$(echo "$DROPLET_JSON" | jq -r '.name')
DROPLET_STATUS=$(echo "$DROPLET_JSON" | jq -r '.status')
DROPLET_SIZE=$(echo "$DROPLET_JSON" | jq -r '.size_slug')
DROPLET_REGION=$(echo "$DROPLET_JSON" | jq -r '.region.slug')
DROPLET_DISK=$(echo "$DROPLET_JSON" | jq -r '.disk')
DROPLET_VCPUS=$(echo "$DROPLET_JSON" | jq -r '.vcpus')
DROPLET_MEMORY=$(echo "$DROPLET_JSON" | jq -r '.memory')
DROPLET_IP=$(echo "$DROPLET_JSON" | jq -r '.networks.v4[] | select(.type == "public") | .ip_address' | head -1)

# Checking for reserved IP
echo ""
echo "Checking for reserved IP..."
RESERVED_IPS_RAW=$(doctl compute reserved-ip list -o json)
DROPLET_RESERVED_IP=$(echo "$RESERVED_IPS_RAW" | jq -r ".[] | select(.droplet.id == $DROPLET_ID) | .ip")

echo ""
echo "========================================"
echo "Droplet Details"
echo "========================================"
echo "  ID: $DROPLET_ID"
echo "  Name: $DROPLET_NAME"
echo "  Status: $DROPLET_STATUS"
echo "  Region: $DROPLET_REGION"
echo "  Size: $DROPLET_SIZE"
echo "  vCPUs: $DROPLET_VCPUS"
echo "  Memory: ${DROPLET_MEMORY}MB"
echo "  Disk: ${DROPLET_DISK}GB"
echo "  Public IP: $DROPLET_IP"
if [ -n "$DROPLET_RESERVED_IP" ]; then
  echo "  Reserved IP: $DROPLET_RESERVED_IP"
else
  echo "  Reserved IP: (none)"
fi
echo "========================================"

if [ -z "$SNAPSHOT_NAME" ]; then
  DEFAULT_SNAPSHOT_NAME="${DROPLET_NAME}-snapshot-$(date +%Y%m%d-%H%M)"
  echo ""
  if ! read -r -p "Snapshot name [$DEFAULT_SNAPSHOT_NAME]: " SNAPSHOT_NAME; then
     echo -e "\nCancelled."
     exit 1
  fi
  SNAPSHOT_NAME=${SNAPSHOT_NAME:-$DEFAULT_SNAPSHOT_NAME}
fi

echo ""
echo "Snapshot will be named: $SNAPSHOT_NAME"

echo ""
if ! read -r -p "Proceed with snapshot? (y/n): " CONFIRM; then
  echo -e "\nAborted."
  exit 1
fi
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
  echo "Aborted."
  exit 0
fi

if [ "$DROPLET_STATUS" = "active" ]; then
  echo ""
  echo "Shutting down droplet for clean snapshot..."
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY RUN] doctl compute droplet-action power-off $DROPLET_ID --wait"
  else
    # doctl compute droplet-action power-off waits until it's off
    if ! doctl compute droplet-action power-off "$DROPLET_ID" --wait; then
      echo "Power off action failed. Check DO status."
      exit 1
    fi
    echo "Shutdown complete."
  fi
else
  echo ""
  echo "Droplet is already off."
fi

echo ""
echo "Creating snapshot '$SNAPSHOT_NAME' (this may take several minutes)..."
if [ "$DRY_RUN" -eq 1 ]; then
  echo "[DRY RUN] doctl compute droplet-action snapshot $DROPLET_ID --snapshot-name $SNAPSHOT_NAME --wait"
  NEW_SNAPSHOT_ID="dry-run-snap-id"
  NEW_SNAPSHOT_SIZE="0"
  NEW_SNAPSHOT_MIN_DISK="$DROPLET_DISK"
else
  if ! doctl compute droplet-action snapshot "$DROPLET_ID" --snapshot-name "$SNAPSHOT_NAME" --wait; then
    echo "Snapshot failed!"
    exit 1
  fi
  
  echo "Snapshot complete!"
  
  echo ""
  echo "Fetching snapshot details..."
  NEW_SNAPSHOT_JSON=$(doctl compute snapshot list --resource droplet -o json | jq -r ".[] | select(.name == \"$SNAPSHOT_NAME\")")
  NEW_SNAPSHOT_ID=$(echo "$NEW_SNAPSHOT_JSON" | jq -r '.id')
  NEW_SNAPSHOT_SIZE=$(echo "$NEW_SNAPSHOT_JSON" | jq -r '.size_gigabytes')
  NEW_SNAPSHOT_MIN_DISK=$(echo "$NEW_SNAPSHOT_JSON" | jq -r '.min_disk_size')
  
  log_action "Created snapshot '$SNAPSHOT_NAME' (ID: $NEW_SNAPSHOT_ID) from droplet '$DROPLET_NAME' (ID: $DROPLET_ID)."
fi

echo ""
echo "========================================"
echo "Snapshot Created Successfully"
echo "========================================"
echo "  ID: $NEW_SNAPSHOT_ID"
echo "  Name: $SNAPSHOT_NAME"
echo "  Size: ${NEW_SNAPSHOT_SIZE}GB"
echo "  Min Disk: ${NEW_SNAPSHOT_MIN_DISK}GB"
echo "========================================"

echo ""
echo "What would you like to do with the droplet?"
POST_OPTIONS=("start|Start it back up" "leave|Leave it shut down" "delete|Delete/destroy it")
SELECTED=$(select_option "Select action:" "${POST_OPTIONS[@]}")
POST_ACTION=$(echo "$SELECTED" | cut -d'|' -f1)

case "$POST_ACTION" in
  start)
    echo ""
    echo "Starting droplet..."
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[DRY RUN] doctl compute droplet-action power-on $DROPLET_ID --wait"
    else
      if ! doctl compute droplet-action power-on "$DROPLET_ID" --wait; then
        echo "Failed to start droplet."
        exit 1
      fi
      echo "Droplet is active!"
      if [ -n "$DROPLET_RESERVED_IP" ]; then
        echo "Connect with: ssh root@$DROPLET_RESERVED_IP"
      else
        echo "Connect with: ssh root@$DROPLET_IP"
      fi
      log_action "Started droplet '$DROPLET_NAME' (ID: $DROPLET_ID)."
    fi
    ;;
    
  leave)
    echo ""
    echo "Droplet left shut down."
    echo "Note: You are still being billed for the droplet while it exists."
    ;;
    
  delete)
    echo ""
    if [ -n "$DROPLET_RESERVED_IP" ]; then
      echo "WARNING: This droplet has reserved IP $DROPLET_RESERVED_IP assigned."
      echo "The reserved IP will be unassigned but NOT deleted."
    fi
    echo ""
    echo "⚠️  DANGER: DELETING DROPLET ⚠️"
    echo "To confirm, please type the name of the droplet exactly: '$DROPLET_NAME'"
    if ! read -r -p "> " DELETE_CONFIRM; then
      echo -e "\nCancelled."
      exit 1
    fi
    
    if [ "$DELETE_CONFIRM" = "$DROPLET_NAME" ]; then
      echo "Deleting droplet..."
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY RUN] doctl compute droplet delete $DROPLET_ID --force"
      else
        if doctl compute droplet delete "$DROPLET_ID" --force; then
          echo "Droplet deleted successfully."
          echo ""
          echo "Your snapshot '$SNAPSHOT_NAME' (ID: $NEW_SNAPSHOT_ID) is preserved."
          echo "Use do-restore.sh to restore from this snapshot later."
          log_action "Deleted droplet '$DROPLET_NAME' (ID: $DROPLET_ID)."
        else
          echo "Failed to delete droplet."
        fi
      fi
    else
      echo "Name did not match. Deletion cancelled. Droplet left shut down."
    fi
    ;;
esac

echo ""
echo "Done!"
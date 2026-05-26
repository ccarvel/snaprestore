#!/bin/bash
set -e

trap 'echo ""; echo -e "\033[31mOperation aborted.\033[0m"; exit 1' INT QUIT

#-----------------------------------------
# UI BOOTSTRAPPER & TOOLKIT
#-----------------------------------------
USE_GUM=0
if command -v gum >/dev/null 2>&1; then
  USE_GUM=1
else
  if command -v brew >/dev/null 2>&1; then
    echo -e "\033[1;36m[Optional]\033[0m This script supports an enhanced visual UI using 'gum'."
    read -r -p "Would you like to install gum via Homebrew? (y/N): " INSTALL_GUM
    if [[ "$INSTALL_GUM" =~ ^[Yy] ]]; then
      echo "Installing gum..."
      if brew install gum; then
        USE_GUM=1
      else
        echo -e "\033[31mFailed to install gum. Falling back to text UI.\033[0m"
      fi
    fi
  fi
fi

# NO_COLOR handling
if [ -n "$NO_COLOR" ]; then
  C_RESET=""
  C_INFO=""
  C_SUCCESS=""
  C_WARN=""
  C_ERROR=""
  C_HEADER=""
  C_DIM=""
else
  C_RESET="\033[0m"
  C_INFO="\033[34m"     # Blue
  C_SUCCESS="\033[32m"  # Green
  C_WARN="\033[33m"     # Yellow
  C_ERROR="\033[31m"    # Red
  C_HEADER="\033[1;36m" # Bold Cyan
  C_DIM="\033[2m"       # Dim
fi

ui_header() {
  if [ "$USE_GUM" -eq 1 ]; then
    gum style --border double --margin "1 0" --padding "0 2" --border-foreground 212 "$1"
  else
    echo ""
    echo -e "${C_HEADER}========================================${C_RESET}"
    echo -e "${C_HEADER}  $1${C_RESET}"
    echo -e "${C_HEADER}========================================${C_RESET}"
  fi
}

ui_info() { echo -e "${C_INFO}▸ INFO${C_RESET}  $1"; }
ui_success() { echo -e "${C_SUCCESS}✓ OK${C_RESET}    $1"; }
ui_warn() { echo -e "${C_WARN}⚠ WARN${C_RESET}  $1" >&2; }
ui_error() { echo -e "${C_ERROR}✗ ERROR${C_RESET} $1" >&2; }

ui_spin() {
  local title="$1"
  shift
  if [ "$USE_GUM" -eq 1 ]; then
    gum spin --spinner dot --title "$title" -- "$@"
  else
    echo -e "${C_INFO}⏳ WAIT${C_RESET}  $title"
    "$@"
    ui_success "Done."
  fi
}

ui_choose() {
  local prompt="$1"
  shift
  local options=("$@")
  
  if [ "$USE_GUM" -eq 1 ]; then
    echo -e "${C_INFO}?${C_RESET} $prompt"
    local selected
    selected=$(printf '%s\n' "${options[@]}" | gum choose --cursor="> " --height=15)
    if [ -z "$selected" ]; then
      ui_error "Selection cancelled."
      exit 1
    fi
    echo "$selected"
  else
    # Fallback to fzf if available, else numbered list
    if command -v fzf >/dev/null 2>&1; then
      local selected
      selected=$(printf '%s\n' "${options[@]}" | fzf --height=15 --prompt="$prompt ")
      if [ -z "$selected" ]; then
        ui_error "Selection cancelled."
        exit 1
      fi
      echo "$selected"
    else
      echo "" >&2
      echo -e "${C_INFO}?${C_RESET} $prompt" >&2
      local i=1
      for opt in "${options[@]}"; do
        echo "  $i) $opt" >&2
        ((i++))
      done
      local selection
      if ! read -r -p "Enter number: " selection; then
         echo "" >&2
         ui_error "Selection cancelled."
         exit 1
      fi
      if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#options[@]}" ]; then
         ui_error "Invalid selection."
         exit 1
      fi
      echo "${options[$((selection-1))]}"
    fi
  fi
}

ui_confirm() {
  local prompt="$1"
  if [ "$USE_GUM" -eq 1 ]; then
    gum confirm "$prompt"
    return $?
  else
    local answer
    read -r -p "? $prompt (y/N): " answer
    if [[ "$answer" =~ ^[Yy] ]]; then
      return 0
    else
      return 1
    fi
  fi
}

ui_input() {
  local prompt="$1"
  local default="$2"
  local res
  if [ "$USE_GUM" -eq 1 ]; then
    res=$(gum input --prompt="? $prompt " --placeholder="$default")
  else
    read -r -p "? $prompt [$default]: " res
  fi
  [ -z "$res" ] && res="$default"
  echo "$res"
}

ui_input_secret() {
  local prompt="$1"
  local res
  if [ "$USE_GUM" -eq 1 ]; then
    res=$(gum input --password --prompt="? $prompt ")
    echo "$res"
  else
    read -rs -p "? $prompt " res
    echo "" >&2
    echo "$res"
  fi
}

#-----------------------------------------
# CONFIGURATION
#-----------------------------------------
DO_TOKEN=""           
DROPLET_ID=""         
SNAPSHOT_NAME=""      
DRY_RUN=0             

CACHE_DIR="${HOME}/.config/do-snap-tool"
LOG_DIR="${HOME}/.local/share/do-snap-tool"
LOG_FILE="${LOG_DIR}/action.log"

mkdir -p "$CACHE_DIR" "$LOG_DIR"

log_action() {
  local msg="$1"
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $msg" >> "$LOG_FILE"
}

if [[ "$1" == "--dry-run" ]]; then
  DRY_RUN=1
  ui_warn "DRY RUN MODE ENABLED. No mutating DO API calls will be executed."
fi

if ! command -v doctl >/dev/null 2>&1; then
  ui_error "doctl is required but not installed."
  ui_info "Install with: brew install doctl"
  exit 1
fi

ui_header "DigitalOcean Snapshot Tool"

if [ -z "$DO_TOKEN" ]; then
  DO_TOKEN="${DO_API_TOKEN:-}"
fi

if [ -z "$DO_TOKEN" ] && command -v op >/dev/null 2>&1; then
  : # Placeholder for 1password fetch
fi

if [ -z "$DO_TOKEN" ]; then
  DO_TOKEN=$(ui_input_secret "DigitalOcean API Token:")
  if [ -z "$DO_TOKEN" ]; then
    ui_error "Input cancelled."
    exit 1
  fi
fi

export DIGITALOCEAN_ACCESS_TOKEN="$DO_TOKEN"

list_droplets() {
  ui_info "Fetching droplets..."
  doctl compute droplet list --format "ID,Name,Status,SizeSlug,Region,Disk" --no-header | awk '{print $1"  "$2"  "$3"  "$4"  "$5"  "$6"GB disk"}'
}

DROPLET_ID_LOWER=$(echo "$DROPLET_ID" | tr '[:upper:]' '[:lower:]')

case "$DROPLET_ID_LOWER" in
  list|get) list_droplets; exit 0 ;;
esac

ui_info "Fetching droplets..."
DROPLETS_RAW=$(doctl compute droplet list --format "ID,Name,Status,SizeSlug,Region,Disk,VCPUs,Memory,PublicIPv4,PrivateIPv4" -o json)

if [ -z "$DROPLET_ID" ]; then
  OIFS="$IFS"
  IFS=$'\n'
  DROPLET_OPTIONS=($(echo "$DROPLETS_RAW" | jq -r '.[] | "\(.id)|\(.name)|\(.status)|\(.size_slug)|\(.region.slug)|\(.disk)GB"'))
  IFS="$OIFS"
  
  if [ ${#DROPLET_OPTIONS[@]} -eq 0 ]; then
    ui_error "No droplets found."
    exit 1
  fi
  
  SELECTED=$(ui_choose "Select droplet to snapshot:" "${DROPLET_OPTIONS[@]}")
  DROPLET_ID=$(echo "$SELECTED" | cut -d'|' -f1)
fi

DROPLET_JSON=$(echo "$DROPLETS_RAW" | jq -r ".[] | select(.id == $DROPLET_ID)")
if [ -z "$DROPLET_JSON" ]; then
  ui_error "Droplet ID $DROPLET_ID not found."
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

ui_info "Checking for reserved IP..."
RESERVED_IPS_RAW=$(doctl compute reserved-ip list -o json)
DROPLET_RESERVED_IP=$(echo "$RESERVED_IPS_RAW" | jq -r ".[] | select(.droplet.id == $DROPLET_ID) | .ip")

if [ "$USE_GUM" -eq 1 ]; then
  # Use gum table or format
  DETAILS="ID: $DROPLET_ID
Name: $DROPLET_NAME
Status: $DROPLET_STATUS
Region: $DROPLET_REGION
Size: $DROPLET_SIZE
vCPUs: $DROPLET_VCPUS
Memory: ${DROPLET_MEMORY}MB
Disk: ${DROPLET_DISK}GB
Public IP: $DROPLET_IP
Reserved IP: ${DROPLET_RESERVED_IP:-(none)}"
  gum style --margin "1 2" --padding "1 2" --border rounded --border-foreground 212 "$DETAILS"
else
  echo ""
  echo -e "${C_DIM}Droplet Details${C_RESET}"
  echo "  ID: $DROPLET_ID"
  echo "  Name: $DROPLET_NAME"
  echo "  Status: $DROPLET_STATUS"
  echo "  Region: $DROPLET_REGION"
  echo "  Size: $DROPLET_SIZE"
  echo "  vCPUs: $DROPLET_VCPUS"
  echo "  Memory: ${DROPLET_MEMORY}MB"
  echo "  Disk: ${DROPLET_DISK}GB"
  echo "  Public IP: $DROPLET_IP"
  echo "  Reserved IP: ${DROPLET_RESERVED_IP:-(none)}"
  echo ""
fi

if [ -z "$SNAPSHOT_NAME" ]; then
  DEFAULT_SNAPSHOT_NAME="${DROPLET_NAME}-snapshot-$(date +%Y%m%d-%H%M)"
  SNAPSHOT_NAME=$(ui_input "Snapshot name:" "$DEFAULT_SNAPSHOT_NAME")
fi

ui_info "Snapshot will be named: $SNAPSHOT_NAME"

if ! ui_confirm "Proceed with snapshot?"; then
  ui_error "Aborted."
  exit 0
fi

if [ "$DROPLET_STATUS" = "active" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    ui_info "[DRY RUN] doctl compute droplet-action power-off $DROPLET_ID --wait"
  else
    if ! ui_spin "Shutting down droplet..." doctl compute droplet-action power-off "$DROPLET_ID" --wait; then
      ui_error "Power off action failed. Check DO status."
      exit 1
    fi
  fi
else
  ui_info "Droplet is already off."
fi

if [ "$DRY_RUN" -eq 1 ]; then
  ui_info "[DRY RUN] doctl compute droplet-action snapshot $DROPLET_ID --snapshot-name $SNAPSHOT_NAME --wait"
  NEW_SNAPSHOT_ID="dry-run-snap-id"
  NEW_SNAPSHOT_SIZE="0"
  NEW_SNAPSHOT_MIN_DISK="$DROPLET_DISK"
else
  if ! ui_spin "Creating snapshot '$SNAPSHOT_NAME' (takes a few minutes)..." doctl compute droplet-action snapshot "$DROPLET_ID" --snapshot-name "$SNAPSHOT_NAME" --wait; then
    ui_error "Snapshot failed!"
    exit 1
  fi
  
  ui_info "Fetching snapshot details..."
  NEW_SNAPSHOT_JSON=$(doctl compute snapshot list --resource droplet -o json | jq -r ".[] | select(.name == \"$SNAPSHOT_NAME\")")
  NEW_SNAPSHOT_ID=$(echo "$NEW_SNAPSHOT_JSON" | jq -r '.id')
  NEW_SNAPSHOT_SIZE=$(echo "$NEW_SNAPSHOT_JSON" | jq -r '.size_gigabytes')
  NEW_SNAPSHOT_MIN_DISK=$(echo "$NEW_SNAPSHOT_JSON" | jq -r '.min_disk_size')
  
  log_action "Created snapshot '$SNAPSHOT_NAME' (ID: $NEW_SNAPSHOT_ID) from droplet '$DROPLET_NAME' (ID: $DROPLET_ID)."
fi

if [ "$USE_GUM" -eq 1 ]; then
  SUCCESS_MSG="SNAPSHOT CREATED SUCCESSFULLY
ID: $NEW_SNAPSHOT_ID
Name: $SNAPSHOT_NAME
Size: ${NEW_SNAPSHOT_SIZE}GB
Min Disk: ${NEW_SNAPSHOT_MIN_DISK}GB"
  gum style --margin "1 2" --padding "1 2" --border rounded --border-foreground 42 "$SUCCESS_MSG"
else
  echo ""
  ui_success "Snapshot Created Successfully"
  echo "  ID: $NEW_SNAPSHOT_ID"
  echo "  Name: $SNAPSHOT_NAME"
  echo "  Size: ${NEW_SNAPSHOT_SIZE}GB"
  echo "  Min Disk: ${NEW_SNAPSHOT_MIN_DISK}GB"
  echo ""
fi

POST_OPTIONS=("start|Start it back up" "leave|Leave it shut down" "delete|Delete/destroy it")
SELECTED=$(ui_choose "What would you like to do with the droplet?" "${POST_OPTIONS[@]}")
POST_ACTION=$(echo "$SELECTED" | cut -d'|' -f1)

case "$POST_ACTION" in
  start)
    if [ "$DRY_RUN" -eq 1 ]; then
      ui_info "[DRY RUN] doctl compute droplet-action power-on $DROPLET_ID --wait"
    else
      if ! ui_spin "Starting droplet..." doctl compute droplet-action power-on "$DROPLET_ID" --wait; then
        ui_error "Failed to start droplet."
        exit 1
      fi
      ui_success "Droplet is active!"
      if [ -n "$DROPLET_RESERVED_IP" ]; then
        ui_info "Connect with: ssh root@$DROPLET_RESERVED_IP"
      else
        ui_info "Connect with: ssh root@$DROPLET_IP"
      fi
      log_action "Started droplet '$DROPLET_NAME' (ID: $DROPLET_ID)."
    fi
    ;;
    
  leave)
    ui_success "Droplet left shut down."
    ui_warn "Note: You are still being billed for the droplet while it exists."
    ;;
    
  delete)
    if [ -n "$DROPLET_RESERVED_IP" ]; then
      ui_warn "This droplet has reserved IP $DROPLET_RESERVED_IP assigned."
      ui_warn "The reserved IP will be unassigned but NOT deleted."
    fi
    
    echo -e "\n${C_ERROR}⚠️  DANGER: DELETING DROPLET ⚠️${C_RESET}"
    DELETE_CONFIRM=$(ui_input "To confirm, type the exact name '$DROPLET_NAME':" "")
    
    if [ "$DELETE_CONFIRM" = "$DROPLET_NAME" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        ui_info "[DRY RUN] doctl compute droplet delete $DROPLET_ID --force"
      else
        if ui_spin "Deleting droplet..." doctl compute droplet delete "$DROPLET_ID" --force; then
          ui_success "Droplet deleted successfully."
          ui_info "Your snapshot '$SNAPSHOT_NAME' (ID: $NEW_SNAPSHOT_ID) is preserved."
          ui_info "Use do-restore_sh.sh to restore from this snapshot later."
          log_action "Deleted droplet '$DROPLET_NAME' (ID: $DROPLET_ID)."
        else
          ui_error "Failed to delete droplet."
        fi
      fi
    else
      ui_warn "Name did not match. Deletion cancelled. Droplet left shut down."
    fi
    ;;
esac

ui_success "Done!"
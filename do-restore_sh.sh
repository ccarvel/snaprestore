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
  
  if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
    ui_error "Interactive menu '$prompt' skipped in non-interactive mode. Provide required variables via environment."
    exit 1
  fi
  
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
  if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then return 0; fi
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
  
  if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
    echo "$default"
    return 0
  fi
  
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
  
  if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
    ui_error "Secret input required but running non-interactively."
    exit 1
  fi
  
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
SNAPSHOT_ID=""        
SSH_KEY_ID=""         
SIZE_SLUG=""          
DROPLET_NAME=""       
RESERVED_IP=""        
DROPLET_TAGS=""       
VPC_UUID=""           
USER_DATA_FILE=""     
DRY_RUN=0             

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

NON_INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ui_warn "DRY RUN MODE ENABLED. No mutating DO API calls will be executed."
      ;;
    --force|-y)
      NON_INTERACTIVE=1
      ;;
  esac
done

if ! command -v doctl >/dev/null 2>&1; then
  ui_error "doctl is required but not installed."
  ui_info "Install with: brew install doctl"
  exit 1
fi

ui_header "DigitalOcean Restore Tool"

if [ -z "$DO_TOKEN" ]; then
  DO_TOKEN="${DO_API_TOKEN:-}"
fi

if [ -z "$DO_TOKEN" ] && command -v op >/dev/null 2>&1; then
  : # Placeholder for op read
fi

if [ -z "$DO_TOKEN" ]; then
  DO_TOKEN=$(ui_input_secret "DigitalOcean API Token:")
  if [ -z "$DO_TOKEN" ]; then
    ui_error "Input cancelled."
    exit 1
  fi
fi

export DIGITALOCEAN_ACCESS_TOKEN="$DO_TOKEN"

update_cache() {
  local cache_file="$1"
  local cmd="$2"
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
  ui_info "Fetching snapshots..."
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
  ui_info "Fetching SSH keys..."
  doctl compute ssh-key list --format "ID,Name" --no-header | awk '{print $1"  "$2}'
}

list_sizes() {
  SNAPSHOT_ID_CHECK=$(echo "$SNAPSHOT_ID" | tr '[:upper:]' '[:lower:]')
  if [ -z "$SNAPSHOT_ID" ] || [ "$SNAPSHOT_ID_CHECK" = "list" ]; then
    ui_error "Error: Set SNAPSHOT_ID first to list compatible sizes"
    exit 1
  fi
  
  SNAPSHOT_JSON=$(doctl compute snapshot get "$SNAPSHOT_ID" -o json)
  SNAPSHOT_MIN_DISK=$(echo "$SNAPSHOT_JSON" | jq -r '.[0].min_disk_size')
  SNAPSHOT_REGION=$(echo "$SNAPSHOT_JSON" | jq -r '.[0].regions[0]')
  
  ui_info "Fetching sizes compatible with snapshot (min disk: ${SNAPSHOT_MIN_DISK}GB, region: $SNAPSHOT_REGION)..."
  update_cache "$SIZES_CACHE" "doctl compute size list"
  jq -r --arg region "$SNAPSHOT_REGION" --argjson min_disk "$SNAPSHOT_MIN_DISK" \
    '.[] | select(.available == true) | select(.regions[] == $region) | select(.disk >= $min_disk) | "\(.slug)  \(.vcpus)vCPU  \(.memory)MB RAM  \(.disk)GB disk  $\(.price_monthly)/mo"' \
    "$SIZES_CACHE" | sort -t'$' -k2 -n
}

list_reserved_ips() {
  ui_info "Fetching reserved IPs..."
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

ui_info "Fetching snapshots..."
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
    ui_error "No snapshots found."
    exit 1
  fi
  
  SELECTED=$(ui_choose "Select snapshot:" "${SNAPSHOT_OPTIONS[@]}")
  SNAPSHOT_ID=$(echo "$SELECTED" | cut -d'|' -f1)
fi

SNAPSHOT=$(echo "$SNAPSHOTS_RAW" | jq -r ".[] | select(.id == \"$SNAPSHOT_ID\")")
SNAPSHOT_SIZE=$(echo "$SNAPSHOT" | jq -r '.size_gigabytes')
SNAPSHOT_MIN_DISK=$(echo "$SNAPSHOT" | jq -r '.min_disk_size')
SNAPSHOT_REGION=$(echo "$SNAPSHOT" | jq -r '.regions[0]')
SNAPSHOT_NAME=$(echo "$SNAPSHOT" | jq -r '.name')

ui_info "Selected: $SNAPSHOT_NAME ($SNAPSHOT_REGION, ${SNAPSHOT_SIZE}GB)"

ui_info "Fetching droplet sizes..."
update_cache "$SIZES_CACHE" "doctl compute size list"

if [ -z "$SIZE_SLUG" ]; then
  OIFS="$IFS"
  IFS=$'\n'
  SIZE_OPTIONS=($(jq -r --arg region "$SNAPSHOT_REGION" --argjson min_disk "$SNAPSHOT_MIN_DISK" \
    '.[] | select(.available == true) | select(.regions[] == $region) | select(.disk >= $min_disk) | "\(.slug)|\(.vcpus)vCPU|\(.memory)MB|\(.disk)GB|$\(.price_monthly)/mo"' \
    "$SIZES_CACHE" | sort -t'$' -k2 -n))
  IFS="$OIFS"
  
  if [ ${#SIZE_OPTIONS[@]} -eq 0 ]; then
    ui_error "No compatible droplet sizes found (need >= ${SNAPSHOT_MIN_DISK}GB disk in $SNAPSHOT_REGION)."
    exit 1
  fi
  
  SELECTED=$(ui_choose "Select droplet size:" "${SIZE_OPTIONS[@]}")
  SIZE_SLUG=$(echo "$SELECTED" | cut -d'|' -f1)
fi

ui_info "Fetching SSH keys..."
KEYS=$(doctl compute ssh-key list -o json)

if [ -z "$SSH_KEY_ID" ]; then
  if ui_confirm "Does this droplet require an SSH key?"; then
    OIFS="$IFS"
    IFS=$'\n'
    KEY_OPTIONS=($(echo "$KEYS" | jq -r '.[] | "\(.id)|\(.name)"'))
    IFS="$OIFS"
    
    if [ ${#KEY_OPTIONS[@]} -eq 0 ]; then
      ui_error "No SSH keys found in your account."
      exit 1
    fi
    
    SELECTED=$(ui_choose "Select SSH key:" "${KEY_OPTIONS[@]}")
    SSH_KEY_ID=$(echo "$SELECTED" | cut -d'|' -f1)
  fi
fi

if [ -z "$RESERVED_IP" ]; then
  if ui_confirm "Assign a reserved IP?"; then
    ui_info "Fetching reserved IPs..."
    RESERVED_IPS=$(doctl compute reserved-ip list -o json)
    
    OIFS="$IFS"
    IFS=$'\n'
    IP_OPTIONS=($(echo "$RESERVED_IPS" | jq -r --arg region "$SNAPSHOT_REGION" \
      '.[] | select(.region.slug == $region) | select(.droplet == null) | "\(.ip)|unassigned|\(.region.slug)"'))
    IFS="$OIFS"
    
    if [ ${#IP_OPTIONS[@]} -eq 0 ]; then
      ui_warn "No unassigned reserved IPs found in $SNAPSHOT_REGION."
      RESERVED_IP=""
    else
      SELECTED=$(ui_choose "Select reserved IP:" "${IP_OPTIONS[@]}")
      RESERVED_IP=$(echo "$SELECTED" | cut -d'|' -f1)
    fi
  fi
fi

if [ -z "$DROPLET_TAGS" ]; then
  DROPLET_TAGS=$(ui_input "Comma-separated tags (leave blank for none):" "")
fi

if [ -z "$VPC_UUID" ]; then
  VPC_UUID=$(ui_input "VPC UUID (leave blank for default):" "")
fi

if [ -z "$USER_DATA_FILE" ]; then
  USER_DATA_FILE=$(ui_input "Cloud-init user-data file path (leave blank for none):" "")
fi

if [ -z "$DROPLET_NAME" ]; then
  DEFAULT_NAME="restored-$(echo "$SNAPSHOT_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')-$(date +%Y%m%d)"
  DROPLET_NAME=$(ui_input "Droplet name:" "$DEFAULT_NAME")
fi

if [ "$USE_GUM" -eq 1 ]; then
  DETAILS="Name: $DROPLET_NAME
Size: $SIZE_SLUG
Region: $SNAPSHOT_REGION
Image: $SNAPSHOT_ID ($SNAPSHOT_NAME)
SSH Keys: ${SSH_KEY_ID:-(none)}
Reserved IP: ${RESERVED_IP:-(none)}
Tags: ${DROPLET_TAGS:-(none)}
VPC: ${VPC_UUID:-(default)}
User Data: ${USER_DATA_FILE:-(none)}"
  gum style --margin "1 2" --padding "1 2" --border rounded --border-foreground 212 "$DETAILS"
else
  echo ""
  echo -e "${C_DIM}Droplet Configuration${C_RESET}"
  echo "  Name: $DROPLET_NAME"
  echo "  Size: $SIZE_SLUG"
  echo "  Region: $SNAPSHOT_REGION"
  echo "  Image: $SNAPSHOT_ID ($SNAPSHOT_NAME)"
  echo "  SSH Keys: ${SSH_KEY_ID:-(none)}"
  echo "  Reserved IP: ${RESERVED_IP:-(none)}"
  echo "  Tags: ${DROPLET_TAGS:-(none)}"
  echo "  VPC: ${VPC_UUID:-(default)}"
  echo "  User Data: ${USER_DATA_FILE:-(none)}"
  echo ""
fi

if ! ui_confirm "Proceed?"; then
  ui_error "Aborted."
  exit 0
fi

CREATE_CMD=("doctl" "compute" "droplet" "create" "$DROPLET_NAME" "--region" "$SNAPSHOT_REGION" "--size" "$SIZE_SLUG" "--image" "$SNAPSHOT_ID" "--wait")

if [ -n "$SSH_KEY_ID" ]; then CREATE_CMD+=("--ssh-keys" "$SSH_KEY_ID"); fi
if [ -n "$DROPLET_TAGS" ]; then CREATE_CMD+=("--tag-names" "$DROPLET_TAGS"); fi
if [ -n "$VPC_UUID" ]; then CREATE_CMD+=("--vpc-uuid" "$VPC_UUID"); fi
if [ -n "$USER_DATA_FILE" ] && [ -f "$USER_DATA_FILE" ]; then CREATE_CMD+=("--user-data-file" "$USER_DATA_FILE"); fi

if [ "$DRY_RUN" -eq 1 ]; then
  ui_info "[DRY RUN] ${CREATE_CMD[*]}"
  DROPLET_ID="dry-run-droplet-id"
  IP="203.0.113.1"
else
  CREATE_RESPONSE=$(mktemp)
  if ! ui_spin "Creating droplet (takes a few minutes)..." "${CREATE_CMD[@]}" -o json > "$CREATE_RESPONSE"; then
    ui_error "Failed to create droplet."
    cat "$CREATE_RESPONSE"
    rm "$CREATE_RESPONSE"
    exit 1
  fi
  
  DROPLET_ID=$(cat "$CREATE_RESPONSE" | jq -r '.[0].id')
  IP=$(cat "$CREATE_RESPONSE" | jq -r '.[0].networks.v4[] | select(.type == "public") | .ip_address' | head -1)
  rm "$CREATE_RESPONSE"
  
  ui_success "Created droplet: $DROPLET_ID"
  log_action "Restored droplet '$DROPLET_NAME' (ID: $DROPLET_ID) from snapshot '$SNAPSHOT_ID'."
fi

if [ -n "$RESERVED_IP" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    ui_info "[DRY RUN] doctl compute reserved-ip-action assign $RESERVED_IP $DROPLET_ID"
  else
    if ui_spin "Assigning reserved IP $RESERVED_IP to droplet..." doctl compute reserved-ip-action assign "$RESERVED_IP" "$DROPLET_ID"; then
      ui_success "Reserved IP assigned successfully!"
      ui_info "Connect with: ssh root@$RESERVED_IP"
      log_action "Assigned reserved IP $RESERVED_IP to droplet '$DROPLET_NAME' (ID: $DROPLET_ID)."
    else
      ui_error "Failed to assign reserved IP. You may need to assign it manually in the DO console."
      ui_info "Connect with: ssh root@$IP"
    fi
  fi
else
  ui_info "Connect with: ssh root@$IP"
fi
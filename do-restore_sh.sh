#!/bin/bash
set -e

#-----------------------------------------
# CONFIGURATION - Set these or use "list" to fetch
#-----------------------------------------
DO_TOKEN=""           # Required: your DigitalOcean API token
SNAPSHOT_ID=""        # Use "list" to see available snapshots
SSH_KEY_ID=""         # Use "list" to see available SSH keys
SIZE_SLUG=""          # Use "list" to see available sizes (requires SNAPSHOT_ID)
DROPLET_NAME=""       # Optional: defaults to restored-{snapshot}-{date}
RESERVED_IP=""        # Use "list" to see available reserved IPs, or set IP to assign
#-----------------------------------------

# Check if fzf is available
HAS_FZF=$(command -v fzf >/dev/null 2>&1 && echo "yes" || echo "no")

# Generic selection function: uses fzf if available, falls back to numbered menu
# Usage: selected=$(select_option "prompt" "option1" "option2" ...)
select_option() {
  local prompt="$1"
  shift
  local options=("$@")
  
  if [ "$HAS_FZF" = "yes" ]; then
    printf '%s\n' "${options[@]}" | fzf --height=15 --prompt="$prompt "
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
    read -p "Enter number: " selection
    echo "${options[$((selection-1))]}"
  fi
}

# Load token from config, environment, or prompt
DO_TOKEN="${DO_TOKEN:-$DO_API_TOKEN}"
if [ -z "$DO_TOKEN" ]; then
  read -p "DigitalOcean API Token: " DO_TOKEN
fi

# Helper function to list snapshots
list_snapshots() {
  echo "Fetching snapshots..."
  curl -s "https://api.digitalocean.com/v2/snapshots?resource_type=droplet" \
    -H "Authorization: Bearer $DO_TOKEN" | jq -r '.snapshots[] | "\(.id)  \(.name)  \(.size_gigabytes)GB  min_disk:\(.min_disk_size)GB  \(.regions[0])"'
}

# Helper function to list SSH keys
list_ssh_keys() {
  echo "Fetching SSH keys..."
  curl -s "https://api.digitalocean.com/v2/account/keys" \
    -H "Authorization: Bearer $DO_TOKEN" | jq -r '.ssh_keys[] | "\(.id)  \(.name)"'
}

# Helper function to list sizes for a snapshot
list_sizes() {
  SNAPSHOT_ID_CHECK=$(echo "$SNAPSHOT_ID" | tr '[:upper:]' '[:lower:]')
  if [ -z "$SNAPSHOT_ID" ] || [ "$SNAPSHOT_ID_CHECK" = "list" ]; then
    echo "Error: Set SNAPSHOT_ID first to list compatible sizes"
    exit 1
  fi
  
  SNAPSHOTS=$(curl -s "https://api.digitalocean.com/v2/snapshots?resource_type=droplet" \
    -H "Authorization: Bearer $DO_TOKEN")
  SNAPSHOT=$(echo "$SNAPSHOTS" | jq -r ".snapshots[] | select(.id == \"$SNAPSHOT_ID\")")
  SNAPSHOT_MIN_DISK=$(echo "$SNAPSHOT" | jq -r '.min_disk_size')
  SNAPSHOT_REGION=$(echo "$SNAPSHOT" | jq -r '.regions[0]')
  
  echo "Fetching sizes compatible with snapshot (min disk: ${SNAPSHOT_MIN_DISK}GB, region: $SNAPSHOT_REGION)..."
  curl -s "https://api.digitalocean.com/v2/sizes" \
    -H "Authorization: Bearer $DO_TOKEN" | jq -r --arg region "$SNAPSHOT_REGION" --argjson min_disk "$SNAPSHOT_MIN_DISK" \
    '.sizes[] | select(.available == true) | select(.regions[] == $region) | select(.disk >= $min_disk) | "\(.slug)  \(.vcpus)vCPU  \(.memory)MB RAM  \(.disk)GB disk  $\(.price_monthly)/mo"' \
    | sort -t'$' -k2 -n
}

# Helper function to list reserved IPs
list_reserved_ips() {
  echo "Fetching reserved IPs..."
  curl -s "https://api.digitalocean.com/v2/reserved_ips" \
    -H "Authorization: Bearer $DO_TOKEN" | jq -r '.reserved_ips[] | "\(.ip)  \(.region.slug)  droplet: \(.droplet.id // "unassigned")"'
}

# Check for "list" commands (case-insensitive)
SNAPSHOT_ID_LOWER=$(echo "$SNAPSHOT_ID" | tr '[:upper:]' '[:lower:]')
SSH_KEY_ID_LOWER=$(echo "$SSH_KEY_ID" | tr '[:upper:]' '[:lower:]')
SIZE_SLUG_LOWER=$(echo "$SIZE_SLUG" | tr '[:upper:]' '[:lower:]')
RESERVED_IP_LOWER=$(echo "$RESERVED_IP" | tr '[:upper:]' '[:lower:]')

case "$SNAPSHOT_ID_LOWER" in
  list|get) list_snapshots; exit 0 ;;
esac

case "$SSH_KEY_ID_LOWER" in
  list|get) list_ssh_keys; exit 0 ;;
esac

case "$SIZE_SLUG_LOWER" in
  list|get) list_sizes; exit 0 ;;
esac

case "$RESERVED_IP_LOWER" in
  list|get) list_reserved_ips; exit 0 ;;
esac

# Fetch snapshots
echo "Fetching snapshots..."
SNAPSHOTS=$(curl -s "https://api.digitalocean.com/v2/snapshots?resource_type=droplet" \
  -H "Authorization: Bearer $DO_TOKEN")

# If SNAPSHOT_ID not set, prompt with selection
if [ -z "$SNAPSHOT_ID" ]; then
  SNAPSHOT_OPTIONS=($(echo "$SNAPSHOTS" | jq -r '.snapshots[] | "\(.id)|\(.name)|\(.size_gigabytes)GB|min:\(.min_disk_size)GB|\(.regions[0])"'))
  
  if [ ${#SNAPSHOT_OPTIONS[@]} -eq 0 ]; then
    echo "No snapshots found."
    exit 1
  fi
  
  SELECTED=$(select_option "Select snapshot:" "${SNAPSHOT_OPTIONS[@]}")
  SNAPSHOT_ID=$(echo "$SELECTED" | cut -d'|' -f1)
fi

# Get snapshot details
SNAPSHOT=$(echo "$SNAPSHOTS" | jq -r ".snapshots[] | select(.id == \"$SNAPSHOT_ID\")")
SNAPSHOT_SIZE=$(echo "$SNAPSHOT" | jq -r '.size_gigabytes')
SNAPSHOT_MIN_DISK=$(echo "$SNAPSHOT" | jq -r '.min_disk_size')
SNAPSHOT_REGION=$(echo "$SNAPSHOT" | jq -r '.regions[0]')
SNAPSHOT_NAME=$(echo "$SNAPSHOT" | jq -r '.name')

echo ""
echo "Selected: $SNAPSHOT_NAME"
echo "Size: ${SNAPSHOT_SIZE}GB (min disk: ${SNAPSHOT_MIN_DISK}GB)"
echo "Region: $SNAPSHOT_REGION"

# Fetch available sizes
echo ""
echo "Fetching droplet sizes..."
SIZES=$(curl -s "https://api.digitalocean.com/v2/sizes" \
  -H "Authorization: Bearer $DO_TOKEN")

# If SIZE_SLUG not set, prompt with selection
if [ -z "$SIZE_SLUG" ]; then
  SIZE_OPTIONS=($(echo "$SIZES" | jq -r --arg region "$SNAPSHOT_REGION" --argjson min_disk "$SNAPSHOT_MIN_DISK" \
    '.sizes[] | select(.available == true) | select(.regions[] == $region) | select(.disk >= $min_disk) | "\(.slug)|\(.vcpus)vCPU|\(.memory)MB|\(.disk)GB|$\(.price_monthly)/mo"' \
    | sort -t'$' -k2 -n))
  
  if [ ${#SIZE_OPTIONS[@]} -eq 0 ]; then
    echo "No compatible droplet sizes found (need >= ${SNAPSHOT_MIN_DISK}GB disk)."
    echo "Your snapshot requires a larger disk than any available droplet size."
    exit 1
  fi
  
  SELECTED=$(select_option "Select droplet size:" "${SIZE_OPTIONS[@]}")
  SIZE_SLUG=$(echo "$SELECTED" | cut -d'|' -f1)
fi

echo "Selected size: $SIZE_SLUG"

# Fetch SSH keys
echo ""
echo "Fetching SSH keys..."
KEYS=$(curl -s "https://api.digitalocean.com/v2/account/keys" \
  -H "Authorization: Bearer $DO_TOKEN")

# If SSH_KEY_ID not set, ask if needed
if [ -z "$SSH_KEY_ID" ]; then
  echo ""
  read -p "Does this droplet require an SSH key? (y/n): " NEED_SSH_KEY
  
  if [ "$NEED_SSH_KEY" = "y" ] || [ "$NEED_SSH_KEY" = "Y" ]; then
    KEY_OPTIONS=($(echo "$KEYS" | jq -r '.ssh_keys[] | "\(.id)|\(.name)"'))
    
    if [ ${#KEY_OPTIONS[@]} -eq 0 ]; then
      echo "No SSH keys found in your account."
      exit 1
    fi
    
    SELECTED=$(select_option "Select SSH key:" "${KEY_OPTIONS[@]}")
    SSH_KEY_ID=$(echo "$SELECTED" | cut -d'|' -f1)
  fi
fi

# Format SSH keys as JSON array (empty array if not set)
if [ -n "$SSH_KEY_ID" ]; then
  SSH_KEYS_JSON=$(echo "$SSH_KEY_ID" | sed 's/,/","/g' | sed 's/^/["/' | sed 's/$/"]/')
  echo "Selected SSH key: $SSH_KEY_ID"
else
  SSH_KEYS_JSON="[]"
  echo "No SSH key selected."
fi

# Ask about reserved IP if not set
if [ -z "$RESERVED_IP" ]; then
  echo ""
  read -p "Assign a reserved IP? (y/n): " NEED_RESERVED_IP
  
  if [ "$NEED_RESERVED_IP" = "y" ] || [ "$NEED_RESERVED_IP" = "Y" ]; then
    echo "Fetching reserved IPs..."
    RESERVED_IPS=$(curl -s "https://api.digitalocean.com/v2/reserved_ips" \
      -H "Authorization: Bearer $DO_TOKEN")
    
    # Filter to unassigned IPs in the same region
    IP_OPTIONS=($(echo "$RESERVED_IPS" | jq -r --arg region "$SNAPSHOT_REGION" \
      '.reserved_ips[] | select(.region.slug == $region) | select(.droplet == null) | "\(.ip)|unassigned|\(.region.slug)"'))
    
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

# Droplet name
if [ -z "$DROPLET_NAME" ]; then
  DEFAULT_NAME="restored-$(echo $SNAPSHOT_NAME | tr ' ' '-' | tr '[:upper:]' '[:lower:]')-$(date +%Y%m%d)"
  read -p "Droplet name [$DEFAULT_NAME]: " DROPLET_NAME
  DROPLET_NAME=${DROPLET_NAME:-$DEFAULT_NAME}
fi

# Confirm
echo ""
echo "========================================"
echo "Creating droplet:"
echo "  Name: $DROPLET_NAME"
echo "  Size: $SIZE_SLUG"
echo "  Region: $SNAPSHOT_REGION"
echo "  Image: $SNAPSHOT_ID ($SNAPSHOT_NAME)"
echo "  SSH Keys: $SSH_KEYS_JSON"
if [ -n "$RESERVED_IP" ]; then
  echo "  Reserved IP: $RESERVED_IP"
fi
echo "========================================"
echo ""
read -p "Proceed? (y/n): " CONFIRM

if [ "$CONFIRM" != "y" ]; then
  echo "Aborted."
  exit 0
fi

# Create droplet
RESPONSE=$(curl -s -X POST "https://api.digitalocean.com/v2/droplets" \
  -H "Authorization: Bearer $DO_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"$DROPLET_NAME\",
    \"region\": \"$SNAPSHOT_REGION\",
    \"size\": \"$SIZE_SLUG\",
    \"image\": \"$SNAPSHOT_ID\",
    \"ssh_keys\": $SSH_KEYS_JSON
  }")

DROPLET_ID=$(echo $RESPONSE | jq -r '.droplet.id')

if [ "$DROPLET_ID" = "null" ] || [ -z "$DROPLET_ID" ]; then
  echo "Failed to create droplet:"
  echo $RESPONSE | jq
  exit 1
fi

echo "Created droplet: $DROPLET_ID"
echo "Waiting for droplet to become active..."

# Poll until active
while true; do
  DROPLET_STATUS=$(curl -s "https://api.digitalocean.com/v2/droplets/$DROPLET_ID" \
    -H "Authorization: Bearer $DO_TOKEN")
  
  STATUS=$(echo $DROPLET_STATUS | jq -r '.droplet.status')
  
  if [ "$STATUS" = "active" ]; then
    IP=$(echo $DROPLET_STATUS | jq -r '.droplet.networks.v4[] | select(.type == "public") | .ip_address')
    echo ""
    echo "Droplet is active!"
    echo "  ID: $DROPLET_ID"
    echo "  IP: $IP"
    break
  fi
  
  echo "  Status: $STATUS..."
  sleep 5
done

# Assign reserved IP if specified
if [ -n "$RESERVED_IP" ]; then
  echo ""
  echo "Assigning reserved IP $RESERVED_IP to droplet..."
  ASSIGN_RESPONSE=$(curl -s -X POST "https://api.digitalocean.com/v2/reserved_ips/$RESERVED_IP/actions" \
    -H "Authorization: Bearer $DO_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"type\": \"assign\", \"droplet_id\": $DROPLET_ID}")
  
  ASSIGN_STATUS=$(echo $ASSIGN_RESPONSE | jq -r '.action.status // .id')
  
  if [ "$ASSIGN_STATUS" = "in-progress" ] || [ "$ASSIGN_STATUS" = "completed" ]; then
    echo "Reserved IP assigned successfully!"
    echo ""
    echo "Connect with: ssh root@$RESERVED_IP"
  else
    echo "Failed to assign reserved IP:"
    echo $ASSIGN_RESPONSE | jq
    echo ""
    echo "Connect with: ssh root@$IP"
  fi
else
  echo ""
  echo "Connect with: ssh root@$IP"
fi
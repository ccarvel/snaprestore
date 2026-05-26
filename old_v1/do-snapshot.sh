#!/bin/bash
set -e

#-----------------------------------------
# CONFIGURATION - Set these or use "list" to fetch
#-----------------------------------------
DO_TOKEN=""           # Required: your DigitalOcean API token
DROPLET_ID=""         # Use "list" to see available droplets
SNAPSHOT_NAME=""      # Optional: defaults to {droplet-name}-snapshot-{date}
#-----------------------------------------

# Check if fzf is available
HAS_FZF=$(command -v fzf >/dev/null 2>&1 && echo "yes" || echo "no")

# Generic selection function: uses fzf if available, falls back to numbered menu
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

# Helper function to list droplets
list_droplets() {
  echo "Fetching droplets..."
  curl -s "https://api.digitalocean.com/v2/droplets" \
    -H "Authorization: Bearer $DO_TOKEN" | jq -r '.droplets[] | "\(.id)  \(.name)  \(.status)  \(.size_slug)  \(.region.slug)  \(.disk)GB disk"'
}

# Check for "list" command
DROPLET_ID_LOWER=$(echo "$DROPLET_ID" | tr '[:upper:]' '[:lower:]')

case "$DROPLET_ID_LOWER" in
  list|get) list_droplets; exit 0 ;;
esac

# Fetch droplets
echo "Fetching droplets..."
DROPLETS=$(curl -s "https://api.digitalocean.com/v2/droplets" \
  -H "Authorization: Bearer $DO_TOKEN")

# If DROPLET_ID not set, prompt with selection
if [ -z "$DROPLET_ID" ]; then
  DROPLET_OPTIONS=($(echo "$DROPLETS" | jq -r '.droplets[] | "\(.id)|\(.name)|\(.status)|\(.size_slug)|\(.region.slug)|\(.disk)GB"'))
  
  if [ ${#DROPLET_OPTIONS[@]} -eq 0 ]; then
    echo "No droplets found."
    exit 1
  fi
  
  SELECTED=$(select_option "Select droplet to snapshot:" "${DROPLET_OPTIONS[@]}")
  DROPLET_ID=$(echo "$SELECTED" | cut -d'|' -f1)
fi

# Get droplet details
DROPLET=$(echo "$DROPLETS" | jq -r ".droplets[] | select(.id == $DROPLET_ID)")
DROPLET_NAME=$(echo "$DROPLET" | jq -r '.name')
DROPLET_STATUS=$(echo "$DROPLET" | jq -r '.status')
DROPLET_SIZE=$(echo "$DROPLET" | jq -r '.size_slug')
DROPLET_REGION=$(echo "$DROPLET" | jq -r '.region.slug')
DROPLET_DISK=$(echo "$DROPLET" | jq -r '.disk')
DROPLET_VCPUS=$(echo "$DROPLET" | jq -r '.vcpus')
DROPLET_MEMORY=$(echo "$DROPLET" | jq -r '.memory')
DROPLET_IP=$(echo "$DROPLET" | jq -r '.networks.v4[] | select(.type == "public") | .ip_address' | head -1)

# Check for reserved IP
echo ""
echo "Checking for reserved IP..."
RESERVED_IPS=$(curl -s "https://api.digitalocean.com/v2/reserved_ips" \
  -H "Authorization: Bearer $DO_TOKEN")
DROPLET_RESERVED_IP=$(echo "$RESERVED_IPS" | jq -r ".reserved_ips[] | select(.droplet.id == $DROPLET_ID) | .ip")

# Display droplet specs
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

# Prompt for snapshot name
if [ -z "$SNAPSHOT_NAME" ]; then
  DEFAULT_SNAPSHOT_NAME="${DROPLET_NAME}-snapshot-$(date +%Y%m%d-%H%M)"
  echo ""
  read -p "Snapshot name [$DEFAULT_SNAPSHOT_NAME]: " SNAPSHOT_NAME
  SNAPSHOT_NAME=${SNAPSHOT_NAME:-$DEFAULT_SNAPSHOT_NAME}
fi

echo ""
echo "Snapshot will be named: $SNAPSHOT_NAME"

# Confirm before proceeding
echo ""
read -p "Proceed with snapshot? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
  echo "Aborted."
  exit 0
fi

# Shutdown droplet if running
if [ "$DROPLET_STATUS" = "active" ]; then
  echo ""
  echo "Shutting down droplet for clean snapshot..."
  
  SHUTDOWN_RESPONSE=$(curl -s -X POST "https://api.digitalocean.com/v2/droplets/$DROPLET_ID/actions" \
    -H "Authorization: Bearer $DO_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"type": "shutdown"}')
  
  SHUTDOWN_ACTION_ID=$(echo $SHUTDOWN_RESPONSE | jq -r '.action.id')
  
  if [ "$SHUTDOWN_ACTION_ID" = "null" ]; then
    echo "Failed to initiate shutdown:"
    echo $SHUTDOWN_RESPONSE | jq
    exit 1
  fi
  
  # Wait for shutdown to complete
  echo "Waiting for shutdown to complete..."
  while true; do
    ACTION_STATUS=$(curl -s "https://api.digitalocean.com/v2/actions/$SHUTDOWN_ACTION_ID" \
      -H "Authorization: Bearer $DO_TOKEN" | jq -r '.action.status')
    
    if [ "$ACTION_STATUS" = "completed" ]; then
      echo "Shutdown complete."
      break
    elif [ "$ACTION_STATUS" = "errored" ]; then
      echo "Shutdown failed. Trying power off..."
      curl -s -X POST "https://api.digitalocean.com/v2/droplets/$DROPLET_ID/actions" \
        -H "Authorization: Bearer $DO_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"type": "power_off"}' > /dev/null
      sleep 10
      break
    fi
    
    echo "  Status: $ACTION_STATUS..."
    sleep 5
  done
else
  echo ""
  echo "Droplet is already off."
fi

# Create snapshot
echo ""
echo "Creating snapshot '$SNAPSHOT_NAME'..."
SNAPSHOT_RESPONSE=$(curl -s -X POST "https://api.digitalocean.com/v2/droplets/$DROPLET_ID/actions" \
  -H "Authorization: Bearer $DO_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"type\": \"snapshot\", \"name\": \"$SNAPSHOT_NAME\"}")

SNAPSHOT_ACTION_ID=$(echo $SNAPSHOT_RESPONSE | jq -r '.action.id')

if [ "$SNAPSHOT_ACTION_ID" = "null" ]; then
  echo "Failed to initiate snapshot:"
  echo $SNAPSHOT_RESPONSE | jq
  exit 1
fi

# Wait for snapshot to complete
echo "Waiting for snapshot to complete (this may take several minutes)..."
while true; do
  ACTION_STATUS=$(curl -s "https://api.digitalocean.com/v2/actions/$SNAPSHOT_ACTION_ID" \
    -H "Authorization: Bearer $DO_TOKEN" | jq -r '.action.status')
  
  if [ "$ACTION_STATUS" = "completed" ]; then
    echo "Snapshot complete!"
    break
  elif [ "$ACTION_STATUS" = "errored" ]; then
    echo "Snapshot failed!"
    exit 1
  fi
  
  echo "  Status: $ACTION_STATUS..."
  sleep 10
done

# Get the new snapshot ID
echo ""
echo "Fetching snapshot details..."
NEW_SNAPSHOTS=$(curl -s "https://api.digitalocean.com/v2/snapshots?resource_type=droplet" \
  -H "Authorization: Bearer $DO_TOKEN")
NEW_SNAPSHOT=$(echo "$NEW_SNAPSHOTS" | jq -r ".snapshots[] | select(.name == \"$SNAPSHOT_NAME\")")
NEW_SNAPSHOT_ID=$(echo "$NEW_SNAPSHOT" | jq -r '.id')
NEW_SNAPSHOT_SIZE=$(echo "$NEW_SNAPSHOT" | jq -r '.size_gigabytes')
NEW_SNAPSHOT_MIN_DISK=$(echo "$NEW_SNAPSHOT" | jq -r '.min_disk_size')

echo ""
echo "========================================"
echo "Snapshot Created Successfully"
echo "========================================"
echo "  ID: $NEW_SNAPSHOT_ID"
echo "  Name: $SNAPSHOT_NAME"
echo "  Size: ${NEW_SNAPSHOT_SIZE}GB"
echo "  Min Disk: ${NEW_SNAPSHOT_MIN_DISK}GB"
echo "========================================"

# Ask what to do with the droplet
echo ""
echo "What would you like to do with the droplet?"
POST_OPTIONS=("start|Start it back up" "leave|Leave it shut down" "delete|Delete/destroy it")
SELECTED=$(select_option "Select action:" "${POST_OPTIONS[@]}")
POST_ACTION=$(echo "$SELECTED" | cut -d'|' -f1)

case "$POST_ACTION" in
  start)
    echo ""
    echo "Starting droplet..."
    curl -s -X POST "https://api.digitalocean.com/v2/droplets/$DROPLET_ID/actions" \
      -H "Authorization: Bearer $DO_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"type": "power_on"}' > /dev/null
    
    echo "Waiting for droplet to become active..."
    while true; do
      STATUS=$(curl -s "https://api.digitalocean.com/v2/droplets/$DROPLET_ID" \
        -H "Authorization: Bearer $DO_TOKEN" | jq -r '.droplet.status')
      
      if [ "$STATUS" = "active" ]; then
        echo "Droplet is active!"
        if [ -n "$DROPLET_RESERVED_IP" ]; then
          echo "Connect with: ssh root@$DROPLET_RESERVED_IP"
        else
          echo "Connect with: ssh root@$DROPLET_IP"
        fi
        break
      fi
      
      echo "  Status: $STATUS..."
      sleep 5
    done
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
    read -p "Are you sure you want to DELETE droplet '$DROPLET_NAME'? This cannot be undone. (yes/no): " DELETE_CONFIRM
    
    if [ "$DELETE_CONFIRM" = "yes" ]; then
      echo "Deleting droplet..."
      DELETE_RESPONSE=$(curl -s -X DELETE "https://api.digitalocean.com/v2/droplets/$DROPLET_ID" \
        -H "Authorization: Bearer $DO_TOKEN" \
        -w "%{http_code}")
      
      if [ "$DELETE_RESPONSE" = "204" ]; then
        echo "Droplet deleted successfully."
        echo ""
        echo "Your snapshot '$SNAPSHOT_NAME' (ID: $NEW_SNAPSHOT_ID) is preserved."
        echo "Use do-restore.sh to restore from this snapshot later."
      else
        echo "Failed to delete droplet. HTTP status: $DELETE_RESPONSE"
      fi
    else
      echo "Deletion cancelled. Droplet left shut down."
    fi
    ;;
esac

echo ""
echo "Done!"
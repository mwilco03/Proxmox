#!/bin/bash
#
# Interactive script to configure a host-wide CephFS mount and update selected
# LXC containers in Proxmox to bind-mount that CephFS share.
# This script requires you've already configured your CephFS
# But from that it will connect a CephFS to each of the LXC containers you choose
#
#
# Enhancements in this version:
#   - Validates that an active CephFS Metadata Server (MDS) is available.
#   - Uses the keyring from /etc/pve/priv/ceph.client.admin.keyring.
#   - Extracts the secret using an awk-based command.
#   - Optionally echoes each command before executing it (via -v for verbose mode).
#   - Uses whiptail for container selection.
#   - Uses colored output: blue for informational messages and yellow for xtrace (when verbose).
#   - The container mount point default is now "/cephs".
#
# IMPORTANT: Run this script as root on each Proxmox node.
#

set -e

##########################
# Process command-line arguments for verbose mode (-v)
##########################
VERBOSE=0
if [ "$1" == "-v" ]; then
    VERBOSE=1
    shift
fi

##########################
# Color Definitions
##########################
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
RESET="\033[0m"

# If verbose mode is enabled, set PS4 to print in yellow and enable xtrace.
if [ "$VERBOSE" -eq 1 ]; then
    export PS4="${YELLOW}+ ${RESET}"
    set -x
fi

##########################
# Utility Functions
##########################
# Prompt with a default value.
prompt_default() {
    local prompt_msg="$1"
    local default_val="$2"
    read -p "$prompt_msg [$default_val]: " user_input
    if [ -z "$user_input" ]; then
        echo "$default_val"
    else
        echo "$user_input"
    fi
}

# Pause with a message.
pause() {
    read -p "$1"
}

# Info function for printing messages in blue.
info() {
    echo -e "${BLUE}$*${RESET}"
}

##########################
# Step 0: Check for Root
##########################
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${BLUE}Error: This script must be run as root.${RESET}" >&2
    exit 1
fi

##########################
# Step 1: Retrieve Ceph Monitors
##########################
info "==> Attempting to retrieve Ceph monitor addresses from /etc/pve/ceph.conf..."
MONITORS=""
if [ -f /etc/pve/ceph.conf ]; then
    # Look for a non-commented mon_host line.
    MON_LINE=$(grep -E "^\s*mon_host\s*=" /etc/pve/ceph.conf | head -n 1 | cut -d"=" -f2 | cut -d" " -f2-)
    if [ -n "$MON_LINE" ]; then
        MONITORS=$(echo "$MON_LINE")
        info "Found monitors: $MONITORS"
    else
        info "No 'mon_host' line found in /etc/pve/ceph.conf."
    fi
else
    info "/etc/pve/ceph.conf not found."
fi

# If monitors could not be programmatically retrieved, prompt the user.
if [ -z "$MONITORS" ]; then
    info "Unable to programmatically retrieve Ceph monitors."
    read -p "Please enter a comma-separated list of Ceph monitor addresses: " MONITORS
fi

##########################
# Step 2: Retrieve Ceph Client Name and Secret
##########################
KEYRING="/etc/pve/priv/ceph.client.admin.keyring"
CEPH_NAME=""
CEPH_SECRET=""
if [ -f "$KEYRING" ]; then
    info "==> Attempting to retrieve Ceph client credentials from $KEYRING..."
    CEPH_SECRET=$(grep -i 'key' "${KEYRING}" | head -n1 | awk '{print $3}' | tr -d ' \n')
    if [ -n "$CEPH_SECRET" ]; then
        CEPH_NAME="admin"
        info "Retrieved Ceph client: admin"
    else
        info "Unable to extract secret from $KEYRING."
    fi
else
    info "$KEYRING not found."
fi

# If secret is still empty, prompt the user.
if [ -z "$CEPH_SECRET" ]; then
    CEPH_NAME=$(prompt_default "Enter Ceph client name" "admin")
    read -s -p "Enter Ceph secret for client '$CEPH_NAME': " CEPH_SECRET
    echo ""
fi

##########################
# Step 3: Prompt for Mount Points
##########################
HOST_MOUNT=$(prompt_default "Enter host CephFS mount point" "/mnt/cephfs")
CONTAINER_MOUNT=$(prompt_default "Enter mount point inside containers" "/mnt/cephfs")

##########################
# Step 4: Check/Install ceph-common
##########################
info "==> Checking for ceph-common package..."
if ! dpkg -l | grep -qw ceph-common; then
    info "ceph-common package not found. Installing..."
    apt-get update && apt-get install -y ceph-common
else
    info "ceph-common is installed."
fi

##########################
# Step 5: Create Host Mount Point
##########################
if [ ! -d "$HOST_MOUNT" ]; then
    info "Creating host mount point directory: $HOST_MOUNT"
    mkdir -p "$HOST_MOUNT"
else
    info "Host mount point directory $HOST_MOUNT already exists."
fi

##########################
# Step 6: Validate Active CephFS Metadata Server (MDS)
##########################
info "==> Checking for active CephFS Metadata Server (MDS)..."
MDS_STATUS=$(ceph mds stat 2>/dev/null || true)
if [ -z "$MDS_STATUS" ]; then
    echo -e "${BLUE}Error: Could not retrieve MDS status. Check your Ceph cluster configuration.${RESET}" >&2
    exit 1
fi
if ! echo "$MDS_STATUS" | grep -q "up:active"; then
    echo -e "${BLUE}Error: No active metadata server (MDS) found. Please ensure that at least one MDS is up before mounting CephFS.${RESET}" >&2
    exit 1
fi
info "Active MDS found: $MDS_STATUS"

##########################
# Step 7: Mount CephFS on the Host
##########################
CEPH_OPTS="name=${CEPH_NAME},secret=${CEPH_SECRET}"
info "==> Checking if CephFS is already mounted on $HOST_MOUNT..."
if mountpoint -q "$HOST_MOUNT"; then
    info "CephFS already mounted at $HOST_MOUNT"
else
    info "Mounting CephFS at $HOST_MOUNT..."
    mount -t ceph "${MONITORS}:/" "$HOST_MOUNT" -o "$CEPH_OPTS"
fi

if mountpoint -q "$HOST_MOUNT"; then
    info "CephFS is successfully mounted at $HOST_MOUNT"
else
    echo -e "${BLUE}Error: Failed to mount CephFS at $HOST_MOUNT${RESET}" >&2
    exit 1
fi

##########################
# Step 8: Update /etc/fstab
##########################
info "==> Verifying /etc/fstab for an entry for $HOST_MOUNT..."
if grep -Fq "$HOST_MOUNT" /etc/fstab; then
    info "An fstab entry for $HOST_MOUNT already exists."
else
    info "Adding CephFS entry to /etc/fstab..."
    echo "${MONITORS}:/  ${HOST_MOUNT}  ceph  ${CEPH_OPTS}  0  0" >> /etc/fstab
fi

##########################
# Step 9: List and Select Containers (using whiptail)
##########################
if ! command -v whiptail >/dev/null 2>&1; then
    echo -e "${BLUE}Error: whiptail is not installed. Please install whiptail to continue.${RESET}" >&2
    exit 1
fi

info "==> Listing available LXC containers..."
CONTAINER_LIST=$(pct list | tail -n +2)
if [ -z "$CONTAINER_LIST" ]; then
    info "No LXC containers found. Exiting."
    exit 0
fi

# Build whiptail checklist options.
OPTIONS=()
while read -r line; do
    # Expected pct list output format: VMID STATUS IP NAME ...
    vmid=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $4}')
    OPTIONS+=("$vmid" "$name" "OFF")
done <<< "$CONTAINER_LIST"

WHIPTAIL_RESULT=$(whiptail --title "Select Containers" --checklist "Choose containers to update:" 20 78 15 "${OPTIONS[@]}" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then
    info "No container selected. Exiting."
    exit 0
fi

# Parse the whiptail output (returns a quoted, space-separated list).
SELECTED_CONTAINERS=()
for vm in $WHIPTAIL_RESULT; do
    vm=$(echo "$vm" | sed 's/"//g')
    SELECTED_CONTAINERS+=("$vm")
done

info "Selected containers: ${SELECTED_CONTAINERS[@]}"

##########################
# Step 10: Update Each Container's Configuration
##########################
for vmid in "${SELECTED_CONTAINERS[@]}"; do
    info "------------------------------"
    info "Processing container VMID: $vmid"
    # Check if the container config already has our mount.
    if pct config "$vmid" | grep -q "$CONTAINER_MOUNT"; then
        info "Container $vmid already has a mount for $CONTAINER_MOUNT. Skipping."
        continue
    fi

    # Determine the next available mount slot (mp0, mp1, mp2, …)
    mount_slot=0
    while pct config "$vmid" | grep -q "^mp${mount_slot}:"; do
        mount_slot=$((mount_slot + 1))
    done

    info "Adding bind mount (slot mp${mount_slot}) to container $vmid..."
    pct set "$vmid" --mp${mount_slot} "${HOST_MOUNT},mp=${CONTAINER_MOUNT}"
    info "Container $vmid updated: CephFS will be available at ${CONTAINER_MOUNT} inside the container."
done

info "------------------------------"
info "All selected containers have been processed."
info "Note: If any container was running, a restart may be necessary to pick up the new mount."
pause "Press [Enter] to finish..."

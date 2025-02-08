#!/bin/bash
#
# Boilerplate script to execute a code block on all selected LXC containers.
#
# Enhancements in this version:
#   - Optional verbose mode (-v) for debugging (xtrace output in yellow).
#   - Informational messages printed in blue.
#   - Container selection via whiptail checklist.
#   - Executes a provided code block on each selected container.
#
# IMPORTANT: Run this script as root on your Proxmox host.
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
# info() prints messages in blue.
info() {
    echo -e "${BLUE}$*${RESET}"
}

# pause() waits for user input.
pause() {
    read -p "$1"
}

##########################
# Check for Root
##########################
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${BLUE}Error: This script must be run as root.${RESET}" >&2
    exit 1
fi

##########################
# Define the Code Block to Execute
##########################
# Modify the code block below as needed. It is executed in each container.
CODE_BLOCK=$(cat <<'EOF'
# Begin Code Block
echo "Hello from container $(hostname)"
# Add more commands below
# End Code Block
EOF
)

##########################
# Step 1: List and Select Containers (using whiptail)
##########################
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

WHIPTAIL_RESULT=$(whiptail --title "Select Containers" --checklist "Choose containers to execute the code block:" 20 78 15 "${OPTIONS[@]}" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then
    info "No container selected. Exiting."
    exit 0
fi

# Parse whiptail output (which returns a quoted, space-separated list).
SELECTED_CONTAINERS=()
for vm in $WHIPTAIL_RESULT; do
    # Remove any surrounding quotes.
    vm=$(echo "$vm" | sed 's/"//g')
    SELECTED_CONTAINERS+=("$vm")
done

info "Selected containers: ${SELECTED_CONTAINERS[@]}"

##########################
# Step 2: Execute the Code Block in Each Container
##########################
for vmid in "${SELECTED_CONTAINERS[@]}"; do
    info "--------------------------------"
    info "Executing code block on container VMID: $vmid"
    # Execute the provided code block inside the container.
    # Note: If your code block is multi-line, ensure it is properly quoted.
    pct exec "$vmid" -- bash -c "$(printf '%s' "$CODE_BLOCK")"
done

info "--------------------------------"
info "Code block execution completed on selected containers."
pause "Press [Enter] to finish..."

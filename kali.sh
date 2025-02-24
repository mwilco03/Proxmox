#!/usr/bin/env bash
# =============================================================================
# Kali LXC Container Creator for Proxmox VE Helper Scripts
# This script automatically retrieves the Kali squashfs image, converts it
# to a tar.xz template, and then builds an unprivileged container with:
#   • 2 CPU cores
#   • 2048 MiB RAM
#   • 20 GiB Disk
#
# For full Kali installation inside the container, log in and run:
#   apt update && apt upgrade -y && apt install -y kali-linux-default kali-desktop-xfce
#
# © 2021-2025 tteck / community-scripts contributors | License: MIT
# =============================================================================

# Set variables specific to Kali
APP="Kali"
var_tags="kali"
var_cpu="2"
var_ram="2048"
var_disk="20"
var_os="kali"
var_version="rolling"
var_unprivileged="1"

# URL for the Kali squashfs image and expected SHA256 checksum
KALI_SQUASHFS_URL="https://images.lxd.canonical.com/images/kali/current/amd64/default/rootfs.squashfs"
KALI_SQUASHFS_CHECKSUM="cd5a961fc89ee197e40edb69cad3c8246243339307d20ab130e8a6e5ed5cf424"

# Destination template file path on your Proxmox host
TEMPLATE_PATH="/var/lib/vz/template/cache/2024-12-25-Kali-rootfs.tar.xz"

# =============================================================================
# Source common functions (error handling, colors, container build routines, etc.)
# =============================================================================
source <(curl -s https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# =============================================================================
# Function: retrieve_kali_image
# Downloads the squashfs image, verifies its checksum, converts it to tar.xz,
# and saves it to the CT templates directory.
# =============================================================================
retrieve_kali_image() {
  if [[ -f "$TEMPLATE_PATH" ]]; then
    msg_ok "Kali image template already exists at $TEMPLATE_PATH"
    return 0
  fi

  msg_info "Downloading Kali squashfs image..."
  curl -L "$KALI_SQUASHFS_URL" -o /tmp/rootfs.squashfs || { 
    msg_error "Failed to download squashfs image"; exit 1; 
  }

  # Verify checksum
  DOWNLOADED_CHECKSUM=$(sha256sum /tmp/rootfs.squashfs | awk '{print $1}')
  if [[ "$DOWNLOADED_CHECKSUM" != "$KALI_SQUASHFS_CHECKSUM" ]]; then
    msg_error "Checksum verification failed for squashfs image"
    exit 1
  fi
  msg_ok "Downloaded and verified squashfs image"

  msg_info "Converting squashfs image to tar.xz..."
  # Ensure sqfs2tar is installed
  if ! command -v sqfs2tar &> /dev/null; then
    msg_error "sqfs2tar not found, please install squashfs-tools-ng"
    exit 1
  fi

  sqfs2tar /tmp/rootfs.squashfs | xz > "$TEMPLATE_PATH" || { 
    msg_error "Conversion failed"; exit 1; 
  }
  msg_ok "Conversion successful: $TEMPLATE_PATH"
  rm -f /tmp/rootfs.squashfs
}

# Retrieve the Kali image template if needed
retrieve_kali_image

# =============================================================================
# (Optional) Update script function – for updating an existing container
# =============================================================================
function update_script() {
  header_info "Updating $APP LXC"
  check_container_storage
  check_container_resources
  if [[ ! -d /var ]]; then 
    msg_error "No ${APP} Installation Found!"; exit 1; 
  fi
  msg_info "Updating $APP LXC"
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "Updated $APP LXC"
  exit 0
}

# Begin container creation process using the common functions from build.func
header_info "$APP"
variables
color
catch_errors

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "\n${INFO} To complete your Kali installation, log into the container and run:"
echo -e "  apt update && apt upgrade -y && apt install -y kali-linux-default kali-desktop-xfce\n"

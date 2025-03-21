#!/usr/bin/env bash
# Copyright (c) 2021-2025 tteck
# Original Author: tteck (tteckster)
# Modified by: Quix & ChatGPT
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

set -e

function header_info() {
  clear
  cat <<"EOF"
  ______      _ __                __
 /_  __/___ _(_) /_____________ _/ /__
  / / / __ `/ / / ___/ ___/ __ `/ / _ \
 / / / /_/ / / (__  ) /__/ /_/ / /  __/
 /_/  \__,_/_/_/____/\___/\__,_/_/\___/
EOF
}

function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}

# Initial header and confirmation prompt.
header_info
while true; do
  read -rp "This will add Tailscale to an existing LXC Container ONLY. Proceed (y/n)? " yn
  case "${yn}" in
    [Yy]*) break ;;
    [Nn]*) exit ;;
    *) echo "Please answer yes or no." ;;
  esac
done

header_info
echo "Loading..."

# Build menu array for whiptail selection.
MSG_MAX_LENGTH=0
CTID_MENU=()
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  ITEM=$(echo "$line" | awk '{print substr($0,36)}')
  local_offset=2
  if (( ${#ITEM} + local_offset > MSG_MAX_LENGTH )); then
    MSG_MAX_LENGTH=$(( ${#ITEM} + local_offset ))
  fi
  CTID_MENU+=("$TAG" "$ITEM " "OFF")
done < <(pct list | awk 'NR>1')

# Prompt for container selection.
while [ -z "${CTID:-}" ]; do
  CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "Containers on $(hostname)" \
    --radiolist "\nSelect a container to add Tailscale to:\n" \
    16 $((MSG_MAX_LENGTH + 23)) 6 \
    "${CTID_MENU[@]}" 3>&1 1>&2 2>&3) || exit
done

# Update container configuration.
CTID_CONFIG_PATH="/etc/pve/lxc/${CTID}.conf"
cat <<EOF >>"${CTID_CONFIG_PATH}"
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF

header_info
msg "Installing Tailscale..."

# Function to enable and start a systemd service.
function enable_and_start_service() {
  local service_name="$1"
  if systemctl status "${service_name}.service" &>/dev/null; then
      systemctl enable "${service_name}"
      systemctl start "${service_name}"
  fi
}

# Execute Tailscale installation inside the container.
pct exec "$CTID" -- bash -c '
set -e
if command -v apt-get >/dev/null 2>&1; then
  # Debian/Ubuntu installation
  ID=$(grep "^ID=" /etc/os-release | cut -d"=" -f2)
  VER=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d"=" -f2)
  wget -qO- "https://pkgs.tailscale.com/stable/${ID}/${VER}.noarmor.gpg" > /usr/share/keyrings/tailscale-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${ID} ${VER} main" > /etc/apt/sources.list.d/tailscale.list
  apt-get update &>/dev/null
  apt-get install -y tailscale &>/dev/null
  enable_and_start_service tailscaled || enable_and_start_service tailscale
elif command -v dnf >/dev/null 2>&1; then
  # Fedora/CentOS installation
  curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo | tee /etc/yum.repos.d/tailscale.repo
  dnf install -y tailscale &>/dev/null
  enable_and_start_service tailscaled || enable_and_start_service tailscale
elif command -v apk >/dev/null 2>&1; then
  # Alpine installation
  apk update &>/dev/null
  apk add tailscale &>/dev/null
  if [ -f /etc/init.d/tailscaled ]; then
      rc-update add tailscaled default
      rc-service tailscaled start
  elif [ -f /etc/init.d/tailscale ]; then
      rc-update add tailscale default
      rc-service tailscale start
  else
      echo "Tailscale init script not found. Aborting."
      exit 1
  fi
else
  echo "Unsupported package manager. Aborting."
  exit 1
fi
' || exit

# Update tags for the container.
TAGS=$(awk -F': ' '/^tags:/ {print $2}' "/etc/pve/lxc/${CTID}.conf")
TAGS="${TAGS:+$TAGS; }tailscale"
pct set "$CTID" -tags "${TAGS}"

msg "\e[1;32m✔ Installed Tailscale\e[0m"
msg "\e[1;31mReboot the ${CTID} LXC to apply the changes, then run 'tailscale up' in the LXC console\e[0m"

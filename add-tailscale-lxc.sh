#!/usr/bin/env bash 
# Copyright (c) 2021-2025 tteck
# Original Author: tteck (tteckster)
# Modified by: Quix & ChatGPT
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

function header_info {
  clear
  cat <<"EOF"
  ______      _ __                __
 /_  __/___ _(_) /_____________ _/ /__
  / / / __ `/ / / ___/ ___/ __ `/ / _ \
 / / / /_/ / / (__  ) /__/ /_/ / /  __/
 /_/  \__,_/_/_/____/\___/\__,_/_/\___/

EOF
}
header_info
set -e
while true; do
  read -p "This will add Tailscale to an existing LXC Container ONLY. Proceed (y/n)? " yn
  case $yn in
    [Yy]*) break ;;
    [Nn]*) exit ;;
    *) echo "Please answer yes or no." ;;
  esac
done
header_info
echo "Loading..."
function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}

NODE=$(hostname)
MSG_MAX_LENGTH=0
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  ITEM=$(echo "$line" | awk '{print substr($0,36)}')
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  CTID_MENU+=("$TAG" "$ITEM " "OFF")
done < <(pct list | awk 'NR>1')

while [ -z "${CTID:+x}" ]; do
  CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Containers on $NODE" --radiolist \
    "\nSelect a container to add Tailscale to:\n" \
    16 $(($MSG_MAX_LENGTH + 23)) 6 \
    "${CTID_MENU[@]}" 3>&1 1>&2 2>&3) || exit
done

CTID_CONFIG_PATH=/etc/pve/lxc/${CTID}.conf
cat <<EOF >>$CTID_CONFIG_PATH
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
header_info
msg "Installing Tailscale..."
pct exec "$CTID" -- bash -c '
if command -v apt-get >/dev/null 2>&1; then
  # Debian/Ubuntu installation
  ID=$(grep "^ID=" /etc/os-release | cut -d"=" -f2)
  VER=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d"=" -f2)
  wget -qO- https://pkgs.tailscale.com/stable/$ID/$VER.noarmor.gpg >/usr/share/keyrings/tailscale-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/$ID $VER main" >/etc/apt/sources.list.d/tailscale.list
  apt-get update &>/dev/null
  apt-get install -y tailscale &>/dev/null
  # Check for either tailscaled or tailscale systemd service.
  if systemctl status tailscaled.service &>/dev/null; then
      systemctl enable tailscaled
      systemctl start tailscaled
  elif systemctl status tailscale.service &>/dev/null; then
      systemctl enable tailscale
      systemctl start tailscale
  fi
elif command -v dnf >/dev/null 2>&1; then
  # Fedora/CentOS installation
  curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo | tee /etc/yum.repos.d/tailscale.repo
  dnf install -y tailscale &>/dev/null
  # Check for either tailscaled or tailscale systemd service.
  if systemctl status tailscaled.service &>/dev/null; then
      systemctl enable tailscaled
      systemctl start tailscaled
  elif systemctl status tailscale.service &>/dev/null; then
      systemctl enable tailscale
      systemctl start tailscale
  fi
elif command -v apk >/dev/null 2>&1; then
  # Alpine installation
  apk update &>/dev/null
  apk add tailscale &>/dev/null
  # Check for OpenRC init script for tailscaled or tailscale.
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
TAGS=$(awk -F': ' '/^tags:/ {print $2}' /etc/pve/lxc/${CTID}.conf)
TAGS="${TAGS:+$TAGS; }tailscale"
pct set "$CTID" -tags "${TAGS}"
msg "\e[1;32m ✔ Installed Tailscale\e[0m"

msg "\e[1;31m Reboot ${CTID} LXC to apply the changes, then run 'tailscale up' in the LXC console\e[0m"

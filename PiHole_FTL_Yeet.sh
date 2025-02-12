#!/bin/bash
#🔹 What This Script Does
#✅ Installs Caddy if not already installed.
#✅ Extracts all local DNS hostnames from Pi-hole's database.
#✅ Correctly assigns ports for services.
#✅ Generates a Caddyfile dynamically.
#✅ Updates dnsmasq local DNS records (/etc/dnsmasq.d/10-local.conf).
#✅ Adds a custom Pi-hole DNS entry (/etc/pihole/custom.list).
#✅ Restarts Pi-hole DNS and Caddy to apply changes.
# Define paths
FTL_DB="/etc/pihole/pihole-FTL.db"
CADDYFILE="/etc/caddy/Caddyfile"
DNSMASQ_CONF="/etc/dnsmasq.d/10-local.conf"
PIHOLE_CUSTOM_LIST="/etc/pihole/custom.list"
PIHOLE_IP="192.168.5.49"  # Update this with your Pi-hole’s IP

# Function to install Caddy
install_caddy() {
    echo "Checking if Caddy is installed..."
    if ! command -v caddy &>/dev/null; then
        echo "Installing Caddy..."
        apt update && apt install -y caddy sqlite3
    else
        echo "Caddy is already installed."
    fi
}

# Function to query Pi-hole FTL database
query_pihole_db() {
    echo "Querying Pi-hole FTL database for local domains..."
    sqlite3 "$FTL_DB" "SELECT ip, hostname FROM client_by_id" | grep -E '[a-z]' > /tmp/ftl_clients.txt
}

# Function to map correct ports
map_ports() {
    case "$1" in
        pve1.local) echo "8006" ;;
        pve2.local) echo "8006" ;;
        pve3.local) echo "8006" ;;
        pihole.local) echo "80" ;;
        plex.local) echo "32400" ;;
        plexlxc.local) echo "32400" ;;
        qbittorrent.local) echo "8090" ;;
        prowlarr.local) echo "9696" ;;
        sabnzbd.local) echo "7777" ;;
        radarr.local) echo "7878" ;;
        sonarr.local) echo "8989" ;;
        requests.local) echo "7777" ;;
        petio.local) echo "7777" ;;
        wastebin.local) echo "8088" ;;
        pastebin.local) echo "8088" ;;
        nextcloud.local) echo "80" ;;
        docker.local) echo "2375" ;;
        *) echo "80" ;; # Default port if not specified
    esac
}

# Function to generate Caddyfile
generate_caddyfile() {
    echo "Generating Caddyfile..."
    
    # Start with the global Caddy settings
    echo "{ auto_https disable }" > "$CADDYFILE"
    echo "" >> "$CADDYFILE"

    # Initialize DNS config files
    echo "# Local DNS Configuration for dnsmasq" > "$DNSMASQ_CONF"
    echo "# Custom local DNS records for Pi-hole" > "$PIHOLE_CUSTOM_LIST"

    # Read the Pi-hole FTL results and create configurations
    while IFS="|" read -r ip hostname; do
        # Skip localhost
        if [[ "$hostname" == "localhost" ]]; then
            continue
        fi

        # Get the correct port for this service
        port=$(map_ports "$hostname")

        # Define the Caddy reverse proxy entry
        echo "$hostname {" >> "$CADDYFILE"
        echo "    reverse_proxy http://$ip:$port" >> "$CADDYFILE"

        # Special handling for services with unique paths
        if [[ "$hostname" == "plex.local" || "$hostname" == "plexlxc.local" ]]; then
            echo "    @plex path /web*" >> "$CADDYFILE"
            echo "    rewrite @plex /web{path}" >> "$CADDYFILE"
        fi

        if [[ "$hostname" == "pihole.local" ]]; then
            echo "    reverse_proxy http://$ip:$port/admin" >> "$CADDYFILE"
        fi

        echo "}" >> "$CADDYFILE"
        echo "" >> "$CADDYFILE"

        # Add local DNS records to dnsmasq configuration
        echo "address=/$hostname/$ip" >> "$DNSMASQ_CONF"

    done < /tmp/ftl_clients.txt

    # Add Pi-hole’s own DNS entry to /etc/pihole/custom.list
    echo "$PIHOLE_IP pihole.local" >> "$PIHOLE_CUSTOM_LIST"
}

# Function to restart services
restart_services() {
    echo "Restarting Pi-hole DNS and Caddy..."
    systemctl restart pihole-FTL
    systemctl restart caddy
}

# Main script execution
install_caddy
query_pihole_db
generate_caddyfile
restart_services

echo "✅ Setup complete! Caddy and Pi-hole DNS are now configured."

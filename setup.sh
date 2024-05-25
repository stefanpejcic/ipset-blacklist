#!/bin/bash

CONFIG_FILE="/etc/openpanel/ufw/blacklists.conf"

set_api_key() {
    local new_api_key="$1"
    local temp_file=$(mktemp)

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file $CONFIG_FILE does not exist."
        return 1
    fi

    if grep -q "^#abuseipdb|" "$CONFIG_FILE"; then
        sed "s|^#abuseipdb|https://api.abuseipdb.com/api/v2/blacklist|.*$|abuseipdb|https://api.abuseipdb.com/api/v2/blacklist|$new_api_key|" "$CONFIG_FILE" > "$temp_file"
    elif grep -q "^abuseipdb|" "$CONFIG_FILE"; then
        sed "s|^abuseipdb|https://api.abuseipdb.com/api/v2/blacklist|.*$|abuseipdb|https://api.abuseipdb.com/api/v2/blacklist|$new_api_key|" "$CONFIG_FILE" > "$temp_file"
    else
        echo "abuseipdb|https://api.abuseipdb.com/api/v2/blacklist|$new_api_key" >> "$CONFIG_FILE"
    fi

    mv "$temp_file" "$CONFIG_FILE"
    echo "API key for AbuseIPDB is saved in $CONFIG_FILE"
}

# set configuration
mkdir -p /etc/openpanel/ufw/
cp configuration/blacklists.conf /etc/openpanel/ufw/blacklists.conf
touch /etc/openpanel/ufw/exclude.list

# main file
cp ipset-blacklist.sh /usr/ipset-blacklist.sh
chmod +x /usr/ipset-blacklist.sh

# set service
cp service/ipset-blacklist.service /etc/systemd/system/ipset-blacklist.service
cp service/ipset-blacklist.timer /etc/systemd/system/ipset-blacklist.timer
systemctl daemon-reload
systemctl enable ipset-blacklist.timer
systemctl start ipset-blacklist.timer

# Process flag if present
if [[ "$1" == "--abuseipdb-key="* ]]; then
    API_KEY="${1#*=}"
    set_api_key "$API_KEY"
fi

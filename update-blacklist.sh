#!/bin/bash

CONFIG_DIR="/etc/openpanel/ufw"
BLACKLIST_CONF="${CONFIG_DIR}/blacklists.conf"
EXCLUDE_FILE="${CONFIG_DIR}/exclude.list"

fetch_abuseipdb() {
    API_KEY=$1
    OUTPUT_FILE=$2
    echo "Fetching IPs from AbuseIPDB..."
    response=$(curl -s -G https://api.abuseipdb.com/api/v2/blacklist --data-urlencode "confidenceMinimum=90" -H "Key: ${API_KEY}" -H "Accept: application/json")
    if [ $? -ne 0 ]; then
        echo "Error fetching IPs"
        exit 1
    fi
    echo $response | jq -r '.data[].ipAddress' > $OUTPUT_FILE
    echo "IPs fetched and saved to $OUTPUT_FILE"
}

fetch_generic_blacklist() {
    URL=$1
    OUTPUT_FILE=$2
    echo "Fetching IPs from $URL..."
    curl -s $URL -o $OUTPUT_FILE
    if [ $? -ne 0 ]; then
        echo "Error fetching IPs from $URL"
        exit 1
    fi
    echo "IPs fetched and saved to $OUTPUT_FILE"
}

update_ipset() {
    IPSET_NAME=$1
    IP_FILE=$2

    echo "Updating IP set $IPSET_NAME..."
    # Create the IP set if it doesn't exist
    ipset list $IPSET_NAME > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        ipset create $IPSET_NAME hash:ip
    fi

    # Flush the IP set to remove old entries
    ipset flush $IPSET_NAME

    # Read exclusion list if it exists
    if [ -f $EXCLUDE_FILE ]; then
        mapfile -t exclude_ips < $EXCLUDE_FILE
    else
        exclude_ips=()
    fi

    # Add new IPs to the IP set, skipping excluded IPs
    while IFS= read -r ip; do
        if [[ ! " ${exclude_ips[@]} " =~ " ${ip} " ]]; then
            ipset add $IPSET_NAME $ip
        else
            echo "Excluding IP: $ip"
        fi
    done < $IP_FILE

    # Save the IP set
    ipset save > /etc/ipset.conf
    echo "IP set $IPSET_NAME updated"
}

update_ufw() {
    echo "Updating UFW rules..."
    for IPSET_NAME in $(ipset list -name); do
        iptables -C INPUT -m set --match-set $IPSET_NAME src -j LOG --log-prefix "Blocklist $IPSET_NAME: " > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            iptables -I INPUT -m set --match-set $IPSET_NAME src -j LOG --log-prefix "Blocklist $IPSET_NAME: "
            iptables -I INPUT -m set --match-set $IPSET_NAME src -j DROP
            echo "iptables -I INPUT -m set --match-set $IPSET_NAME src -j LOG --log-prefix 'Blocklist $IPSET_NAME: '" >> /etc/ufw/before.rules
            echo "iptables -I INPUT -m set --match-set $IPSET_NAME src -j DROP" >> /etc/ufw/before.rules
        fi
    done

    # Restart UFW to apply the changes
    ufw reload
    echo "UFW updated"
}

set_api_key() {
    mkdir -p $CONFIG_DIR
    echo "$1" > ${CONFIG_DIR}/abuseipdb.key
    chmod 600 ${CONFIG_DIR}/abuseipdb.key
    echo "API key saved to ${CONFIG_DIR}/abuseipdb.key"
}

process_blacklists() {
    if [ ! -f $BLACKLIST_CONF ]; then
        echo "Blacklist configuration file not found: $BLACKLIST_CONF"
        exit 1
    fi

    while IFS= read -r line; do
        # Skip commented or empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue

        IFS='|' read -r name url api_key <<< "$line"
        IP_FILE="${CONFIG_DIR}/${name}_ips.txt"
        IPSET_NAME="${name}_ipset"

        if [[ "$name" == "abuseipdb" ]]; then
            fetch_abuseipdb $api_key $IP_FILE
        else
            fetch_generic_blacklist $url $IP_FILE
        fi

        update_ipset $IPSET_NAME $IP_FILE
    done < $BLACKLIST_CONF
}

usage() {
    echo "Usage: $0 {--fetch|--update_ufw|--api-key=API_KEY}"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

case "$1" in
    --fetch)
        process_blacklists
        ;;
    --update_ufw)
        update_ufw
        ;;
    --api-key=*)
        API_KEY="${1#*=}"
        set_api_key "$API_KEY"
        ;;
    *)
        usage
        ;;
esac

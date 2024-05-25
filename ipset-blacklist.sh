#!/bin/bash

CONFIG_DIR="/etc/openpanel/ufw"
BLACKLIST_CONF="${CONFIG_DIR}/blacklists.conf"
EXCLUDE_FILE="${CONFIG_DIR}/exclude.list"
IP_LIMIT_PER_BLACKLIST="50000"

install_command() {
    local command_name=$1
    # Check if the command is installed
    if ! command -v "$command_name" &> /dev/null
    then
        echo "$command_name is not installed. Installing..."
        sudo apt update
        sudo apt install -y "$command_name"
        if [ $? -eq 0 ]; then
            echo "$command_name installed successfully."
        else
            echo "Failed to install $command_name. Exiting..."
            exit 1
        fi
    fi
}



fetch_abuseipdb() {
    URL=$1
    API_KEY=$2
    OUTPUT_FILE=$3
    echo "Fetching IPs from AbuseIPDB API..."
    response=$(curl -s -G ${URL} --data-urlencode "confidenceMinimum=90" -H "Key: ${API_KEY}" -H "Accept: application/json")
    if [ $? -ne 0 ]; then
        echo "Error fetching IPs"
        exit 1
    fi
    install_command "jq"
    echo $response | jq -r '.data[].ipAddress' > $OUTPUT_FILE
    echo "IPs fetched and saved to $OUTPUT_FILE"
}

fetch_generic_blacklist() {
    URL=$1
    OUTPUT_FILE=$2
    echo "Fetching IPs from $URL..."
    curl -s -L $URL -o $OUTPUT_FILE
    if [ $? -ne 0 ]; then
        echo "Error fetching IPs from $URL"
        exit 1
    fi
    echo "IPs fetched and saved to $OUTPUT_FILE"
}


delete_all_ipsets() {
    echo ""
    echo "Deleting all existing IP sets..."
    echo ""
    # List all IP sets and delete each one
    ipset list -name | while read -r ipset_name; do
        echo "Deleting IP set: $ipset_name"
        ipset destroy $ipset_name
    done
    echo ""
    echo "All IP sets deleted."
    echo ""
}

update_ipset() {
    IPSET_NAME=$1
    IP_FILE=$2
    echo ""
    echo "Updating IPs for: $IPSET_NAME..."
    echo ""
    # Create the ipset if it doesn't exist
    ipset list $IPSET_NAME > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        ipset destroy $IPSET_NAME
    fi
    # fixes
    # ipset v7.15: Hash is full, cannot add more elements
    #
    ipset create $IPSET_NAME hash:ip maxelem $IP_LIMIT_PER_BLACKLIST
    if [ $? -gt 0 ]; then
        echo "ERROR: Can't create $name ipset"
        exit 1
    fi
    # Flush the IP set to remove old entries
    ipset flush $IPSET_NAME

    # Read exclusion list if it exists
    if [ -f $EXCLUDE_FILE ]; then
        mapfile -t exclude_ips < $EXCLUDE_FILE
    else
        exclude_ips=()
    fi

    while IFS= read -r line; do
        # Exclude lines starting with '#' or ';'
        if [[ $line =~ ^[[:space:]]*([#;].*)?$ ]]; then
            continue
        fi
        local ip=$(echo $line | awk '{print $1}')
        # skip excluded ips
        if ! [[ " ${exclude_ips[@]} " =~ " ${ip} " ]]; then
            if ! ipset add $IPSET_NAME $ip 2>&1 | grep -q "Hash is full"; then
                echo $ip
            else
                echo "ERROR: reached limit of $IP_LIMIT_PER_BLACKLIST IP addresses for this ipset $IPSET_NAME"
                return 1
            fi
        else
            echo "Excluding IP: $ip"
        fi
    done < $IP_FILE

    # Save the IP set
    ipset save > /etc/ipset.conf
    echo ""
    echo "IP set $IPSET_NAME updated"
    echo ""
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
    install_command "ufw"
    ufw reload
    echo "UFW updated"
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
            fetch_abuseipdb $url $api_key $IP_FILE
        else
            fetch_generic_blacklist $url $IP_FILE
        fi

        update_ipset $IPSET_NAME $IP_FILE
    done < $BLACKLIST_CONF
}


add_blacklist() {
    local entry="$1"
    if ! grep -qF "$entry" "$BLACKLIST_CONF"; then
        echo "$entry" >> "$BLACKLIST_CONF"
        echo "Added new blacklist: $entry"
    else
        echo "Blacklist already exists: $entry"
    fi
}

parse_add_blacklist_flag() {
    local flag="$1"
    local name=""
    local url=""
    local api_key=""

    for kv in ${flag//&/ }; do
        key=${kv%%=*}
        value=${kv#*=}
        case "$key" in
            name)
                name="$value"
                ;;
            URL)
                url="$value"
                ;;
        esac
    done

    if [ -z "$name" ] || [ -z "$url" ]; then
        echo "Invalid format. Usage: --add-blacklist name=<name> URL=<url>"
        exit 1
    fi

    entry="$name|$url"
    add_blacklist "$entry"
}


enable_blacklist() {
    local blacklist_name="$1"
    if grep -qF "#$blacklist_name" "$BLACKLIST_CONF"; then
        sed -i "s|^#\($blacklist_name.*\)|\1|" "$BLACKLIST_CONF"
        echo "Enabled blacklist: $blacklist_name"
    else
        echo "Blacklist not found or already enabled: $blacklist_name"
    fi
}

disable_blacklist() {
    local blacklist_name="$1"
    if grep -qF "^$blacklist_name" "$BLACKLIST_CONF"; then
        sed -i "s|^\($blacklist_name.*\)|#\1|" "$BLACKLIST_CONF"
        echo "Disabled blacklist: $blacklist_name"
    else
        echo "Blacklist not found or already disabled: $blacklist_name"
    fi
}

delete_blacklist() {
    local blacklist_name="$1"
    if grep -qF "^$blacklist_name|" "$BLACKLIST_CONF"; then
        sed -i "/^$blacklist_name|/d" "$BLACKLIST_CONF"
        echo "Deleted blacklist: $blacklist_name"
    else
        echo "Blacklist not found: $blacklist_name"
    fi
}



usage() {
    echo "Usage: $0 {--fetch|--update_ufw|--delete_ipsets|--add-blacklist name=<name> URL=<url>|--enable-blacklist=|--disable-blacklist=}"
    exit 1
}


if [ $# -ne 1 ]; then
    usage
fi

case "$1" in
    --fetch)
        install_command "ipset"
        process_blacklists
        ;;
    --update_ufw)
        install_command "ipset"
        update_ufw
        ;;
    --delete-ipsets)
        install_command "ipset"
        delete_all_ipsets
        service ufw reload
        ;;
    --add-blacklist*)
        install_command "ipset"
        name=$(echo "$1" | sed -n 's/.*name=\([^ ]*\).*/\1/p')
        url=$(echo "$1" | sed -n 's/.*URL=\([^ ]*\).*/\1/p')
        if [ -n "$name" ] && [ -n "$url" ]; then
            add_blacklist "$name" "$url"
        else
            echo "Invalid format. Use --add-blacklist name=<name> URL=<url>"
        fi
        ;;
    --enable-blacklist=*)
        install_command "ipset"
        blacklist_name="${1#--enable-blacklist=}"
        enable_blacklist "$blacklist_name"
        ;;
    --disable-blacklist=*)
        install_command "ipset"
        blacklist_name="${1#--disable-blacklist=}"
        disable_blacklist "$blacklist_name"
        ;;
    --delete-blacklist=*)
        install_command "ipset"
        blacklist_name="${1#--delete-blacklist=}"
        delete_blacklist "$blacklist_name"
        ;;
    *)
        usage
        ;;
esac

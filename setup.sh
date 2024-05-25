#!/bin/bash

# set configuration
cp configuration/blacklists.conf  /etc/openpanel/ufw/blacklists.conf
touch /etc/openpanel/ufw/exclude.list


# set service
cp service/ipset-blacklist.service /etc/systemd/system/ipset-blacklist.service
cp service/ipset-blacklist.timer /etc/systemd/system/ipset-blacklist.timer

# main file
cp ipset-blacklist.sh /usr/ipset-blacklist.sh
chmod +x /usr/ipset-blacklist.sh


# ipset-blacklist

A Bash shell script which uses ipset and iptables to ban a large number of IP addresses published in IP blacklists. ipset uses a hashtable to store/fetch IP addresses and thus the IP lookup is a lot (!) faster than thousands of sequentially parsed iptables ban rules.

:::warning:::
The ipset command doesn't work under OpenVZ. It works fine on dedicated and fully virtualized servers like KVM though.



## Quick start for Debian/Ubuntu based installations

```bash
bash setup.sh
```

With AbuseIPDB:
```bash
bash setup.sh --abuseipdb-key=API_KEY_HERE
```

## iptables filter rule

```sh
# Enable blacklists
ipset restore < /etc/ipset-blacklist/ip-blacklist.restore
iptables -I INPUT 1 -m set --match-set blacklist src -j DROP
```

Make sure to run this snippet in a firewall script or just insert it to `/etc/rc.local`.

## Check for dropped packets

Using iptables, you can check how many packets got dropped using the blacklist:

```sh
drfalken@wopr:~# iptables -L INPUT -v --line-numbers
Chain INPUT (policy DROP 60 packets, 17733 bytes)
num   pkts bytes target            prot opt in  out source   destination
1       15  1349 DROP              all  --  any any anywhere anywhere     match-set blacklist src
2        0     0 fail2ban-vsftpd   tcp  --  any any anywhere anywhere     multiport dports ftp,ftp-data,ftps,ftps-data
3      912 69233 fail2ban-ssh-ddos tcp  --  any any anywhere anywhere     multiport dports ssh
4      912 69233 fail2ban-ssh      tcp  --  any any anywhere anywhere     multiport dports ssh
```

Since iptable rules are parsed sequentally, the ipset-blacklist is most effective if it's the **topmost** rule in iptable's INPUT chain. However, restarting fail2ban usually leads to a situation, where fail2ban inserts its rules above our blacklist drop rule. To prevent this from happening we have to tell fail2ban to insert its rules at the 2nd position. Since the iptables-multiport action is the default ban-action we have to add a file to `/etc/fail2ban/action.d`:

```sh
tee << EOF /etc/fail2ban/action.d/iptables-multiport.local
[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> 2 -p <protocol> -m multiport --dports <port> -j f2b-<name>
EOF
```

(Please keep in in mind this is entirely optional, it just makes dropping blacklisted IP addresses most effective)

## Modify the blacklists you want to use

Edit the conf file:

```sh
# abuseipdb|https://api.abuseipdb.com/api/v2/blacklist|YOUR_API_KEY
spamhaus_drop|https://www.spamhaus.org/drop/drop.lasso
blocklist_de|https://lists.blocklist.de/lists/all.txt
```


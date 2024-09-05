#!/bin/bash
============================================================

# Custom Service Log
custom_log="/tmp/custom.log"

# Add custom log
echo "[$(date +"%Y.%m.%d.%H:%M:%S")] Start the custom service..." >${custom_log}


# Restart ssh service
[[ -d "/var/run/sshd" ]] || mkdir -p -m0755 /var/run/sshd 2>/dev/null
[[ -f "/etc/init.d/ssh" ]] && {
    sleep 5 && /etc/init.d/ssh restart 2>/dev/null &&
        echo "[$(date +"%Y.%m.%d.%H:%M:%S")] The ssh service restarted successfully." >>${custom_log}
}

# Add network performance optimization
[[ -x "/usr/sbin/balethirq.pl" ]] && {
    perl /usr/sbin/balethirq.pl 2>/dev/null &&
        echo "[$(date +"%Y.%m.%d.%H:%M:%S")] The network optimization service started successfully." >>${custom_log}
}

# For pveproxy startup service
[[ -n "$(dpkg -l | awk '{print $2}' | grep -w "^pve-manager$")" ]] && {
    sudo systemctl restart pveproxy &&
        echo "[$(date +"%Y.%m.%d.%H:%M:%S")] The pveproxy service started successfully." >>${custom_log}
}

# Add custom log
echo "[$(date +"%Y.%m.%d.%H:%M:%S")] All custom services executed successfully!" >>${custom_log}

#!/bin/bash
# Set the EC2 instance hostname
#
# Usage:
#   bash set_hostname.sh maestromojo.com
#   bash set_hostname.sh  # reads from /opt/api/var/hostname
#
set -euo pipefail

HOSTNAME="${1:-}"

if [[ -z "$HOSTNAME" && -f /opt/api/var/hostname ]]; then
    HOSTNAME="$(cat /opt/api/var/hostname)"
fi

if [[ -z "$HOSTNAME" ]]; then
    read -p "Hostname: " HOSTNAME
fi

echo "Setting hostname to: $HOSTNAME"
hostnamectl set-hostname "$HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
echo "$HOSTNAME" > /opt/api/var/hostname 2>/dev/null || true

# Update /etc/hosts
sed -i "s/127.0.0.1.*/127.0.0.1   localhost $HOSTNAME/" /etc/hosts

# Preserve across reboots
if [[ -f /etc/cloud/cloud.cfg ]]; then
    sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
fi

echo "Hostname set to: $(hostname)"

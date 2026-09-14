#!/bin/sh
# Enable SSH on CMU - run from diagnostic terminal
# This starts sshd and makes it persistent across reboots

# Start SSH daemon
/usr/sbin/sshd

# Enable Wi-Fi AP (if not already running)
# You'll connect to this network from your laptop
# Default IP of CMU in AP mode: 192.168.53.1

# Set root password (change 'mazda' to whatever you want)
echo "root:mazda" | chpasswd

# Make SSH start on boot (add to inittab or startup script)
if ! grep -q "sshd" /jci/scripts/stage_wifi.sh; then
    cp /jci/scripts/stage_wifi.sh /jci/scripts/stage_wifi.sh.bak
    echo "/usr/sbin/sshd" >> /jci/scripts/stage_wifi.sh
fi

echo "SSH enabled! Connect to 192.168.53.1 with user: root password: mazda"

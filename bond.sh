#!/bin/bash

# Function to check for active interfaces
check_active_interfaces() {
    echo "Checking for active network interfaces..."
    ACTIVE_INTERFACES=()
    
    # Get a list of all interfaces and check their status
    for interface in $(ip link show | awk -F: '$0 !~ "lo|vir|docker|^[^0-9]"{print $2}' | tr -d ' '); do
        if [[ $(cat /sys/class/net/$interface/operstate) == "up" ]]; then
            ACTIVE_INTERFACES+=($interface)
            echo "$interface is active."
        else
            echo "$interface is inactive."
        fi
    done

    # Check if we have at least two active interfaces
    if [ ${#ACTIVE_INTERFACES[@]} -lt 2 ]; then
        echo "Error: At least two active interfaces are required for bonding."
        exit 1
    fi

    echo "Active interfaces found: ${ACTIVE_INTERFACES[*]}"
}

# Main script execution starts here
check_active_interfaces

# Set the bond name and assign the first two active interfaces
BOND_NAME="bond0"
INTERFACE1=${ACTIVE_INTERFACES[0]}
INTERFACE2=${ACTIVE_INTERFACES[1]}

# Update package repository and install necessary packages
sudo dnf update -y
sudo dnf install -y kernel-modules-extra ifenslave

# Load the bonding kernel module
sudo modprobe bonding

# Create configuration for the bond interface
cat <<EOL | sudo tee /etc/sysconfig/network-scripts/ifcfg-$BOND_NAME
DEVICE=$BOND_NAME
TYPE=Bond
BONDING_MASTER=yes
ONBOOT=yes
BOOTPROTO=none
BONDING_OPTS="miimon=100 mode=4 xmit_hash_policy=layer3+4"
IPADDR=
NETMASK=
GATEWAY=
EOL

# Create configuration for the first slave interface
cat <<EOL | sudo tee /etc/sysconfig/network-scripts/ifcfg-$INTERFACE1
DEVICE=$INTERFACE1
ONBOOT=yes
MASTER=$BOND_NAME
SLAVE=yes
USERCTL=no
EOL

# Create configuration for the second slave interface
cat <<EOL | sudo tee /etc/sysconfig/network-scripts/ifcfg-$INTERFACE2
DEVICE=$INTERFACE2
ONBOOT=yes
MASTER=$BOND_NAME
SLAVE=yes
USERCTL=no
EOL

# Add bonding options to modprobe configuration file 
cat <<EOL | sudo tee /etc/modprobe.d/bonding.conf
alias bond0 bonding
options bond0 miimon=100 mode=4 lacp_rate=1
EOL

# Bring up the interfaces (temporary)
sudo ip link set $INTERFACE1 up
sudo ip link set $INTERFACE2 up

# Ask user for IP address, gateway, netmask, and DNS settings.
read -p "Enter IP Address: " IP_ADDRESS
read -p "Enter Netmask: " NETMASK
read -p "Enter Gateway : " GATEWAY_IP

# Assign IP address and netmask to the bond interface (temporary)
sudo ip addr add $IP_ADDRESS$NETMASK dev $BOND_NAME

# Set the default gateway (temporary)
sudo ip route add default via $GATEWAY_IP

# Ask user for DNS settings and configure DNS resolver permanently.
read -p "Enter Primary DNS Server (e.g., 8.8.8.8): " DNS1
read -p "Enter Secondary DNS Server (optional, press Enter to skip): " DNS2

# Configure DNS in /etc/resolv.conf permanently.
echo -e "nameserver $DNS1" | sudo tee /etc/resolv.conf

if [ ! -z "$DNS2" ]; then
    echo -e "nameserver $DNS2" | sudo tee -a /etc/resolv.conf
fi

# Save IP address, netmask, and gateway permanently in bond configuration file.
sudo sed -i "s|^IPADDR=.*|IPADDR=$IP_ADDRESS|" /etc/sysconfig/network-scripts/ifcfg-$BOND_NAME
sudo sed -i "s|^NETMASK=.*|NETMASK=$NETMASK|" /etc/sysconfig/network-scripts/ifcfg-$BOND_NAME
sudo sed -i "s|^GATEWAY=.*|GATEWAY=$GATEWAY_IP|" /etc/sysconfig/network-scripts/ifcfg-$BOND_NAME

# Restart the network service to apply changes permanently.
sudo systemctl restart NetworkManager.service

# Verify the bond status and configuration.
cat /proc/net/bonding/$BOND_NAME

echo "LACP bonding configuration completed with IP: $IP_ADDRESS"

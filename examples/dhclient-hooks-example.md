# DHCP Client Hooks for Network Failover

These files track IP addresses and gateways automatically when DHCP renews.

## Required DHCP Configuration

### /etc/dhclient.conf
```bash
# DHCP timing - adjust for your ISPs
timeout 300;
retry 90;
initial-interval 2;

# Reject modem IP as our IP (adjust to your modem's IP)
interface "ix0" {
  reject 192.168.200.1;
}
```

## Hook Scripts (create these files)

### /etc/dhclient-enter-hooks
```bash
add_new_resolv_conf() {
  # Prevent DHCP from overwriting resolv.conf
  return 0
}

# Call interface-specific entry hooks if they exist
if [ -x /etc/dhclient-scripts/dhclient-${interface}-enter-hooks ]; then
    /etc/dhclient-scripts/dhclient-${interface}-enter-hooks
fi
```

### /etc/dhclient-exit-hooks
```bash
# Use local DNS resolver
printf 'search example.local\nnameserver 127.0.0.1' | resolvconf -a ${interface}

# Save DHCP status for debugging
env | sed -e 's/new_//g' > /etc/dhclient_status_${interface}

# Call interface-specific exit hooks
if [ -x /etc/dhclient-scripts/dhclient-${interface}-exit-hooks ]; then
    /etc/dhclient-scripts/dhclient-${interface}-exit-hooks
fi
```

### /etc/dhclient-scripts/dhclient-ix0-exit-hooks
```bash
#!/usr/local/bin/bash
# Primary WAN interface hook

# Save network info for failover scripts
case $reason in
BOUND|RENEW|REBIND|REBOOT)
    if [ -n "$new_routers" ] && [ "$new_routers" != "255.255.255.255" ]; then
        echo $new_routers > /tmp/${interface}_router
    fi
    echo $new_ip_address > /var/db/${interface}_ip
    ;;
esac

# Setup modem management route (adjust IPs for your setup)
route delete 192.168.200.1 2>/dev/null || true
route add -host 192.168.200.1 -interface ix0
ifconfig ix0 alias 192.168.200.2/30
```

### /etc/dhclient-scripts/dhclient-ix2-exit-hooks
```bash
#!/usr/local/bin/bash
# Backup WAN interface hook

# Save network info for failover scripts
case $reason in
BOUND|RENEW|REBIND|REBOOT)
    if [ -n "$new_routers" ] && [ "$new_routers" != "255.255.255.255" ]; then
        echo $new_routers > /tmp/${interface}_router
    fi
    echo $new_ip_address > /var/db/${interface}_ip
    ;;
esac

# Setup backup modem management route (adjust IPs for your setup)
route delete 198.51.100.1 2>/dev/null || true
route add -host 198.51.100.1 -interface ix2
ifconfig ix2 alias 198.51.100.2/24
```

## Files Created by Hooks

These files are automatically maintained and read by the failover scripts:

- `/var/db/ix0_ip` - Primary WAN IP address
- `/var/db/ix2_ip` - Backup WAN IP address
- `/tmp/ix0_router` - Primary WAN gateway IP
- `/tmp/ix2_router` - Backup WAN gateway IP

## Setup Instructions

1. Create the hook files above with appropriate permissions:
   ```bash
   chmod +x /etc/dhclient-scripts/dhclient-*-hooks
   ```

2. Adjust IP addresses to match your modem management interfaces

3. Test DHCP renewal:
   ```bash
   dhclient -r ix0 && dhclient ix0
   cat /var/db/ix0_ip /tmp/ix0_router
   ```
# FreeBSD Network Failover System

A robust, production-ready network failover system for FreeBSD that automatically switches between primary and backup internet connections when connectivity issues are detected.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Network Setup](#network-setup)
- [DHCP Configuration](#dhcp-configuration)
- [PF Firewall Configuration](#pf-firewall-configuration)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

## Overview

This system uses `dpinger` to monitor network connectivity and automatically fails over between primary (cable modem) and backup (LTE) internet connections. When packet loss exceeds a configurable threshold, the system switches routing, firewall rules, and restarts dependent services to maintain internet connectivity.

**Key Components:**
- **dpinger**: Network monitoring daemon that detects connectivity issues
- **failover script**: Handles the actual network switching and service management
- **DHCP hooks**: Automatically track IP addresses and gateway changes
- **PF firewall**: Manages routing and security policies

## Features

- ✅ **Automatic Failover**: Switches to backup connection when primary fails
- ✅ **Automatic Recovery**: Returns to primary when connectivity is restored
- ✅ **Race Condition Prevention**: File locking prevents multiple simultaneous operations
- ✅ **Comprehensive Logging**: Multiple log levels with structured output
- ✅ **Service Management**: Automatically restarts dependent services
- ✅ **Network State Backup**: Saves configuration for potential rollback
- ✅ **Input Validation**: Validates interfaces and configuration before execution
- ✅ **Status Monitoring**: Real-time status tracking and reporting
- ✅ **LED Indicators**: Visual notification of network state changes
- ✅ **Push Notifications**: Pushover integration for alerts
- ✅ **DNS Updates**: Automatic Route53 and local DNS updates
- ✅ **Bandwidth Management**: Restricts bandwidth-heavy hosts during failover

## Architecture

### Network Topology

```
Internet
   │
   ├─ Cable Modem (192.168.100.1) ──── ix0 (Primary WAN)
   │                                     │
   └─ LTE Modem (192.168.5.1) ────────── ix2 (Backup WAN)
                                         │
FreeBSD Router ──────────────────────────┤
   │                                     │
   └─ LAN (192.168.100.0/24) ─────────── ix3 (LAN Interface)
```

### Component Interaction

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   rc.local      │───▶│ startup_script  │───▶│    dpinger      │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                                       │
                              ┌─────────────────┐      │ (on packet loss)
                              │ failover_script │◀─────┘
                              └─────────────────┘
                                       │
                    ┌──────────────────┼──────────────────┐
                    ▼                  ▼                  ▼
            ┌───────────────┐  ┌──────────────┐  ┌──────────────┐
            │   Routing     │  │  Firewall    │  │   Services   │
            │   Changes     │  │   Reload     │  │   Restart    │
            └───────────────┘  └──────────────┘  └──────────────┘
```

## Network Setup

### Interface Configuration

The system uses three network interfaces defined in `/etc/rc.conf`:

```bash
# Primary WAN (Cable Modem)
ifconfig_ix0="SYNCDHCP -lro -tso group egress media 10Gbase-T -tso4 -tso6 -vlanhwtso"
ifconfig_ix0_alias0="inet 192.168.100.2/30"  # Cable modem management

# Backup WAN (LTE Modem)
ifconfig_ix2="SYNCDHCP -lro -tso"
ifconfig_ix2_alias0="inet 192.168.5.2/24"    # LTE modem management

# LAN Interface
ifconfig_ix3="inet 192.168.100.1 netmask 255.255.255.0 promisc -lro -tso"
```

### Static Routes

Direct routes to modem management interfaces:

```bash
static_routes="cablemodem ltemodem"
route_cablemodem="-net 192.168.100.1/32 -interface ix0"
route_ltemodem="-net 192.168.5.1/32 -interface ix2"
```

### Interface Groups

FreeBSD's `egress` group is used to dynamically identify the active WAN interface:
- During normal operation: `ix0` is in the `egress` group
- During failover: `ix2` is added to `egress` group, `ix0` is removed
- PF firewall rules reference `egress` for dynamic behavior

## DHCP Configuration

### Main Configuration (`/etc/dhclient.conf`)

```bash
# DHCP timing configuration
timeout 300;
retry 90;
initial-interval 2;
reboot 10;
backoff-cutoff 30;

interface "ix0" {
  reject 192.168.100.1;  # Don't accept cable modem IP as our IP
}
```

### Hook Scripts

The system uses DHCP client hooks to track network changes automatically:

#### Entry Hooks (`/etc/dhclient-enter-hooks`)
- Disables automatic `/etc/resolv.conf` updates
- Calls interface-specific entry hooks

#### Exit Hooks (`/etc/dhclient-exit-hooks`)
- Updates DNS configuration with local resolver
- Saves DHCP status to `/etc/dhclient_status_${interface}`
- Calls interface-specific exit hooks

#### Interface-Specific Hooks

**ix0 (Primary WAN) - `/etc/dhclient-scripts/dhclient-ix0-exit-hooks`:**
```bash
#!/usr/local/bin/bash -x
# Updates gateway hostname entries
/etc/dhclient-scripts/set_gateway_entries.sh "${new_routers}" "gateway-comcast.localhost gateway.localhost"

# Save network info for failover scripts
case $reason in
BOUND|RENEW|REBIND|REBOOT)
    if [ -n "$new_routers" ] && [ "$new_routers" != "255.255.255.255" ]; then
        echo $new_routers > /tmp/${interface}_router
    fi
    echo $new_ip_address > /var/db/${interface}_ip
    ;;
esac

# Setup cable modem management route
route delete 192.168.100.1
route add -host 192.168.100.1 -interface ix0
ifconfig ix0 alias 192.168.100.2/30
```

**ix2 (Backup WAN) - `/etc/dhclient-scripts/dhclient-ix2-exit-hooks`:**
```bash
#!/usr/local/bin/bash -x
# Updates backup gateway hostname entries
/etc/dhclient-scripts/set_gateway_entries.sh "${new_routers}" "gateway-backup.localhost gateway-tmobile.localhost"

# Save network info for failover scripts
case $reason in
BOUND|RENEW|REBIND|REBOOT)
    if [ -n "$new_routers" ] && [ "$new_routers" != "255.255.255.255" ]; then
        echo $new_routers > /tmp/${interface}_router
    fi
    echo $new_ip_address > /var/db/${interface}_ip
    ;;
esac

# Setup LTE modem management route
route delete 192.168.5.1
route add -host 192.168.5.1 -interface ix2
ifconfig ix2 alias 192.168.5.2/24
```

### Tracked Files

The DHCP hooks maintain these files for failover script consumption:

- `/var/db/ix0_ip` - Primary WAN IP address
- `/var/db/ix2_ip` - Backup WAN IP address
- `/tmp/ix0_router` - Primary WAN gateway IP
- `/tmp/ix2_router` - Backup WAN gateway IP

## PF Firewall Configuration

### Key Features (`/etc/pf/pf.simple.conf`)

```bash
# Interface macros
ext_if0="ix0"    # Primary WAN
ext_if1="ix2"    # Backup WAN
int_if0="ix3"    # LAN

# Tables for dynamic management
table <nat_approved_wide> { 192.168.100.1/24 }  # Internal networks
table <fail2ban> persist                        # Banned IPs
table <self> { self }                          # Router IPs

# Global settings
set loginterface egress    # Log on active interface
set state-policy floating # Allow states to survive interface changes

# Special NAT for modem management
nat on $ext_if0 inet from { <nat_approved_wide>, <self> } to 192.168.100.1 -> 192.168.100.2
nat on $ext_if1 inet from { <nat_approved_wide>, <self> } to 192.168.5.1 -> 192.168.5.2

# Primary NAT rule (uses 'egress' group)
nat on egress inet from <nat_approved_wide> to any -> (egress:0)

# Modem management access rules
pass in quick on $int_if0 proto { tcp, icmp, udp } from <nat_approved_wide> to 192.168.100.1
pass out quick on $ext_if0 proto { tcp, icmp, udp } from 192.168.100.2 to 192.168.100.1

pass in quick on $int_if0 proto { tcp, icmp, udp } from <nat_approved_wide> to 192.168.5.1
pass out quick on $ext_if1 proto { tcp, icmp, udp } from 192.168.5.2 to 192.168.5.1
```

### Failover Integration

During failover, the script:
1. Updates interface group membership (`egress`)
2. Reloads PF rules with `pfctl -g -v -F all -f /etc/pf/pf.simple.conf`
3. Manages bandwidth restrictions via the `nat_approved_wide` table

## Installation

### Prerequisites

- FreeBSD 12.0 or later
- Root access
- Network interfaces configured with DHCP
- PF firewall enabled

### Install Dependencies

```bash
# Install required packages
pkg install dpinger bash

# Optional: LED control and notifications
# See: https://github.com/todbot/blink1-tool
pkg install blink1-tool
```

### Deploy Scripts

```bash
# Clone repository
git clone https://github.com/yourusername/freebsd_failover.git
cd freebsd_failover

# Copy scripts to /etc/dpinger
sudo mkdir -p /etc/dpinger
sudo cp dpinger_dhclient_startup_script /etc/dpinger/startup_script
sudo cp dpinger_failover_script /etc/dpinger/failover
sudo cp failover-lib.sh /etc/dpinger/
sudo cp failover.conf /etc/dpinger/
sudo chmod +x /etc/dpinger/*

# Add to rc.local
echo '/etc/dpinger/startup_script ix0 ix2' | sudo tee -a /etc/rc.local
```

## Configuration

### Main Configuration File

Edit `/etc/dpinger/failover.conf`:

```bash
# Network Configuration
PRIMARY_NIC="ix0"
BACKUP_NIC="ix2"

# Monitoring Thresholds
LOSS_THRESHOLD="25%"
AVERAGING_WINDOW="20s"

# Services to restart after failover
SERVICES_TO_RESTART="unbound miniupnpd avahi-daemon"

# Notification settings
ENABLE_PUSHOVER="true"
PUSHOVER_SCRIPT="/usr/local/bin/pushover_message.sh"
```

### Interface Validation

Ensure your interfaces are properly configured:

```bash
# Check interface status
ifconfig ix0 ix2 ix3

# Verify DHCP is working
cat /var/db/ix0_ip
cat /tmp/ix0_router
```

## Usage

### Manual Start

```bash
# Start monitoring
sudo /etc/dpinger/startup_script ix0 ix2

# Check status
pgrep dpinger
cat /var/run/dpinger_ix0.pid
```

### View Logs

```bash
# Real-time failover logs
tail -f /var/log/network_failover.log

# Dpinger monitoring logs
tail -f /var/log/dpinger_ix0.log

# System logs
tail -f /var/log/messages | grep dpinger
```

### Check Status

```bash
# Current network status
cat /var/run/network_failover_status

# Active default route
netstat -rn | grep default

# Interface group membership
ifconfig | grep groups
```

## Monitoring

### Key Metrics

- **Packet Loss**: Current percentage (triggers at 25%)
- **Latency**: Average response time to gateway
- **Interface Status**: Active interface in `egress` group
- **Service Health**: Status of restarted services

### Status Files

- `/var/run/network_failover_status` - Current failover state
- `/var/run/dpinger_ix0.pid` - Dpinger process ID
- `/var/log/network_failover.log` - Detailed failover events

### LED Indicators (Optional)

If [blink1-tool](https://github.com/todbot/blink1-tool) is installed:
- **Black**: Normal operation (primary interface)
- **Pink**: Failover state (backup interface)
- **Red**: Error condition

## Troubleshooting

### Common Issues

**1. Dpinger won't start**
```bash
# Check interfaces exist
ifconfig ix0 ix2

# Verify DHCP files exist
ls -la /var/db/ix*_ip /tmp/ix*_router

# Check for competing processes
pgrep dpinger
```

**2. Failover not triggering**
```bash
# Check dpinger logs
tail -f /var/log/dpinger_ix0.log

# Test connectivity manually
ping -c 5 $(cat /tmp/ix0_router)

# Verify loss threshold
grep LOSS_THRESHOLD /etc/dpinger/failover.conf
```

**3. Services not restarting**
```bash
# Check service status
service unbound status
service miniupnpd status

# Verify service names
grep SERVICES_TO_RESTART /etc/dpinger/failover.conf

# Manual service restart test
sudo service unbound restart
```

**4. PF rules not loading**
```bash
# Test PF syntax
sudo pfctl -n -f /etc/pf/pf.simple.conf

# Check current rules
sudo pfctl -s rules | head -20

# Reload manually
sudo pfctl -f /etc/pf/pf.simple.conf
```

### Debug Mode

Enable detailed logging:

```bash
# Edit configuration
sudo vi /etc/dpinger/failover.conf
# Set: LOG_LEVEL="debug"

# Restart monitoring
sudo pkill dpinger
sudo /etc/dpinger/startup_script ix0 ix2
```

### Log Analysis

```bash
# Search for specific events
grep "FAILOVER" /var/log/network_failover.log
grep "RECOVERY" /var/log/network_failover.log

# Check for errors
grep "ERROR" /var/log/network_failover.log

# Monitor in real-time
tail -f /var/log/network_failover.log | grep -E "(FAILOVER|RECOVERY|ERROR)"
```

## Advanced Configuration

### Custom Notification Scripts

Create custom notification handlers:

```bash
# Example: Slack webhook notification
cat > /usr/local/bin/slack_notification.sh << 'EOF'
#!/bin/bash
MESSAGE="$1"
WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
curl -X POST -H 'Content-type: application/json' \
  --data "{\"text\":\"Network Failover: $MESSAGE\"}" \
  "$WEBHOOK_URL"
EOF
chmod +x /usr/local/bin/slack_notification.sh

# Add to configuration
echo 'CUSTOM_NOTIFICATION_SCRIPT="/usr/local/bin/slack_notification.sh"' >> /etc/dpinger/failover.conf
```

### Multiple Backup Connections

For setups with multiple backup connections, modify the configuration:

```bash
# Example: Cable -> LTE -> Starlink hierarchy
PRIMARY_NIC="ix0"
BACKUP_NIC="ix2"
TERTIARY_NIC="ix4"
```

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/improvement`)
3. Commit your changes (`git commit -am 'Add improvement'`)
4. Push to the branch (`git push origin feature/improvement`)
5. Create a Pull Request

### Development Guidelines

- Follow existing shell scripting patterns
- Add appropriate error handling and logging
- Update documentation for new features
- Test thoroughly on FreeBSD systems

## License

This project is licensed under the BSD 2-Clause License - see the LICENSE file for details.

## Acknowledgments

- FreeBSD project for the robust networking stack
- dpinger developers for the monitoring tool
- Community contributors and testers
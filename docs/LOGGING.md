# Dpinger Logging and Log Rotation

## Dpinger Log Format

The dpinger output consists of space-separated fields:

```
<identifier> <avg_latency_μs> <stddev_latency_μs> <loss_percentage>
```

**Example log entries:**
```
dpinger_ix0 9519 896 0
dpinger_ix0 9332 1589 0
dpinger_ix0 10057 1786 0
```

**Field breakdown:**
- **identifier**: `dpinger_ix0` - Configured with `-i` flag, identifies the monitoring instance
- **avg_latency_μs**: `9519` - Average latency in microseconds (9.519ms in this example)
- **stddev_latency_μs**: `896` - Standard deviation of latency in microseconds
- **loss_percentage**: `0` - Percentage of packet loss (0% = no loss)

## Log Files Created

The failover system creates several log files:

1. **Dpinger monitoring log**: `/var/log/dpinger_ix0.log`
   - Raw dpinger metrics (latency/loss data)
   - High-frequency updates (default every 1 second)
   - Large file size due to frequent writes

2. **Failover event log**: `/var/log/network_failover.log`
   - Human-readable failover events
   - Lower frequency (only during state changes)
   - Includes timestamps and detailed operation logs

3. **Syslog entries**: `/var/log/messages`
   - Dpinger uses syslog with `-S` flag for warnings/alerts
   - Startup script and failover script log to syslog

## Log Rotation Configuration

### For Dpinger Metrics Log

Create `/usr/local/etc/newsyslog.conf.d/dpinger.conf`:

```bash
# Dpinger monitoring logs - high frequency data
# logfilename                    [owner:group] mode count size  when  flags [/pid_file] [sig_num]
/var/log/dpinger_ix0.log        root:wheel    644  7     10000  *     NZ    /var/run/dpinger_ix0.pid
/var/log/dpinger_ix2.log        root:wheel    644  7     10000  *     NZ    /var/run/dpinger_ix2.pid
```

**Configuration explanation:**
- `root:wheel 644` - Readable by all, writable by root
- `7` - Keep 7 rotated copies
- `10000` - Rotate when log reaches 10MB (10,000 KB)
- `*` - Rotate based on size, not time
- `N` - Don't signal any process (dpinger handles rotation)
- `Z` - Compress old log files with gzip
- `/var/run/dpinger_ix0.pid` - PID file location (not used with N flag)

### For Failover Event Log

```bash
# Failover event logs - lower frequency, keep longer
/var/log/network_failover.log   root:wheel    644  30    1000   *     NZ
```

**Configuration explanation:**
- Keep 30 copies (longer retention for troubleshooting)
- Rotate at 1MB (lower frequency data)

## Alternative: Use Syslog Only

For environments preferring centralized logging, configure dpinger to use only syslog:

### Update startup script:
```bash
# Remove the -o file output, use only syslog
dpinger_cmd=(
    dpinger
    -i "dpinger_${DEFAULT_NIC}"
    -p "${DPINGER_PIDFILE}"
    -B "${DEFAULT_NIC_IP}"
    -P -S  # Only use syslog, no file output
    # Remove: -o "${DPINGER_LOGFILE}"
    # ... other options
)
```

### Configure syslog facility
Add to `/etc/syslog.conf`:
```bash
# Dpinger logs to user facility by default
user.info                                       /var/log/dpinger.log
user.warn                                       /var/log/dpinger.log
```

### Syslog rotation in newsyslog.conf:
```bash
/var/log/dpinger.log            root:wheel    644  7     5000   *     JC
```

## Log Analysis Examples

### Monitor real-time latency:
```bash
# Watch current latency (column 2)
tail -f /var/log/dpinger_ix0.log | awk '{print $2/1000 "ms"}'
```

### Check for packet loss:
```bash
# Show entries with packet loss > 0
awk '$4 > 0 {print $0}' /var/log/dpinger_ix0.log
```

### Calculate average latency over time:
```bash
# Average latency from last 100 entries
tail -100 /var/log/dpinger_ix0.log | awk '{sum+=$2; count++} END {print sum/count/1000 "ms"}'
```

### Monitor failover events:
```bash
# Watch failover log for events
tail -f /var/log/network_failover.log | grep -E "(FAILOVER|RECOVERY)"
```

## Disk Space Considerations

**High-frequency logging considerations:**
- Dpinger logs every second by default
- Each entry ~30 bytes: `dpinger_ix0 9519 896 0\n`
- Daily log size: ~2.6MB per day per interface
- Weekly: ~18MB per interface
- With 10MB rotation: ~3-4 days per file

**Recommendations:**
1. **Monitor disk usage**: Set up monitoring alerts for `/var/log/`
2. **Adjust report interval**: Use `-r 5s` for less frequent logging if acceptable
3. **Use syslog centralization**: For multi-system deployments
4. **Consider log shipping**: To external systems for long-term storage

## Integration with Monitoring Systems

### Prometheus/Grafana Integration
Parse dpinger logs to expose metrics:

```bash
#!/bin/bash
# Simple dpinger metrics exporter
tail -f /var/log/dpinger_ix0.log | while read line; do
    set $line
    echo "dpinger_latency_us{interface=\"ix0\"} $2"
    echo "dpinger_jitter_us{interface=\"ix0\"} $3"
    echo "dpinger_loss_percent{interface=\"ix0\"} $4"
done
```

### Log Shipping
For centralized logging systems like ELK stack:
```bash
# Filebeat configuration snippet
- type: log
  paths:
    - /var/log/dpinger_*.log
  fields:
    service: dpinger
    system: failover
  multiline.pattern: '^dpinger_'
  multiline.negate: true
  multiline.match: after
```
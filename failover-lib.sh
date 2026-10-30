#!/usr/local/bin/bash
#
# FreeBSD Network Failover Library
# Common functions for dpinger startup and failover scripts
#

# Global variables
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/failover.conf}"
LOCKFILE="/var/run/failover.lock"
LOCKFD=200
PID="$$"

#############################################################################
# CONFIGURATION LOADING
#############################################################################

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi

    # Source the configuration file
    # shellcheck source=failover.conf
    source "$CONFIG_FILE" || {
        log_error "Failed to load configuration from $CONFIG_FILE"
        return 1
    }

    log_debug "Configuration loaded from $CONFIG_FILE"
    return 0
}

#############################################################################
# LOGGING FUNCTIONS
#############################################################################

# Initialize logging
init_logging() {
    local script_name="$(basename "$0")"
    LOGGER="/usr/bin/logger -s -p user.${LOG_LEVEL:-notice} -t ${script_name}[${PID}]"
}

# Log with different severity levels
log_debug() { [[ "${LOG_LEVEL}" == "debug" ]] && echo "$(date '+%F %T') [DEBUG] $*" | tee -a "${FAILOVER_LOG:-/var/log/network_failover.log}"; }
log_info() { echo "$(date '+%F %T') [INFO] $*" | tee -a "${FAILOVER_LOG:-/var/log/network_failover.log}"; ${LOGGER} "INFO: $*" 2>/dev/null; }
log_notice() { echo "$(date '+%F %T') [NOTICE] $*" | tee -a "${FAILOVER_LOG:-/var/log/network_failover.log}"; ${LOGGER} "NOTICE: $*" 2>/dev/null; }
log_warning() { echo "$(date '+%F %T') [WARNING] $*" | tee -a "${FAILOVER_LOG:-/var/log/network_failover.log}" >&2; ${LOGGER} "WARNING: $*" 2>/dev/null; }
log_error() { echo "$(date '+%F %T') [ERROR] $*" | tee -a "${FAILOVER_LOG:-/var/log/network_failover.log}" >&2; ${LOGGER} "ERROR: $*" 2>/dev/null; }
log_critical() { echo "$(date '+%F %T') [CRITICAL] $*" | tee -a "${FAILOVER_LOG:-/var/log/network_failover.log}" >&2; ${LOGGER} "CRITICAL: $*" 2>/dev/null; }

#############################################################################
# LOCKING FUNCTIONS
#############################################################################

# Acquire exclusive lock to prevent race conditions
acquire_lock() {
    local timeout="${1:-10}"
    local count=0

    exec 200>"$LOCKFILE"

    while ! flock -n 200; do
        if [[ $count -ge $timeout ]]; then
            log_error "Failed to acquire lock after ${timeout}s - another operation may be running"
            return 1
        fi
        sleep 1
        ((count++))
    done

    echo "$PID" > "$LOCKFILE"
    log_debug "Lock acquired (PID: $PID)"
    return 0
}

# Release the lock
release_lock() {
    if [[ -f "$LOCKFILE" ]]; then
        rm -f "$LOCKFILE"
        log_debug "Lock released"
    fi
    exec 200>&-
}

# Set up trap to release lock on exit
setup_lock_cleanup() {
    trap 'release_lock; exit' INT TERM EXIT
}

#############################################################################
# VALIDATION FUNCTIONS
#############################################################################

# Validate that a network interface exists
validate_interface() {
    local interface="$1"

    if [[ -z "$interface" ]]; then
        log_error "Interface name cannot be empty"
        return 1
    fi

    if ! ifconfig "$interface" >/dev/null 2>&1; then
        log_error "Interface '$interface' does not exist"
        return 1
    fi

    log_debug "Interface '$interface' validated successfully"
    return 0
}

# Validate that required files exist
validate_file() {
    local file="$1"
    local description="$2"

    if [[ ! -f "$file" ]]; then
        log_error "$description file not found: $file"
        return 1
    fi

    log_debug "File validated: $file"
    return 0
}

# Validate configuration
validate_config() {
    log_info "Validating configuration..."

    # Validate interfaces
    validate_interface "$PRIMARY_NIC" || return 1
    validate_interface "$BACKUP_NIC" || return 1

    # Validate required files
    validate_file "${PF_RULE_FILE:-/etc/pf/pf.simple.conf}" "PF configuration" || log_warning "PF configuration file not found"

    # Validate IP files exist
    validate_file "/var/db/${PRIMARY_NIC}_ip" "Primary NIC IP" || return 1
    validate_file "/tmp/${PRIMARY_NIC}_router" "Primary NIC gateway" || return 1
    validate_file "/tmp/${BACKUP_NIC}_router" "Backup NIC gateway" || return 1

    log_info "Configuration validation completed"
    return 0
}

#############################################################################
# NETWORK OPERATION FUNCTIONS
#############################################################################

# Safely execute route operations with error handling
safe_route_operation() {
    local operation="$1"
    local gateway="$2"
    local max_retries="${3:-3}"
    local retry_delay="${4:-2}"
    local attempt=1

    while [[ $attempt -le $max_retries ]]; do
        log_debug "Route operation attempt $attempt/$max_retries: $operation default $gateway"

        if route "$operation" default "$gateway" >/dev/null 2>&1; then
            log_info "Route operation successful: $operation default $gateway"
            return 0
        else
            log_warning "Route operation failed (attempt $attempt): $operation default $gateway"
            if [[ $attempt -lt $max_retries ]]; then
                sleep "$retry_delay"
            fi
        fi

        ((attempt++))
    done

    log_error "Route operation failed after $max_retries attempts: $operation default $gateway"
    return 1
}

# Verify network connectivity
verify_connectivity() {
    local gateway="$1"
    local test_host="${TEST_DESTINATION:-8.8.8.8}"
    local timeout="${CONNECTIVITY_TEST_TIMEOUT:-2000}"

    log_debug "Testing connectivity to $test_host via $gateway"

    if ping -c 3 -W "$timeout" "$test_host" >/dev/null 2>&1; then
        log_info "Connectivity verified to $test_host"
        return 0
    else
        log_warning "Connectivity test failed to $test_host"
        return 1
    fi
}

#############################################################################
# BACKUP AND ROLLBACK FUNCTIONS
#############################################################################

# Save current network state for potential rollback
save_network_state() {
    local timestamp=$(date +%s)
    local backup_dir="/tmp/network_backup_${timestamp}"

    if [[ "${ENABLE_ROLLBACK:-true}" != "true" ]]; then
        log_debug "Network state backup disabled"
        return 0
    fi

    mkdir -p "$backup_dir" || {
        log_error "Failed to create backup directory: $backup_dir"
        return 1
    }

    # Save routing table
    netstat -rn > "${backup_dir}/routes" || log_warning "Failed to backup routes"

    # Save interface configuration
    ifconfig > "${backup_dir}/interfaces" || log_warning "Failed to backup interfaces"

    # Save PF state if pfctl is available
    if command -v pfctl >/dev/null 2>&1; then
        pfctl -s rules > "${backup_dir}/pf_rules" 2>/dev/null || log_warning "Failed to backup PF rules"
    fi

    # Store backup path for cleanup
    echo "$backup_dir" > "/tmp/last_network_backup"
    log_debug "Network state saved to $backup_dir"

    # Clean up old backups (keep only last 5)
    find /tmp -name "network_backup_*" -type d -mtime +1 -exec rm -rf {} \; 2>/dev/null || true

    return 0
}

#############################################################################
# SERVICE MANAGEMENT FUNCTIONS
#############################################################################

# Safely restart a service with timeout
restart_service_safely() {
    local service="$1"
    local timeout="${SERVICE_RESTART_TIMEOUT:-30}"
    local count=0

    log_info "Restarting service: $service"

    # Check if service exists
    if ! service "$service" status >/dev/null 2>&1; then
        log_warning "Service $service not found or not running"
        return 0
    fi

    # Stop the service
    if ! service "$service" stop >/dev/null 2>&1; then
        log_warning "Failed to stop service $service gracefully"
    fi

    # Wait for clean shutdown
    while pgrep "$service" >/dev/null 2>&1 && [[ $count -lt $timeout ]]; do
        sleep 1
        ((count++))
    done

    # Force kill if still running
    if pgrep "$service" >/dev/null 2>&1; then
        log_warning "Force killing service $service after ${timeout}s timeout"
        pkill -9 "$service" 2>/dev/null || true
    fi

    # Special handling for unbound
    if [[ "$service" == "unbound" ]] && [[ -f "/etc/unbound/root.key" ]]; then
        log_debug "Removing unbound root.key for clean restart"
        rm -f "/etc/unbound/root.key"
    fi

    # Start the service
    if service "$service" start >/dev/null 2>&1; then
        log_info "Service $service restarted successfully"
        return 0
    else
        log_error "Failed to start service $service"
        return 1
    fi
}

#############################################################################
# STATUS AND MONITORING FUNCTIONS
#############################################################################

# Update system status file
update_status() {
    local status="$1"
    local primary_nic="$2"
    local backup_nic="$3"
    local status_file="/var/run/network_failover_status"

    local timestamp=$(date '+%s')
    echo "${timestamp}:${status}:${primary_nic}:${backup_nic}" > "$status_file"
    log_debug "Status updated: $status"
}

# Check if we're in a failover state
is_failed_over() {
    local status_file="/var/run/network_failover_status"

    if [[ -f "$status_file" ]]; then
        local last_status=$(cut -d':' -f2 < "$status_file")
        [[ "$last_status" == "1" ]]
    else
        return 1  # Assume normal state if no status file
    fi
}

#############################################################################
# NOTIFICATION FUNCTIONS
#############################################################################

# Send notification via pushover
send_pushover_notification() {
    local message="$1"
    local priority="${2:-normal}"

    if [[ "${ENABLE_PUSHOVER:-true}" != "true" ]]; then
        log_debug "Pushover notifications disabled"
        return 0
    fi

    if [[ -x "$PUSHOVER_SCRIPT" ]]; then
        echo "$message" | "$PUSHOVER_SCRIPT" "$priority" &
        log_debug "Pushover notification sent: $message"
    else
        log_warning "Pushover script not found or not executable: $PUSHOVER_SCRIPT"
    fi
}

# Update LED status
update_led() {
    local color="$1"

    if [[ -x "$BLINK_TOOL" ]]; then
        "$BLINK_TOOL" "--rgb=${color}" >/dev/null 2>&1 || log_warning "Failed to update LED"
        log_debug "LED updated to color: $color"
    else
        log_debug "LED tool not available: $BLINK_TOOL"
    fi
}

#############################################################################
# INITIALIZATION
#############################################################################

# Initialize the library
init_failover_lib() {
    # Load configuration first
    load_config || exit 1

    # Initialize logging
    init_logging

    # Set up lock cleanup
    setup_lock_cleanup

    log_debug "Failover library initialized"
}
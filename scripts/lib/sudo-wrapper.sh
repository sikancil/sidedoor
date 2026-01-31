#!/usr/bin/env bash
#
# Sudo Elevation Wrapper
# Auto-elevates scripts with sudo when not running as root
#
# Features:
# - Auto-detects non-root execution
# - Elevates with sudo automatically
# - Extends sudo timeout for long-running operations
# - Provides helpful error messages
#
# Usage:
#   # At the start of your script:
#   source "scripts/lib/sudo-wrapper.sh"
#   ensure_elevated "$@"
#
#   # For long-running operations:
#   sudo_refresh
#

# Sudo timestamp timeout (default is usually 15 minutes)
# We'll refresh it periodically during long operations
SUDO_TIMESTAMP_TIMEOUT=${SUDO_TIMESTAMP_TIMEOUT:-15}

# Last sudo refresh time
_SUDO_LAST_REFRESH=0

# Check if we need to refresh sudo timestamp
sudo_need_refresh() {
    local now
    now=$(date +%s)

    # Refresh if we haven't in the last 5 minutes (half of default timeout)
    if [[ $((now - _SUDO_LAST_REFRESH)) -gt 300 ]]; then
        return 0
    fi
    return 1
}

# Refresh sudo timestamp (extends timeout)
sudo_refresh() {
    if [[ $EUID -eq 0 ]]; then
        _SUDO_LAST_REFRESH=$(date +%s)
        return 0
    fi

    # Only attempt refresh if we have sudo cached
    if sudo -n true 2>/dev/null; then
        sudo -v 2>/dev/null || {
            error "Sudo session expired during operation"
            error "Please re-run the script"
            exit 1
        }
        _SUDO_LAST_REFRESH=$(date +%s)
    fi
}

# Ensure script is running with root privileges
# Automatically re-runs script with sudo if needed
ensure_elevated() {
    # Already running as root
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi

    # Check if we're in a sudo session already
    if [[ -n "${SUDO_USER:-}" ]] || [[ -n "${SUDO_UID:-}" ]]; then
        # We're already elevated via sudo
        return 0
    fi

    # Check if sudo command is available
    if ! command -v sudo &>/dev/null; then
        error "This script requires root privileges"
        error ""
        error "Sudo is not available on this system"
        error "Please run this script as root directly:"
        error "  su - root -c '$0 $*'"
        exit 1
    fi

    # Check if we can use sudo (will prompt for password)
    if ! sudo -v &>/dev/null; then
        error "This script requires root privileges"
        error ""
        error "Sudo authentication failed or not permitted"
        error "Please check your sudo configuration and try again"
        exit 1
    fi

    # Sudo is available and we can authenticate - re-run script with sudo
    log "🔐 Elevating privileges with sudo..."
    log ""

    # Re-execute this script with sudo
    # exec replaces the current process, so no shell returns
    exec sudo "$0" "$@"

    # This line should never be reached due to exec
    error "Failed to elevate privileges"
    exit 1
}

# Alternative: Check and suggest sudo command (non-auto-elevating)
# Use this if you want to inform the user instead of auto-elevating
check_elevated() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi

    error "This script must be run as root"
    error ""
    error "Please run with sudo:"
    error "  sudo $0 $*"
    error ""
    error "Or ensure you have sudo privileges and try again"

    exit 1
}

# Show sudo timeout information
sudo_timeout_info() {
    local timeout_file
    timeout_file=$(sudo -n env 2>/dev/null | grep "SUDO_USER" && echo "active" || echo "inactive")

    info "Sudo Credential Caching:"
    info "  Status: $timeout_file"
    info "  Default timeout: 15 minutes (configurable in /etc/sudoers)"
    info "  This script will automatically refresh credentials during long operations"
    info ""
    info "To change sudo timeout:"
    info "  sudo visudo"
    info "  Add: Defaults:$USER timestamp_timeout=30"
    info ""
}

# Validate sudo configuration
validate_sudo_config() {
    local current_user="${SUDO_USER:-$USER}"

    # Check if user is in sudo group
    if ! groups "$current_user" 2>/dev/null | grep -q "sudo"; then
        error "User '$current_user' is not in the sudo group"
        error ""
        error "To add user to sudo group:"
        error "  sudo usermod -aG sudo $current_user"
        return 1
    fi

    return 0
}

# Export functions for use in other scripts
export -f ensure_elevated
export -f check_elevated
export -f sudo_refresh
export -f sudo_need_refresh
export -f sudo_timeout_info
export -f validate_sudo_config

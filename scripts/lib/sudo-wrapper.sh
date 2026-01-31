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

# sudo_need_refresh determines whether the sudo timestamp should be refreshed when more than 300 seconds have elapsed since _SUDO_LAST_REFRESH. It returns success (0) if a refresh is needed, failure (1) otherwise.
sudo_need_refresh() {
    local now
    now=$(date +%s)

    # Refresh if we haven't in the last 5 minutes (half of default timeout)
    if [[ $((now - _SUDO_LAST_REFRESH)) -gt 300 ]]; then
        return 0
    fi
    return 1
}

# sudo_refresh refreshes the sudo credential timestamp to extend the sudo timeout.
# If run as root, updates _SUDO_LAST_REFRESH and returns. If not root, attempts a non-interactive sudo refresh;
# on success updates _SUDO_LAST_REFRESH, on failure prints an error and exits with status 1.
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
# ensure_elevated ensures the current script is running as root; if not, it attempts to authenticate via sudo and re-executes the script with elevated privileges, or prints errors and exits on failure.
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
# check_elevated ensures the script is running as root; if not, it prints instructions for running with sudo and exits with status 1.
# When already running as root the function returns with status 0.
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

# sudo_timeout_info reports the current sudo credential caching status and prints the default timeout, instructions to change it, and a note that this script refreshes credentials during long operations.
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

# validate_sudo_config validates that the current user (SUDO_USER or USER) is a member of the sudo group; prints instructions to add the user to the sudo group and returns 1 if not, returns 0 otherwise.
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
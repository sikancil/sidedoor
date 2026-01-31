#!/usr/bin/env bash
#
# Sidedoor Bootstrap Installer
# Curl-based installer for single-command deployment
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | bash
#
# Environment Variables:
#   SIDEDOOR_BRANCH           Git branch to clone (default: wizard)
#   SIDEDOOR_USER             Service user name (default: ubuntu)
#   SKIP_SETUP                Skip setup.sh execution (default: false)
#   MIGRATE_SSH_PRIVATE_KEYS  Include private keys in SSH migration (default: false)
#
# Examples:
#   # Standard installation
#   curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | bash
#
#   # Custom branch
#   curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | BRANCH=main bash
#
#   # Custom user
#   curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | SERVICE_USER=sidedoor bash
#
#   # With SSH private key migration
#   curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | MIGRATE_SSH_PRIVATE_KEYS=true bash
#

set -euo pipefail

# ========== CONFIGURATION ==========
REPO_URL="https://github.com/sikancil/sidedoor.git"
BRANCH="${SIDEDOOR_BRANCH:-wizard}"
SERVICE_USER="${SIDEDOOR_USER:-ubuntu}"
SKIP_SETUP="${SKIP_SETUP:-false}"
MIGRATE_SSH_PRIVATE_KEYS="${MIGRATE_SSH_PRIVATE_KEYS:-false}"
CLONE_DIR_BASE="/tmp/sidedoor-bootstrap"

# Global for cleanup trap access
CLONE_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========== UTILITY FUNCTIONS ==========

log() {
    echo -e "${GREEN}[INSTALL]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

header() {
    echo ""
    echo -e "${BLUE}===============================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}===============================================================${NC}"
    echo ""
}

# ========== VALIDATION FUNCTIONS ==========

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot determine OS version"
        exit 1
    fi

    if ! grep -q "Ubuntu" /etc/os-release; then
        error "This installer is designed for Ubuntu systems only"
        local os_name
        os_name=$(grep "^ID=" /etc/os-release | cut -d'=' -f2)
        error "Detected OS: $os_name"
        exit 1
    fi

    local ubuntu_version
    ubuntu_version=$(grep "VERSION_ID" /etc/os-release | cut -d'"' -f2)
    log "Ubuntu version: $ubuntu_version"
}

# ========== INSTALLATION FUNCTIONS ==========

install_minimal_deps() {
    header "Installing Minimal Dependencies"

    # Wait for APT lock (unattended-updates may be running on fresh droplet)
    log "Waiting for APT lock..."
    local max_wait=60
    local waited=0
    while fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [[ $waited -ge $max_wait ]]; then
            warn "APT lock wait timeout, attempting to continue..."
            break
        fi
        sleep 2
        ((waited += 2))
    done

    log "Updating package list..."
    apt-get update -qq

    local packages=(
        "git"
        "curl"
        "jq"
        "unzip"
        "ca-certificates"
    )

    log "Installing: ${packages[*]}"
    apt-get install -y -qq "${packages[@]}" >/dev/null 2>&1

    log "Dependencies installed"
}

create_user_smart() {
    header "Configuring Service User"

    # Check if user exists
    if id "$SERVICE_USER" &>/dev/null; then
        log "User $SERVICE_USER already exists"

        # Check for required groups
        local user_groups
        user_groups=$(groups "$SERVICE_USER")
        local missing_groups=()

        if ! echo "$user_groups" | grep -q "sudo"; then
            missing_groups+=("sudo")
        fi
        if ! echo "$user_groups" | grep -q "www-data"; then
            missing_groups+=("www-data")
        fi

        # Add missing groups
        if [[ ${#missing_groups[@]} -gt 0 ]]; then
            log "Adding missing groups: ${missing_groups[*]}"
            for group in "${missing_groups[@]}"; do
                usermod -aG "$group" "$SERVICE_USER"
                log "  Added to $group group"
            done
        else
            log "User has all required groups"
        fi

        return 0
    fi

    # Create new user
    log "Creating user: $SERVICE_USER"
    if [[ "$SERVICE_USER" == "ubuntu" ]]; then
        useradd -m -s /bin/bash ubuntu 2>/dev/null || true
    else
        useradd -r -s /bin/bash "$SERVICE_USER"
    fi

    # Add to required groups
    usermod -aG sudo "$SERVICE_USER"
    usermod -aG www-data "$SERVICE_USER"

    log "User $SERVICE_USER created with required groups"
}

configure_git() {
    header "Configuring Git"

    log "Setting up git configuration for $SERVICE_USER"

    # Configure git for the service user
    su - "$SERVICE_USER" -c "git config --global user.name 'Sidedoor Installer'" 2>/dev/null || true
    su - "$SERVICE_USER" -c "git config --global user.email 'installer@sidedoor.local'" 2>/dev/null || true
    su - "$SERVICE_USER" -c "git config --global init.defaultBranch main'" 2>/dev/null || true

    log "Git configured"
}

clone_repo() {
    local clone_dir="${CLONE_DIR_BASE}-$$"
    local clone_attempts=0
    local max_attempts=3

    # Output header to stderr (not captured by command substitution)
    header "Cloning Repository" >&2

    while [[ $clone_attempts -lt $max_attempts ]]; do
        # Output log to stderr
        log "Cloning from $REPO_URL (branch: $BRANCH)..." >&2

        if git clone -b "$BRANCH" --depth 1 "$REPO_URL" "$clone_dir" 2>/dev/null; then
            log "Repository cloned successfully to $clone_dir" >&2
            # Output ONLY the directory path to stdout (for command substitution)
            echo "$clone_dir"
            return 0
        fi

        ((clone_attempts++))
        if [[ $clone_attempts -lt $max_attempts ]]; then
            warn "Clone attempt $clone_attempts failed, retrying..." >&2
            sleep 2
        fi
    done

    error "Failed to clone repository after $max_attempts attempts" >&2
    exit 1
}

delegate_to_setup() {
    local clone_dir=$1

    header "Delegating to Setup Script"

    local setup_script="$clone_dir/scripts/setup.sh"

    if [[ ! -f "$setup_script" ]]; then
        error "Setup script not found at $setup_script"
        rm -rf "$clone_dir"
        exit 1
    fi

    # Source the SSH migration library for migration before setup
    local ssh_migrate_lib="$clone_dir/scripts/lib/ssh-migrate.sh"
    if [[ -f "$ssh_migrate_lib" ]]; then
        source "$ssh_migrate_lib"

        # Perform SSH migration if needed
        if [[ "${SSH_MIGRATION_NEEDED:-false}" == "true" ]] && [[ "$SERVICE_USER" != "root" ]]; then
            if [[ "$MIGRATE_SSH_PRIVATE_KEYS" == "true" ]]; then
                log "Migrating SSH keys from root to $SERVICE_USER (including private keys)..."
                ssh_migrate_keys "$SERVICE_USER" "true"
            else
                log "Migrating SSH keys from root to $SERVICE_USER (public keys only)..."
                ssh_migrate_keys "$SERVICE_USER" "false"
            fi
        fi
    fi

    # Build setup command with optional flags
    local setup_cmd="bash \"$setup_script\" --user \"$SERVICE_USER\""
    if [[ "$MIGRATE_SSH_PRIVATE_KEYS" == "true" ]]; then
        setup_cmd="$setup_cmd --migrate-ssh-private-keys"
    fi

    log "Executing: $setup_cmd"
    echo ""

    # Run setup script and capture exit code
    eval "$setup_cmd"
    local exit_code=$?

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        log "Setup completed successfully"
    else
        error "Setup failed with exit code $exit_code"
    fi

    return $exit_code
}

cleanup() {
    # Skip cleanup if we're in SKIP_SETUP mode (CLONE_DIR should be preserved)
    if [[ "$SKIP_SETUP" == "true" ]]; then
        return 0
    fi

    # Only remove our specific clone directory
    if [[ -n "$CLONE_DIR" ]] && [[ -d "$CLONE_DIR" ]]; then
        log "Removing temporary clone directory: $CLONE_DIR"
        rm -rf "$CLONE_DIR" 2>/dev/null || true
    fi

    log "Cleanup complete"
}

# ========== MAIN FUNCTION ==========

main() {
    # Source wrapper libraries (available after cloning, but we need them before)
    # For now, define inline functions that will be available
    # The actual libraries will be sourced after cloning

    echo ""
    echo "============================================"
    echo "  Sidedoor SSH/SFTP Certificate Management"
    echo "  Bootstrap Installer"
    echo "============================================"
    echo ""
    echo -e "Branch:       ${GREEN}$BRANCH${NC}"
    echo -e "Service User: ${GREEN}$SERVICE_USER${NC}"
    echo -e "Repository:   ${GREEN}$REPO_URL${NC}"
    echo ""

    # Set trap for cleanup on exit (use global CLONE_DIR)
    trap cleanup EXIT

    # Check root/sudo elevation (inline for bootstrap)
    if [[ $EUID -ne 0 ]]; then
        if ! command -v sudo &>/dev/null; then
            error "This script requires root privileges"
            error "Sudo is not available on this system"
            exit 1
        fi
        if ! sudo -v &>/dev/null; then
            error "This script requires root privileges"
            error "Sudo authentication failed"
            exit 1
        fi
        log "🔐 Elevating privileges with sudo..."
        exec sudo "$0" "$@"
    fi

    # Run installation phases
    check_os
    install_minimal_deps
    create_user_smart

    # SSH migration from root to service user
    if [[ "$SERVICE_USER" != "root" ]] && id "$SERVICE_USER" &>/dev/null; then
        if [[ -d /root/.ssh ]]; then
            log "Checking for SSH migration from root..."
            # We'll do the actual migration after cloning when libraries are available
            SSH_MIGRATION_NEEDED="true"
        fi
    fi

    configure_git
    CLONE_DIR=$(clone_repo)

    # Delegate to setup.sh unless skipped
    if [[ "$SKIP_SETUP" == "true" ]]; then
        warn "SKIP_SETUP=true, skipping setup.sh execution"
        warn "Clone directory: $CLONE_DIR"
        warn "To run setup manually: sudo bash $CLONE_DIR/scripts/setup.sh --user $SERVICE_USER"

        # Cancel the trap so we don't clean up the directory
        trap - EXIT

        exit 0
    fi

    # Run setup and capture exit code
    delegate_to_setup "$CLONE_DIR"
    local exit_code=$?

    # Exit with setup script's exit code
    # Cleanup will happen automatically via trap
    exit $exit_code
}

# Run main function
main "$@"

#!/usr/bin/env bash
#
# Sidedoor Bootstrap Installer
# Curl-based installer for single-command deployment
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | bash
#
# Environment Variables:
#   SIDEDOOR_BRANCH      Git branch to clone (default: wizard)
#   SIDEDOOR_USER        Service user name (default: ubuntu)
#   SKIP_SETUP           Skip setup.sh execution (default: false)
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

set -euo pipefail

# ========== CONFIGURATION ==========
REPO_URL="https://github.com/sikancil/sidedoor.git"
BRANCH="${SIDEDOOR_BRANCH:-wizard}"
SERVICE_USER="${SIDEDOOR_USER:-ubuntu}"
SKIP_SETUP="${SKIP_SETUP:-false}"
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
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ========== VALIDATION FUNCTIONS ==========

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        error "Please use: sudo $0"
        exit 1
    fi
    log "Running as root"
}

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
    header "Cloning Repository"

    local clone_dir="${CLONE_DIR_BASE}-$$"
    local clone_attempts=0
    local max_attempts=3

    while [[ $clone_attempts -lt $max_attempts ]]; do
        log "Cloning from $REPO_URL (branch: $BRANCH)..."

        if git clone -b "$BRANCH" --depth 1 "$REPO_URL" "$clone_dir" 2>/dev/null; then
            log "Repository cloned successfully to $clone_dir"
            echo "$clone_dir"
            return 0
        fi

        ((clone_attempts++))
        if [[ $clone_attempts -lt $max_attempts ]]; then
            warn "Clone attempt $clone_attempts failed, retrying..."
            sleep 2
        fi
    done

    error "Failed to clone repository after $max_attempts attempts"
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

    log "Executing: bash $setup_script --user $SERVICE_USER"
    echo ""

    # Run setup script and capture exit code
    bash "$setup_script" --user "$SERVICE_USER"
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
    header "Cleanup"

    if [[ -n "$CLONE_DIR" ]] && [[ -d "$CLONE_DIR" ]]; then
        log "Removing temporary clone directory: $CLONE_DIR"
        rm -rf "$CLONE_DIR"
    fi

    # Clean up any old bootstrap directories (skip if CLONE_DIR is still active)
    find "$CLONE_DIR_BASE"* -maxdepth 0 -mtime +1 2>/dev/null | while read -r old_dir; do
        if [[ -d "$old_dir" ]] && [[ "$old_dir" != "$CLONE_DIR" ]]; then
            log "Removing old bootstrap directory: $old_dir"
            rm -rf "$old_dir"
        fi
    done

    log "Cleanup complete"
}

# ========== MAIN FUNCTION ==========

main() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                                   ║${NC}"
    echo -e "${CYAN}║   ${NC}Sidedoor SSH/SFTP Certificate Management${NC}                 ${CYAN}║${NC}"
    echo -e "${CYAN}║   ${NC}Bootstrap Installer${NC}                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║                                                                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Branch:       ${GREEN}$BRANCH${NC}"
    echo -e "Service User: ${GREEN}$SERVICE_USER${NC}"
    echo -e "Repository:   ${GREEN}$REPO_URL${NC}"
    echo ""

    # Set trap for cleanup on exit (use global CLONE_DIR)
    trap cleanup EXIT

    # Run installation phases
    check_root
    check_os
    install_minimal_deps
    create_user_smart
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

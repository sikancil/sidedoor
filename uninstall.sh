#!/usr/bin/env bash
#
# Sidedoor Uninstaller
# Curl-based uninstaller for single-command removal
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/uninstall.sh | bash
#
# Environment Variables:
#   SIDEDOOR_BRANCH    Git branch to clone (default: wizard)
#   DRY_RUN            Preview without actual deletion (default: false)
#
# Examples:
#   # Standard uninstall
#   curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/uninstall.sh | bash
#
#   # Dry run (safe preview)
#   curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/uninstall.sh | DRY_RUN=true bash
#
#   # Custom branch
#   curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/uninstall.sh | BRANCH=main bash
#

set -euo pipefail

# ========== CONFIGURATION ==========
REPO_URL="https://github.com/sikancil/sidedoor.git"
BRANCH="${SIDEDOOR_BRANCH:-wizard}"
DRY_RUN="${DRY_RUN:-false}"
CLONE_DIR_BASE="/tmp/sidedoor-uninstall-$$"

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            echo "Sidedoor Uninstaller - Remove all Sidedoor installation artifacts"
            echo ""
            echo "Usage: $0 [--dry-run]"
            echo ""
            echo "Options:"
            echo "  --dry-run    Preview what would be removed without actual deletion"
            echo "  -h, --help   Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# log prints an informational message prefixed with a green `[UNINSTALL]` tag.

log() {
    echo -e "${GREEN}[UNINSTALL]${NC} $1"
}

# warn prints a warning message prefixed with a yellow "[WARNING]" label to stdout.
warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# error echoes the given message prefixed with a red `[ERROR]` label.
error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# info prints an informational message prefixed with a cyan "[INFO]" tag.
info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

# header prints a formatted, colored section header to stdout.
# Takes one argument: the header text to display.
header() {
    echo ""
    echo -e "${BLUE}===============================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}===============================================================${NC}"
    echo ""
}

# check_os verifies the host is Ubuntu and logs its VERSION_ID; if the OS cannot be determined or is not Ubuntu, it prints an error and exits with status 1.

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot determine OS version"
        exit 1
    fi

    if ! grep -q "Ubuntu" /etc/os-release; then
        error "This uninstaller is designed for Ubuntu systems only"
        local os_name
        os_name=$(grep "^ID=" /etc/os-release | cut -d'=' -f2)
        error "Detected OS: $os_name"
        exit 1
    fi

    local ubuntu_version
    ubuntu_version=$(grep "VERSION_ID" /etc/os-release | cut -d'"' -f2)
    log "Ubuntu version: $ubuntu_version"
}

# install_minimal_deps waits for APT locks (up to 60s), updates apt package lists, and installs Git and curl quietly.
# It prints progress headers and messages, attempts to continue if the lock wait times out, and suppresses package manager output.

install_minimal_deps() {
    header "Installing Minimal Dependencies"

    # Wait for APT lock
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
    )

    log "Installing: ${packages[*]}"
    apt-get install -y -qq "${packages[@]}" >/dev/null 2>&1

    log "Dependencies installed"
}

# clone_repo attempts to clone the configured repository and branch into the temporary clone directory, retrying up to three times and exiting with an error if all attempts fail.
clone_repo() {
    header "Cloning Repository"

    local clone_attempts=0
    local max_attempts=3

    while [[ $clone_attempts -lt $max_attempts ]]; do
        log "Cloning from $REPO_URL (branch: $BRANCH)..."

        if git clone -b "$BRANCH" --depth 1 "$REPO_URL" "$CLONE_DIR_BASE" 2>/dev/null; then
            log "Repository cloned successfully to $CLONE_DIR_BASE"
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

# delegate_to_uninstall delegates execution to the cloned repository's uninstall.sh, passes `--dry-run` when DRY_RUN is true, validates the script exists (removing the clone and exiting on missing), runs the script, logs success or failure, and returns the uninstall script's exit code.
delegate_to_uninstall() {
    header "Delegating to Uninstall Script"

    local uninstall_script="$CLONE_DIR_BASE/scripts/uninstall.sh"

    if [[ ! -f "$uninstall_script" ]]; then
        error "Uninstall script not found at $uninstall_script"
        rm -rf "$CLONE_DIR_BASE"
        exit 1
    fi

    # Build uninstall command with optional flags
    local uninstall_cmd="bash \"$uninstall_script\""
    if [[ "$DRY_RUN" == "true" ]]; then
        uninstall_cmd="$uninstall_cmd --dry-run"
    fi

    log "Executing: $uninstall_cmd"
    echo ""

    # Run uninstall script and capture exit code
    eval "$uninstall_cmd"
    local exit_code=$?

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        log "Uninstall completed successfully"
    else
        error "Uninstall failed with exit code $exit_code"
    fi

    return $exit_code
}

# cleanup removes the temporary clone directory specified by CLONE_DIR_BASE if it exists.
cleanup() {
    # Remove clone directory
    if [[ -n "$CLONE_DIR_BASE" ]] && [[ -d "$CLONE_DIR_BASE" ]]; then
        log "Removing temporary clone directory: $CLONE_DIR_BASE"
        rm -rf "$CLONE_DIR_BASE" 2>/dev/null || true
    fi
}

# main displays the banner and active configuration, ensures root privileges (re-executes with sudo if needed while preserving DRY_RUN), registers cleanup on exit, runs OS validation, installs minimal dependencies, clones the repository, delegates to the repository's uninstall script, and exits with that script's exit code.

main() {
    echo ""
    echo "============================================"
    echo "  Sidedoor SSH/SFTP Certificate Management"
    echo "  Remote Uninstaller"
    echo "============================================"
    echo ""
    echo -e "Branch:   ${GREEN}$BRANCH${NC}"
    echo -e "Dry Run:  ${GREEN}$DRY_RUN${NC}"
    echo -e "Repository: ${GREEN}$REPO_URL${NC}"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY-RUN MODE: No actual changes will be made"
        echo ""
    fi

    # Set trap for cleanup on exit
    trap cleanup EXIT

    # Check root/sudo elevation
    if [[ $EUID -ne 0 ]]; then
        if ! command -v sudo &>/dev/null; then
            error "This script requires root privileges"
            error "Sudo is not available on this system"
            exit 1
        fi
        # Use sudo -n for non-interactive check (works with curl pipes)
        if ! sudo -n true &>/dev/null; then
            error "This script requires root privileges"
            error "Sudo authentication failed or passwordless sudo not configured"
            error "Please ensure passwordless sudo is enabled for the current user"
            exit 1
        fi
        log "Elevating privileges with sudo..."
        # Re-run script with sudo, explicitly passing DRY_RUN
        if [[ "$DRY_RUN" == "true" ]]; then
            exec sudo env DRY_RUN=true "$0" "$@"
        else
            exec sudo "$0" "$@"
        fi
    fi

    # Run uninstallation phases
    check_os
    install_minimal_deps
    clone_repo

    # Run uninstall and capture exit code
    delegate_to_uninstall
    local exit_code=$?

    # Exit with uninstall script's exit code
    # Cleanup will happen automatically via trap
    exit $exit_code
}

# Run main function
main "$@"
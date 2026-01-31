#!/usr/bin/env bash
#
# Sidedoor Setup Rollback Script
# Removes all components installed by setup-production.sh
#
# Usage:
#   sudo ./scripts/rollback-setup.sh [--full-reset] [--keep-logs] [--rollback-ssh-migration]
#
# Options:
#   --full-reset             Remove user (if not ubuntu), database, and all traces
#   --keep-logs              Preserve log files for debugging
#   --rollback-ssh-migration Remove SSH keys migrated from root
#   -h, --help               Show this help message
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source SSH migration library if available
if [[ -f "$SCRIPT_DIR/lib/ssh-migrate.sh" ]]; then
    source "$SCRIPT_DIR/lib/ssh-migrate.sh"
fi

# Default values
SERVICE_USER="${SERVICE_USER:-sidedoor}"
FULL_RESET=false
KEEP_LOGS=false
ROLLBACK_SSH_MIGRATION=false

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# show_help displays the script's help text extracted from the rollback-setup.sh header and exits with status 0.
show_help() {
    grep '^#' "$SCRIPT_DIR/rollback-setup.sh" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --full-reset)
            FULL_RESET=true
            shift
            ;;
        --keep-logs)
            KEEP_LOGS=true
            shift
            ;;
        --rollback-ssh-migration)
            ROLLBACK_SSH_MIGRATION=true
            shift
            ;;
        --user)
            SERVICE_USER="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            ;;
    esac
done

# Safety check: prevent running on non-Ubuntu systems
if [[ ! -f /etc/os-release ]] || ! grep -q "Ubuntu" /etc/os-release; then
    echo -e "${RED}ERROR: This script is designed for Ubuntu systems only${NC}"
    exit 1
fi

# Require root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    echo "Use: sudo $0 $@"
    exit 1
fi

# log prints a message prefixed with a green "[ROLLBACK]" tag to stdout.
log() {
    echo -e "${GREEN}[ROLLBACK]${NC} $1"
}

# warn prints a yellow "[WARNING]"-prefixed message to stdout using the YELLOW/NC color variables and accepts a single message argument.
warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# error prints an error message prefixed with a red "[ERROR]" tag.
error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Confirm before proceeding
echo ""
echo -e "${YELLOW}===============================================================${NC}"
echo -e "${YELLOW}  ⚠️  SIDEDOOR SETUP ROLLBACK ⚠️${NC}"
echo -e "${YELLOW}===============================================================${NC}"
echo ""
echo "This will remove:"
echo "  - Systemd service: sidedoor.service"
if [[ "$FULL_RESET" == "true" ]]; then
    echo "  - Service user: $SERVICE_USER (if not 'ubuntu')"
    echo "  - Application directory: /opt/sidedoor"
    echo "  - Configuration: /etc/sidedoor"
    echo "  - Database: /var/lib/sidedoor"
else
    echo "  - Systemd timers (all sidedoor-* timers)"
fi
echo "  - SSH configuration: /etc/ssh/sshd_config.d/sidedoor.conf"
echo "  - Sudoers: /etc/sudoers.d/sidedoor"
echo "  - State file: /var/lib/sidedoor/.setup-state"
if [[ "$ROLLBACK_SSH_MIGRATION" == "true" ]]; then
    echo "  - SSH keys migrated from root to $SERVICE_USER"
fi
if [[ "$KEEP_LOGS" == "false" ]]; then
    echo "  - Logs: /var/log/sidedoor"
fi
echo ""
read -p "Continue? (yes/no): " -r
echo

if [[ ! "$REPLY" =~ ^[Yy][Ee][Ss]$ ]]; then
    log "Rollback cancelled"
    exit 0
fi

# ========== PHASE 1: Stop and Disable Service ==========
log "Phase 1: Stopping and disabling systemd service..."

if systemctl is-active --quiet sidedoor 2>/dev/null; then
    systemctl stop sidedoor
    log "Stopped sidedoor.service"
fi

if systemctl is-enabled --quiet sidedoor 2>/dev/null; then
    systemctl disable sidedoor
    log "Disabled sidedoor.service"
fi

# Remove all sidedoor timers
log "Removing systemd timers..."
for timer_file in /etc/systemd/system/sidedoor-*.timer; do
    if [[ -f "$timer_file" ]]; then
        timer_name=$(basename "$timer_file" .timer)
        systemctl stop "${timer_name}.timer" 2>/dev/null || true
        systemctl disable "${timer_name}.timer" 2>/dev/null || true
        rm -f "$timer_file"
        rm -f "${timer_file%.timer}.service"
        log "Removed timer: $timer_name"
    fi
done

systemctl daemon-reload

# ========== PHASE 2: Remove Systemd Service File ==========
log "Phase 2: Removing systemd service file..."

rm -f /etc/systemd/system/sidedoor.service
systemctl daemon-reload
log "Removed sidedoor.service"

# ========== PHASE 3: Remove SSH Configuration ==========
log "Phase 3: Removing SSH configuration..."

rm -f /etc/ssh/sshd_config.d/sidedoor.conf

# Test and reload SSH if config was removed
if command -v sshd &> /dev/null; then
    sshd -t && systemctl reload sshd 2>/dev/null || systemctl restart sshd
    log "Removed SSH chroot configuration and reloaded sshd"
fi

# ========== PHASE 4: Remove Sudoers Configuration ==========
log "Phase 4: Removing sudoers configuration..."

rm -f /etc/sudoers.d/sidedoor
log "Removed sudoers configuration"

# ========== PHASE 5: Full Reset (if requested) ==========
if [[ "$FULL_RESET" == "true" ]]; then
    log "Phase 5: Performing full reset..."

    # Remove application directory
    if [[ -d /opt/sidedoor ]]; then
        rm -rf /opt/sidedoor
        log "Removed /opt/sidedoor"
    fi

    # Remove configuration directory
    if [[ -d /etc/sidedoor ]]; then
        rm -rf /etc/sidedoor
        log "Removed /etc/sidedoor"
    fi

    # Remove data directory (but keep logs if requested)
    if [[ -d /var/lib/sidedoor ]]; then
        if [[ "$KEEP_LOGS" == "true" ]]; then
            # Only remove database, keep logs
            rm -f /var/lib/sidedoor/certificates.db
            log "Removed database (logs preserved)"
        else
            rm -rf /var/lib/sidedoor
            log "Removed /var/lib/sidedoor"
        fi
    fi

    # Remove service user (if not ubuntu)
    if [[ "$SERVICE_USER" != "ubuntu" ]] && id "$SERVICE_USER" &>/dev/null; then
        # Kill any processes owned by the user
        pkill -u "$SERVICE_USER" 2>/dev/null || true
        sleep 1

        # Remove user
        userdel -r "$SERVICE_USER" 2>/dev/null || true
        log "Removed user: $SERVICE_USER"
    fi
fi

# ========== PHASE 6: Remove Logs (if not keeping) ==========
if [[ "$KEEP_LOGS" == "false" ]]; then
    log "Phase 6: Removing logs..."
    rm -rf /var/log/sidedoor
    log "Removed /var/log/sidedoor"
fi

# ========== PHASE 7: Remove State File ==========
log "Phase 7: Removing state tracking file..."

rm -f /var/lib/sidedoor/.setup-state
log "Removed .setup-state"

# ========== PHASE 7.5: Rollback SSH Migration (if requested) ==========
if [[ "$ROLLBACK_SSH_MIGRATION" == "true" ]] && declare -f ssh_rollback_migration &>/dev/null; then
    log "Phase 7.5: Rolling back SSH migration..."

    # Try both with and without private keys flag
    ssh_rollback_migration "$SERVICE_USER" "false" 2>/dev/null || true
    ssh_rollback_migration "$SERVICE_USER" "true" 2>/dev/null || true

    # Also remove the SSH migration state file
    rm -f /etc/sidedoor/.ssh-migration-state
    log "Removed SSH migration state"
fi

# ========== PHASE 8: Remove Chroot Base Directory ==========
log "Phase 8: Cleaning up chroot directories..."

if [[ "$FULL_RESET" == "true" ]] && [[ -d /home/sftp ]]; then
    # Remove all user chroots
    for chroot_dir in /home/sftp/n0x*; do
        if [[ -d "$chroot_dir" ]]; then
            # Unmount any bind mounts
            mount | grep "$chroot_dir" | awk '{print $3}' | while read mountpoint; do
                umount -l "$mountpoint" 2>/dev/null || true
            done
            rm -rf "$chroot_dir"
            log "Removed chroot: $chroot_dir"
        fi
    done

    # Remove base directory if empty
    rmdir /home/sftp 2>/dev/null || true
fi

# ========== SUMMARY ==========
echo ""
echo -e "${GREEN}===============================================================${NC}"
echo -e "${GREEN}  ✅ ROLLBACK COMPLETE${NC}"
echo -e "${GREEN}===============================================================${NC}"
echo ""
echo "Removed components:"
echo "  ✓ Systemd service and timers"
echo "  ✓ SSH chroot configuration"
echo "  ✓ Sudoers configuration"
echo "  ✓ State tracking file"
if [[ "$ROLLBACK_SSH_MIGRATION" == "true" ]]; then
    echo "  ✓ SSH migration state"
fi
if [[ "$FULL_RESET" == "true" ]]; then
    echo "  ✓ Application files"
    echo "  ✓ Configuration files"
    echo "  ✓ Database"
    if [[ "$SERVICE_USER" != "ubuntu" ]]; then
        echo "  ✓ Service user: $SERVICE_USER"
    fi
fi
if [[ "$KEEP_LOGS" == "false" ]]; then
    echo "  ✓ Log files"
else
    echo "  ⚠ Logs preserved at: /var/log/sidedoor"
fi
echo ""
log "Rollback completed successfully"
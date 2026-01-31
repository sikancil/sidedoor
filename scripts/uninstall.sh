#!/usr/bin/env bash
#
# Sidedoor Uninstall Script
# Removes all Sidedoor installation artifacts while preserving users, SSH keys, and source directories
#
# Usage:
#   sudo ./scripts/uninstall.sh [--dry-run] [-h|--help]
#
# Options:
#   --dry-run       Preview what would be removed without actual deletion
#   -h, --help      Show this help message
#
# What gets REMOVED:
#   - Sidedoor service and systemd timers
#   - Dynamic n0x* certificate users
#   - SQLite database at /var/lib/sidedoor/certificates.db
#   - Configuration files at /etc/sidedoor/
#   - SSH config at /etc/ssh/sshd_config.d/sidedoor.conf
#   - Application files at /opt/sidedoor/
#   - State files (.setup-state, .ssh-migration-state)
#   - Cloned repository (on remote systems only)
#   - Chroot bind mounts (NOT source directories)
#   - SFTP base directory /home/sftp/ (if empty)
#
# What gets PRESERVED:
#   - Service users (ubuntu, SERVICE_USER)
#   - All SSH keys in ~/.ssh/*
#   - Local codebase at /Users/dimasarif/DATA/WORK/Pegasus/vm-access/
#   - Source directories behind chroot bind mounts
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source logging library
source "$SCRIPT_DIR/lib/logging.sh"

# Default values
DRY_RUN=false
LOCAL_DEV_PATH="/Users/dimasarif/DATA/WORK/Pegasus/vm-access"

# Tracking variables for summary
SERVICES_STOPPED=0
TIMERS_REMOVED=0
USERS_REMOVED=0
FILES_REMOVED=0
MOUNTS_UNMOUNTED=0
TOTAL_SIZE_BYTES=0

# show_help displays usage, available options, a concise list of removed vs. preserved artifacts, example invocations, and exits the script.
show_help() {
    cat << EOF
Sidedoor Uninstall Script - Remove all Sidedoor installation artifacts

Usage: sudo $0 [OPTIONS]

Options:
  --dry-run       Preview what would be removed without actual deletion
  -h, --help      Show this help message

What gets REMOVED:
  - Sidedoor service and all systemd timers
  - Dynamic n0x* certificate users (e.g., n0x1a2b3c)
  - SQLite certificate database
  - Configuration files
  - SSH config at /etc/ssh/sshd_config.d/sidedoor.conf
  - Application files at /opt/sidedoor/
  - State files (.setup-state, .ssh-migration-state)
  - Cloned repository (remote only)
  - Chroot bind mounts (NOT source directories)
  - SFTP base directory /home/sftp/ (if empty)

What gets PRESERVED:
  - Service users (ubuntu, SERVICE_USER)
  - All SSH keys in ~/.ssh/*
  - Local codebase
  - Source directories behind chroot bind mounts

Examples:
  # Preview what would be removed
  sudo $0 --dry-run

  # Actual uninstall
  sudo $0

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# dry_run_log prints a prefixed dry-run message when DRY_RUN is true.

dry_run_log() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $1"
    fi
}

# ========== UTILITY FUNCTIONS ==========

# format_size converts a byte count into a human-readable string using B, KB, MB, or GB units.
format_size() {
    local bytes=$1
    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ $bytes -lt 1048576 ]]; then
        echo "$((bytes / 1024))KB"
    elif [[ $bytes -lt 1073741824 ]]; then
        echo "$((bytes / 1048576))MB"
    else
        echo "$((bytes / 1073741824))GB"
    fi
}

# get_size prints the size in bytes of the given file or directory, or 0 if the path does not exist or the size cannot be determined.
get_size() {
    local path=$1
    if [[ -d "$path" ]]; then
        du -sb "$path" 2>/dev/null | cut -f1 || echo "0"
    elif [[ -f "$path" ]]; then
        stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# run_rm safely removes a file or directory (or reports the planned removal when DRY_RUN is true), updates TOTAL_SIZE_BYTES and FILES_REMOVED, and logs success or failure.
run_rm() {
    local description=$1
    local path=$2
    local force=${3:-false}

    if [[ ! -e "$path" ]]; then
        return 0
    fi

    local size
    size=$(get_size "$path")

    if [[ "$DRY_RUN" == true ]]; then
        local size_human
        size_human=$(format_size "$size")
        local file_count=""
        if [[ -d "$path" ]]; then
            file_count=$(find "$path" -type f 2>/dev/null | wc -l | tr -d ' ')
            dry_run_log "Would remove: $path ($size_human - $file_count files)"
        else
            dry_run_log "Would remove: $path ($size_human)"
        fi
        ((TOTAL_SIZE_BYTES += size))
        ((++FILES_REMOVED))
    else
        if [[ "$force" == true ]]; then
            rm -rf "$path" 2>/dev/null || true
        else
            rm -rf "$path" 2>/dev/null || true
        fi
        if [[ ! -e "$path" ]]; then
            log "Removed: $path"
            ((TOTAL_SIZE_BYTES += size))
            ((++FILES_REMOVED))
        else
            warn "Failed to remove: $path"
        fi
    fi
}

# run_rm_file removes the file at the given path if it exists and updates TOTAL_SIZE_BYTES and FILES_REMOVED; in dry-run mode it only logs the planned removal and still updates the counters.
run_rm_file() {
    local path=$1

    if [[ ! -f "$path" ]]; then
        return 0
    fi

    local size
    size=$(get_size "$path")

    if [[ "$DRY_RUN" == true ]]; then
        local size_human
        size_human=$(format_size "$size")
        dry_run_log "Would remove: $path ($size_human)"
        ((TOTAL_SIZE_BYTES += size))
        ((++FILES_REMOVED))
    else
        rm -f "$path" 2>/dev/null || true
        if [[ ! -f "$path" ]]; then
            log "Removed: $path"
            ((TOTAL_SIZE_BYTES += size))
            ((++FILES_REMOVED))
        fi
    fi
}

# run_umount safely unmounts the given mount point; in dry-run mode it logs the planned unmount (including source) and increments MOUNTS_UNMOUNTED without performing the unmount.
run_umount() {
    local mount_point=$1

    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        local source
        source=$(findmnt -n -o SOURCE "$mount_point" 2>/dev/null || echo "unknown")
        dry_run_log "Would unmount: $mount_point (from: $source)"
        ((++MOUNTS_UNMOUNTED))
    else
        if umount -l "$mount_point" 2>/dev/null; then
            log "Unmounted: $mount_point"
            ((++MOUNTS_UNMOUNTED))
        else
            warn "Failed to unmount: $mount_point"
        fi
    fi
}

# check_root ensures the script is run as root; if not, it logs an error, shows usage advice, and exits with status 1.

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        log "Use: sudo $0 $@"
        exit 1
    fi
}

# check_local_dev checks that the current working directory is not the configured local development path and exits with an error if it is.
check_local_dev() {
    local current_dir
    current_dir=$(pwd)

    if [[ "$current_dir" == "$LOCAL_DEV_PATH" ]]; then
        error "Cannot run uninstall from local development directory"
        log "This script is designed for remote systems only"
        log "Local path: $LOCAL_DEV_PATH"
        exit 1
    fi
}

# show_preserved_notice prints a notice explaining which user data and directories will be preserved (service user and SSH keys) and warns that dynamic certificate users (n0x*) will be removed.
show_preserved_notice() {
    echo ""
    echo -e "${YELLOW}=== NOTICE ===${NC}"
    log "The following will NOT be removed:"
    echo "  - ubuntu (or custom SERVICE_USER)"
    echo "  - Your SSH keys in ~/.ssh/* will be preserved"
    echo ""
    warn "Dynamic certificate users (n0x*) WILL be removed"
    echo ""
}

# phase_stop_services stops the main 'sidedoor' systemd service and any 'sidedoor-*.timer' units, incrementing SERVICES_STOPPED and TIMERS_REMOVED; in dry-run mode it only logs the planned stops.

phase_stop_services() {
    phase "PHASE 1: Stop Services"

    # Stop main service
    if systemctl is-active --quiet sidedoor 2>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            dry_run_log "Would stop service: sidedoor"
        else
            systemctl stop sidedoor 2>/dev/null || true
            log "Stopped service: sidedoor"
        fi
        ((++SERVICES_STOPPED))
    fi

    # Stop all timers
    local timers
    timers=$(systemctl list-units --all 'sidedoor-*.timer' 2>/dev/null | grep -oE 'sidedoor-[^[:space:]]+\.timer' || true)

    if [[ -n "$timers" ]]; then
        for timer in $timers; do
            if systemctl is-active --quiet "$timer" 2>/dev/null; then
                if [[ "$DRY_RUN" == true ]]; then
                    dry_run_log "Would stop timer: $timer"
                else
                    systemctl stop "$timer" 2>/dev/null || true
                    log "Stopped timer: $timer"
                fi
            fi
        done
        ((TIMERS_REMOVED += $(echo "$timers" | wc -l))) || true
    fi
}

# phase_remove_systemd_units removes Sidedoor-related systemd unit and timer files and reloads the systemd daemon.
# In non-dry-run mode it disables any matching timer/service units and deletes their unit files; in dry-run mode it only reports the actions and sizes that would be removed.

phase_remove_systemd_units() {
    phase "PHASE 2: Remove Systemd Units"

    local systemd_dir="/etc/systemd/system"

    # Remove timers
    for timer in "$systemd_dir"/sidedoor-*.timer; do
        [[ -f "$timer" ]] || continue
        local timer_name
        timer_name=$(basename "$timer")

        if [[ "$DRY_RUN" == true ]]; then
            local size
            size=$(get_size "$timer")
            dry_run_log "Would disable and remove: $timer ($(format_size "$size"))"
        else
            systemctl disable "$timer_name" 2>/dev/null || true
            rm -f "$timer"
            log "Removed timer: $timer_name"
        fi
    done

    # Remove main service
    if [[ -f "$systemd_dir/sidedoor.service" ]]; then
        run_rm_file "$systemd_dir/sidedoor.service"
        if [[ "$DRY_RUN" == false ]]; then
            systemctl disable sidedoor 2>/dev/null || true
            log "Disabled service: sidedoor"
        fi
    fi

    # Remove helper service
    if [[ -f "$systemd_dir/sidedoor-helper@.service" ]]; then
        run_rm_file "$systemd_dir/sidedoor-helper@.service"
    fi

    # Reload systemd
    if [[ "$DRY_RUN" == false ]]; then
        systemctl daemon-reload 2>/dev/null || true
        log "Reloaded systemd daemon"
    fi
}

# phase_remove_dynamic_users finds dynamic certificate users matching n0x[0-9a-f]{6}, kills any running processes for each user, and removes the user account and home directory (or logs the planned actions when running in dry-run mode), incrementing USERS_REMOVED for each user.

phase_remove_dynamic_users() {
    phase "PHASE 3: Remove Dynamic Certificate Users"

    # Find all n0x* users (6 hex chars)
    local users
    users=$(grep -E '^n0x[0-9a-f]{6}:' /etc/passwd 2>/dev/null | cut -d: -f1 || true)

    if [[ -z "$users" ]]; then
        info "No dynamic certificate users found"
        return
    fi

    for user in $users; do
        # Check for processes
        local proc_count=0
        proc_count=$(pgrep -u "$user" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        local home_dir
        home_dir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || echo "")

        if [[ "$DRY_RUN" == true ]]; then
            dry_run_log "Would remove user: $user (home: $home_dir, $proc_count processes)"
        else
            # Kill processes
            pkill -u "$user" 2>/dev/null || true
            # Delete user (removes home dir)
            userdel -r "$user" 2>/dev/null || true
            log "Removed user: $user"
        fi
        ((++USERS_REMOVED))
    done
}

# phase_cleanup_chroot_mounts cleans up SFTP chroot directories under /home/sftp by unmounting any mounted paths, removing broken symlinks inside chroot homes, and removing the /home/sftp base directory if it is empty.

phase_cleanup_chroot_mounts() {
    phase "PHASE 4: Cleanup Chroot Mounts"

    local sftp_base="/home/sftp"

    if [[ ! -d "$sftp_base" ]]; then
        info "No SFTP chroot directory found"
        return
    fi

    # Find all chroot directories
    for chroot in "$sftp_base"/*/; do
        [[ -d "$chroot" ]] || continue

        # Find all mount points under chroot
        while IFS= read -r mount; do
            run_umount "$mount"
        done < <(find "$chroot" -mindepth 1 -maxdepth 10 -xdev 2>/dev/null | while read -r dir; do
            mountpoint -q "$dir" 2>/dev/null && echo "$dir"
        done)
    done

    # Remove broken symlinks in chroot homes
    if [[ "$DRY_RUN" == false ]]; then
        for chroot in "$sftp_base"/*/; do
            [[ -d "$chroot" ]] || continue
            while IFS= read -r symlink; do
                if [[ -L "$symlink" && ! -e "$symlink" ]]; then
                    rm -f "$symlink"
                    log "Removed broken symlink: $symlink"
                fi
            done < <(find "$chroot" -type l 2>/dev/null)
        done
    fi

    # Remove SFTP base directory if empty (idempotent)
    if [[ -d "$sftp_base" ]]; then
        local remaining_items
        remaining_items=$(ls -A "$sftp_base" 2>/dev/null | wc -l | tr -d ' ') || true
        if [[ $remaining_items -eq 0 ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry_run_log "Would remove empty SFTP base directory: $sftp_base"
            else
                rm -rf "$sftp_base" 2>/dev/null || true
                log "Removed empty SFTP base directory: $sftp_base"
            fi
        else
            info "SFTP base directory not empty (contains $remaining_items items), skipping removal"
        fi
    fi
}

# phase_remove_database removes the Sidedoor certificates database, related state files and SQLite WAL files, and the /var/lib/sidedoor directory; in dry-run mode it only logs planned removals while updating size and removal counters.

phase_remove_database() {
    phase "PHASE 5: Remove Database and State Files"

    local db_path="/var/lib/sidedoor/certificates.db"
    local db_dir="/var/lib/sidedoor"

    # Remove setup state file first (before directory removal)
    if [[ -f "$db_dir/.setup-state" ]]; then
        run_rm_file "$db_dir/.setup-state"
    fi

    # Remove SSH migration state file first (before directory removal)
    if [[ -f "$db_dir/.ssh-migration-state" ]]; then
        run_rm_file "$db_dir/.ssh-migration-state"
    fi

    if [[ -f "$db_path" ]]; then
        local size
        size=$(get_size "$db_path")
        if [[ "$DRY_RUN" == true ]]; then
            dry_run_log "Would remove database: $db_path ($(format_size "$size"))"
        else
            rm -f "$db_path"
            log "Removed database: $db_path"
        fi
        ((TOTAL_SIZE_BYTES += size))
        ((++FILES_REMOVED))
    fi

    # Remove all SQLite WAL files (-shm, -wal) that may remain
    if [[ "$DRY_RUN" == false ]]; then
        rm -f "$db_dir"/certificates.db* 2>/dev/null || true
    else
        if [[ -f "$db_dir"/certificates.db-shm ]]; then
            local shm_size
            shm_size=$(get_size "$db_dir"/certificates.db-shm)
            dry_run_log "Would remove SQLite WAL: $db_dir/certificates.db-shm ($(format_size "$shm_size"))"
        fi
        if [[ -f "$db_dir"/certificates.db-wal ]]; then
            local wal_size
            wal_size=$(get_size "$db_dir"/certificates.db-wal)
            dry_run_log "Would remove SQLite WAL: $db_dir/certificates.db-wal ($(format_size "$wal_size"))"
        fi
    fi

    # Remove database directory (using rm -rf for idempotency)
    if [[ -d "$db_dir" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            local dir_size
            dir_size=$(get_size "$db_dir")
            dry_run_log "Would remove directory: $db_dir ($(format_size "$dir_size"))"
        else
            rm -rf "$db_dir" 2>/dev/null || true
            log "Removed directory: $db_dir"
        fi
    fi
}

# phase_remove_configuration removes Sidedoor configuration files under /etc/sidedoor and the sidedoor SSH snippet, deletes the config directory if it is empty, and reloads sshd when the SSH snippet is removed.

phase_remove_configuration() {
    phase "PHASE 6: Remove Configuration"

    local config_dir="/etc/sidedoor"

    if [[ -f "$config_dir/config.json" ]]; then
        run_rm_file "$config_dir/config.json"
    fi

    # Remove directory if empty
    if [[ -d "$config_dir" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            if [[ -z "$(ls -A "$config_dir" 2>/dev/null)" ]]; then
                dry_run_log "Would remove directory: $config_dir (if empty)"
            fi
        else
            rm -rf "$config_dir" 2>/dev/null || true
        fi
    fi

    # Remove SSH config
    local ssh_config="/etc/ssh/sshd_config.d/sidedoor.conf"
    if [[ -f "$ssh_config" ]]; then
        run_rm_file "$ssh_config"
        # Reload sshd to apply config changes
        if [[ "$DRY_RUN" == false ]]; then
            systemctl reload sshd 2>/dev/null || true
            log "Reloaded sshd service"
        else
            dry_run_log "Would reload sshd service"
        fi
    fi
}

# phase_remove_application_files removes Sidedoor's application directory (/opt/sidedoor) and the systemd helper binary (/usr/local/bin/sidedoor-systemd-helper) if they exist.

phase_remove_application_files() {
    phase "PHASE 7: Remove Application Files"

    # Remove app directory
    if [[ -d /opt/sidedoor ]]; then
        run_rm "Application directory" /opt/sidedoor true
    fi

    # Remove systemd helper script
    if [[ -f /usr/local/bin/sidedoor-systemd-helper ]]; then
        run_rm_file /usr/local/bin/sidedoor-systemd-helper
    fi
}

# phase_cleanup_remaining_artifacts removes empty chroot home directories under /home/sftp; in dry-run mode it logs planned removals instead of deleting.
# The operation is idempotent and silently no-ops if the sftp base directory does not exist or contains non-empty homes.

phase_cleanup_remaining_artifacts() {
    phase "PHASE 8: Cleanup Remaining Artifacts"

    local sftp_base="/home/sftp"

    # Remove any remaining empty chroot home directories (idempotent)
    if [[ -d "$sftp_base" ]]; then
        for chroot_home in "$sftp_base"/*/; do
            [[ -d "$chroot_home" ]] || continue
            local remaining_items
            remaining_items=$(ls -A "$chroot_home" 2>/dev/null | wc -l | tr -d ' ') || true
            if [[ $remaining_items -eq 0 ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    dry_run_log "Would remove empty chroot home: $chroot_home"
                else
                    rm -rf "$chroot_home" 2>/dev/null || true
                    log "Removed empty chroot home: $chroot_home"
                fi
            fi
        done
    fi
}

# phase_remove_repository_clone removes known Sidedoor repository clone directories from common locations, skipping removal when running from the local development path.

phase_remove_repository_clone() {
    phase "PHASE 9: Remove Repository Clone"

    local current_dir
    current_dir=$(pwd)

    # Skip if in local dev directory (already checked, but double-check)
    if [[ "$current_dir" == "$LOCAL_DEV_PATH" ]]; then
        info "Skipping clone removal in local development directory"
        return
    fi

    # Possible clone locations
    local clone_locations=(
        "/tmp/sidedoor-bootstrap-"*
        "/home/ubuntu/sidedoor"
        "/home/sidedoor/sidedoor"
        "/opt/sidedoor-bootstrap"
    )

    for clone_path in "${clone_locations[@]}"; do
        if [[ -d "$clone_path" ]]; then
            run_rm "Repository clone" "$clone_path" true
        fi
    done
}

# phase_verification verifies that no leftover Sidedoor components remain and logs warnings for any detected issues.
# It checks for an enabled service, remaining systemd timers, dynamic n0x users, the certificates database and its directory, and the Sidedoor SSH config; it reports a summary count of issues found.

phase_verification() {
    phase "PHASE 10: Verification"

    local issues=0

    # Check services
    if systemctl is-enabled --quiet sidedoor 2>/dev/null; then
        warn "Service still enabled: sidedoor"
        ((++issues))
    fi

    # Check timers
    local remaining_timers
    remaining_timers=$(ls /etc/systemd/system/sidedoor-*.timer 2>/dev/null | wc -l | tr -d ' ') || true
    remaining_timers=${remaining_timers:-0}
    if [[ $remaining_timers -gt 0 ]]; then
        warn "Remaining timers: $remaining_timers"
        ((++issues))
    fi

    # Check dynamic users
    local remaining_users
    remaining_users=$(grep -cE '^n0x[0-9a-f]{6}:' /etc/passwd 2>/dev/null || echo "0")
    remaining_users=$(echo "$remaining_users" | tr -d '[:space:]')
    if [[ $remaining_users -gt 0 ]]; then
        warn "Remaining dynamic users: $remaining_users"
        ((++issues))
    fi

    # Check database
    if [[ -f /var/lib/sidedoor/certificates.db ]]; then
        warn "Database still exists: /var/lib/sidedoor/certificates.db"
        ((++issues))
    fi

    # Check database directory
    if [[ -d /var/lib/sidedoor ]]; then
        warn "Database directory still exists: /var/lib/sidedoor"
        ((++issues))
    fi

    # Check SSH config
    if [[ -f /etc/ssh/sshd_config.d/sidedoor.conf ]]; then
        warn "SSH config still exists: /etc/ssh/sshd_config.d/sidedoor.conf"
        ((++issues))
    fi

    if [[ $issues -eq 0 ]]; then
        log "Verification passed: All components removed successfully"
    else
        warn "Verification found $issues issue(s)"
    fi
}

# show_summary prints a concise removal summary (services stopped, timers removed, users removed, mount points unmounted, files removed with human-readable total size) and logs completion.

show_summary() {
    phase "Removal Summary"

    echo "Services stopped: $SERVICES_STOPPED"
    echo "Timers removed: $TIMERS_REMOVED"
    echo "Users removed: $USERS_REMOVED"
    echo "Mount points unmounted: $MOUNTS_UNMOUNTED"

    local total_size
    total_size=$(format_size "$TOTAL_SIZE_BYTES")
    echo "Files removed: $FILES_REMOVED ($total_size)"

    echo ""
    log "Uninstall complete"
}

# main orchestrates the Sidedoor uninstall: runs safety checks, executes phased cleanup steps (services, systemd units, dynamic users, mounts, DB, config, application files, repository clones, and verification), and prints a final summary.
# main prompts for interactive confirmation unless DRY_RUN=true and respects dry-run mode to simulate actions without making changes.

main() {
    # Initialize logging
    init_logging "uninstall" 2>/dev/null || true

    echo ""
    echo -e "${BLUE}=== Sidedoor Uninstall ===${NC}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        warn "DRY-RUN MODE: No actual changes will be made" "${BASH_LINENO:-0}"
        echo ""
    fi

    # Log uninstall parameters
    log "INFO" "Uninstall started with DRY_RUN=$DRY_RUN" "${BASH_LINENO:-0}"

    # Safety checks
    check_root
    check_local_dev
    show_preserved_notice

    # Confirm unless dry-run
    if [[ "$DRY_RUN" == false ]]; then
        echo -n "Continue with uninstall? (y/N): "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log "INFO" "Uninstall cancelled" "${BASH_LINENO:-0}"
            exit 0
        fi
        echo ""
    fi

    # Run phases
    phase_stop_services
    phase_remove_systemd_units
    phase_remove_dynamic_users
    phase_cleanup_chroot_mounts
    phase_remove_database
    phase_remove_configuration
    phase_remove_application_files
    phase_cleanup_remaining_artifacts
    phase_remove_repository_clone
    phase_verification

    # Show summary
    show_summary
}

main "$@"
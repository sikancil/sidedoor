#!/usr/bin/env bash
#
# Validation Functions for Smart Idempotency
# Provides ensure-style functions that detect → validate → act → confirm
#

# Source dependencies
SCRIPT_DIR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR_LIB/version.sh"
source "$SCRIPT_DIR_LIB/state.sh"

# Setup mode detection
# Detects if we're in install, update, or repair mode
# detect_setup_mode determines the current setup mode ("install", "update", or "repair") based on the presence of /etc/sidedoor/config.json and systemd state.
# It exports SETUP_MODE with the detected mode and echoes the mode to stdout.
detect_setup_mode() {
    local config_file="/etc/sidedoor/config.json"
    local mode="install"

    if [[ -f "$config_file" ]]; then
        if systemctl is-active --quiet sidedoor 2>/dev/null; then
            mode="update"
        elif systemctl list-unit-files | grep -q "sidedoor.service"; then
            mode="repair"
        else
            mode="install"
        fi
    fi

    export SETUP_MODE="$mode"
    echo "$mode"
}

# Ensure Bun is installed and meets minimum version
# ensure_bun ensures Bun is installed at or above the specified min_version (default 1.3.0); if Bun is missing, outdated, or nonfunctional it installs or reinstalls Bun and records the installed version.
ensure_bun() {
    local min_version="${1:-1.3.0}"

    # 1. DETECT - Check if installed
    if ! command -v bun &>/dev/null; then
        log "Bun not found, installing..."
        _install_bun
        return $?
    fi

    # 2. VALIDATE - Check version
    local current
    current=$(bun --version 2>/dev/null || echo "0.0.0")
    if ! version_ge "$current" "$min_version"; then
        log "⚠️  Bun $current outdated (need $min_version), upgrading..."
        _install_bun
        return $?
    fi

    # 3. CONFIRM - Verify it works
    if ! bun --help &>/dev/null; then
        error "Bun installed but broken, reinstalling..."
        _install_bun
        return $?
    fi

    log "✅ Bun $current installed and functional"
    set_state_meta "bun_installed" "$current"
    return 0
}

# _install_bun installs the Bun JavaScript runtime system-wide into /opt/bun, creates symlinks in /usr/local/bin, updates PATH/BUN_INSTALL, and records the installed version via set_state_meta.
# Returns 0 on success, 1 on failure.
_install_bun() {
    apt-get update -qq
    apt-get install -y -qq unzip curl ca-certificates >/dev/null 2>&1

    if curl -fsSL https://bun.sh/install | bash; then
        # Copy to system-wide location
        mkdir -p /opt/bun
        cp "$HOME/.bun/bin/bun" /opt/bun/bun
        cp "$HOME/.bun/bin/bunx" /opt/bun/bunx 2>/dev/null || true
        chmod 755 /opt/bun/bun
        chmod 755 /opt/bun/bunx 2>/dev/null || true

        # Create symlinks
        ln -sf /opt/bun/bun /usr/local/bin/bun
        ln -sf /opt/bun/bunx /usr/local/bin/bunx 2>/dev/null || true

        export BUN_INSTALL="/opt/bun"
        export PATH="/opt/bun:$PATH"

        local version
        version=$(/usr/local/bin/bun --version)
        set_state_meta "bun_installed" "$version"
        log "✅ Bun $version installed"
        return 0
    else
        error "Failed to install Bun"
        return 1
    fi
}

# Ensure user exists with correct groups
# ensure_user ensures a user exists and is a member of the sudo and www-data groups; creates the user if missing and adds any missing groups.
ensure_user() {
    local user=$1
    local required_groups="sudo|www-data"

    # 1. DETECT - Check existence
    if ! id "$user" &>/dev/null; then
        log "User $user not found, creating..."
        _create_user "$user"
        return $?
    fi

    # 2. VALIDATE - Check groups
    local user_groups
    user_groups=$(groups "$user")
    local missing_groups=()

    if ! echo "$user_groups" | grep -q "sudo"; then
        missing_groups+=("sudo")
    fi
    if ! echo "$user_groups" | grep -q "www-data"; then
        missing_groups+=("www-data")
    fi

    # 3. ACT - Add missing groups
    if [[ ${#missing_groups[@]} -gt 0 ]]; then
        log "⚠️  User $user missing groups: ${missing_groups[*]}, adding..."
        for group in "${missing_groups[@]}"; do
            usermod -aG "$group" "$user"
            log "  Added to $group group"
        done
    fi

    log "✅ User $user validated with correct groups"
    return 0
}

# _create_user creates the specified user (creates a regular user with a home for "ubuntu" and a system user otherwise), sets the login shell to /bin/bash, adds the user to sudo and www-data groups, and marks state "users_created".
_create_user() {
    local user=$1

    if [[ "$user" == "ubuntu" ]]; then
        useradd -m -s /bin/bash ubuntu 2>/dev/null || true
    else
        useradd -r -s /bin/bash "$user"
    fi

    # Add to required groups
    usermod -aG sudo "$user"
    usermod -aG www-data "$user"

    log "✅ User $user created"
    set_state "users_created"
}

# Ensure directory exists with correct ownership and permissions
# ensure_directory ensures a directory exists with the specified owner and permissions, creating it if missing and fixing ownership or mode as needed.
ensure_directory() {
    local dir=$1
    local owner=${2}
    local perms=${3:-755}

    # 1. DETECT - Check existence
    if [[ ! -d "$dir" ]]; then
        log "Creating directory: $dir"
        mkdir -p "$dir"
    fi

    local made_changes=false

    # 2. VALIDATE - Check ownership
    local current_owner
    current_owner=$(stat -c '%U:%G' "$dir" 2>/dev/null || stat -f '%Su:%Sg' "$dir")
    if [[ "$current_owner" != "$owner" ]]; then
        log "⚠️  Fixing ownership: $dir ($current_owner → $owner)"
        chown -R "$owner" "$dir"
        made_changes=true
    fi

    # 3. VALIDATE - Check permissions
    local current_perms
    current_perms=$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir")
    if [[ "$current_perms" != "$perms" ]]; then
        log "⚠️  Fixing permissions: $dir ($current_perms → $perms)"
        chmod "$perms" "$dir"
        made_changes=true
    fi

    if [[ "$made_changes" == "false" ]]; then
        log "✅ Directory $dir validated"
    fi

    return 0
}

# Validate SSH configuration syntax
# validate_ssh_config validates the SSH server configuration syntax by testing sshd and exits with status 0 on success or nonzero on failure.
validate_ssh_config() {
    if sshd -t 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Validate sudoers syntax
# validate_sudoers validates the syntax of the given sudoers file path using visudo and returns success (0) if the file is valid, non-zero otherwise.
validate_sudoers() {
    local file=$1
    if visudo -c -f "$file" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check if service is running
# is_service_running checks whether the given systemd service is active.
is_service_running() {
    local service=$1
    systemctl is-active --quiet "$service" 2>/dev/null
}

# Check if service is enabled
# is_service_enabled checks whether the specified systemd service is enabled at boot.
is_service_enabled() {
    local service=$1
    systemctl is-enabled --quiet "$service" 2>/dev/null
}

# Get service status
# get_service_status echoes the status of a systemd service as one of: active, failed, inactive, or unknown.
get_service_status() {
    local service=$1
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "active"
    elif systemctl is-failed --quiet "$service" 2>/dev/null; then
        echo "failed"
    elif systemctl list-unit-files | grep -q "${service}.service"; then
        echo "inactive"
    else
        echo "unknown"
    fi
}

# Validate configuration file JSON syntax
# validate_json validates the JSON syntax of a file using `jq` when available; otherwise performs a lightweight structural check.
validate_json() {
    local file=$1
    if command -v jq &>/dev/null; then
        jq empty "$file" 2>/dev/null
    else
        # Fallback: basic syntax check
        grep -q '{.*}' "$file"
    fi
}

# Validate user access and permissions
# validate_user_access validates that the specified user has a home directory, can write to it, is a member of the sudo group, and can run sudo without a password (warns if a password is required).
validate_user_access() {
    local user=$1

    # Check home directory exists
    local home_dir
    home_dir=$(eval echo "~$user")
    if [[ ! -d "$home_dir" ]]; then
        error "Home directory not found: $home_dir"
        return 1
    fi

    # Test write access to home directory
    local test_file="$home_dir/.write_test_$$"
    if ! su - "$user" -c "touch $test_file" 2>/dev/null; then
        error "User $user cannot write to home directory: $home_dir"
        error "Possible causes:"
        error "  • Disk full (df -h to check)"
        error "  • Permission denied (ls -la $home_dir)"
        error "  • Read-only filesystem"
        return 1
    fi
    rm -f "$test_file"

    # Verify user is in sudo group
    if ! groups "$user" 2>/dev/null | grep -q "sudo"; then
        error "User $user is not in sudo group"
        error "Required for certificate operations"
        return 1
    fi

    # Verify sudo actually works for this user
    if ! su - "$user" -c "sudo -n true" 2>/dev/null; then
        warn "User $user may require password for sudo operations"
        warn "This could cause issues with certificate creation"
    fi

    log "✅ User $user access validated"
    return 0
}
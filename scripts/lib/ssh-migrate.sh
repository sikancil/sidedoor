#!/usr/bin/env bash
#
# SSH Migration Library
# Merges SSH configuration from root user to service user
#
# Features:
# - Merges authorized_keys (deduplicates by key fingerprint)
# - Merges config files (preserves host entries)
# - Merges known_hosts (deduplicates)
# - Copies public keys by default
# - Copies private keys only with --migrate-ssh-private-keys flag
# - Tracks state for idempotency
# - Supports rollback
#
# Usage:
#   ssh_migrate_keys "ubuntu"              # Public keys only
#   ssh_migrate_keys "ubuntu" true         # Include private keys
#   ssh_rollback_migration "ubuntu"        # Remove migrated keys
#

# ========== COLORS ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========== UTILITY FUNCTIONS ==========
# Define if not already defined (allows standalone usage)
if ! declare -f log >/dev/null; then
    # log prints an informational message prefixed with "[SSH-MIGRATE]" in green.
log() { echo -e "${GREEN}[SSH-MIGRATE]${NC} $1"; }
fi
if ! declare -f warn >/dev/null; then
    # warn prints a warning message prefixed with a yellow "[WARNING]" tag.
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
fi
if ! declare -f error >/dev/null; then
    # error prints an error message prefixed with a red "[ERROR]" tag followed by the provided message.
error() { echo -e "${RED}[ERROR]${NC} $1"; }
fi
if ! declare -f info >/dev/null; then
    # info prints an informational message to stdout prefixed with "[INFO]" styled in cyan.
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
fi
if ! declare -f phase >/dev/null; then
    # phase prints a formatted phase header block with a title passed as the first argument.
    phase() {
        echo ""
        echo -e "${BLUE}===============================================================${NC}"
        echo -e "${BLUE}  $1${NC}"
        echo -e "${BLUE}===============================================================${NC}"
        echo ""
    }
fi

# SSH Migration state file (separate from setup state)
SSH_MIGRATION_STATE="/etc/sidedoor/.ssh-migration-state"

# _ssh_init_state ensures the SSH migration state directory exists and creates the state file with restrictive permissions (directory mode 755, file mode 600).
_ssh_init_state() {
    local state_dir
    state_dir=$(dirname "$SSH_MIGRATION_STATE")

    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir"
        chmod 755 "$state_dir"
    fi

    if [[ ! -f "$SSH_MIGRATION_STATE" ]]; then
        touch "$SSH_MIGRATION_STATE"
        chmod 600 "$SSH_MIGRATION_STATE"
    fi
}

# _ssh_set_state writes a key/value pair into the SSH migration state file, replacing any existing entry for the given key.
_ssh_set_state() {
    local key=$1
    local value=$2
    _ssh_init_state

    # Remove existing entry
    sed -i "/^${key}=/d" "$SSH_MIGRATION_STATE" 2>/dev/null || true
    echo "${key}=${value}" >> "$SSH_MIGRATION_STATE"
}

# _ssh_get_state retrieves the value for a given key from the migration state file; it echoes the value when present and returns 0, otherwise returns 1.
_ssh_get_state() {
    local key=$1
    local result
    result=$(grep "^${key}=" "$SSH_MIGRATION_STATE" 2>/dev/null | cut -d'=' -f2-)
    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi
    return 1
}

_ssh_is_migrated checks whether SSH migration to the specified target user (optionally including private keys when include_private is "true") is recorded in the state file and returns 0 if found, 1 if not.
_ssh_is_migrated() {
    local target_user=$1
    local include_private=$2

    local state_key="ssh_migrated_to_${target_user}"
    if [[ "$include_private" == "true" ]]; then
        state_key="${state_key}_with_private"
    fi

    _ssh_get_state "$state_key" &>/dev/null
}

# _ssh_mark_migrated records that SSH migration to a target user has completed by writing a timestamped state entry; if the second argument is "true" the entry indicates private keys were included.
_ssh_mark_migrated() {
    local target_user=$1
    local include_private=$2
    local timestamp=${3:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}

    local state_key="ssh_migrated_to_${target_user}"
    if [[ "$include_private" == "true" ]]; then
        state_key="${state_key}_with_private"
    fi

    _ssh_set_state "$state_key" "$timestamp"
}

# _ssh_get_ssh_dir returns the SSH directory for the specified user: "/root/.ssh" for root and "/home/<user>/.ssh" for any other user.
_ssh_get_ssh_dir() {
    local user=$1

    if [[ "$user" == "root" ]]; then
        echo "/root/.ssh"
    else
        echo "/home/$user/.ssh"
    fi
}

# Extract key fingerprint (for deduplication)
# _ssh_get_key_fingerprint extracts the base64 key blob from an SSH public-key line and echoes its MD5 fingerprint in hex (prints nothing on invalid input).
_ssh_get_key_fingerprint() {
    local key_line=$1

    # Extract the key part (skip options, comments)
    # Format: (options) key-type key-data comment
    echo "$key_line" | awk '{print $2}' | base64 -d 2>/dev/null | md5sum | cut -d' ' -f1
}

# _ssh_is_valid_key returns success if the given line is a non-empty, non-comment SSH public key entry that begins with a recognized key type (e.g., ssh-rsa, ssh-ed25519, ssh-ecdsa, ecdsa-sha2-nistp*, ssh-dss).
_ssh_is_valid_key() {
    local line=$1

    # Skip empty lines and comments
    [[ -z "$line" ]] && return 1
    [[ "$line" =~ ^[[:space:]]*# ]] && return 1

    # Check if it starts with valid SSH key type
    [[ "$line" =~ ^(ssh-rsa|ssh-ed25519|ssh-ecdsa|ecdsa-sha2-nistp|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-dss) ]]
}

# Merge SSH keys from source to target file
# _ssh_merge_keys merges public keys from source_file into target_file for target_user, preserving comment lines and deduplicating entries by key fingerprint.
# It preserves existing target keys, appends non-duplicate keys from the source, sets ownership and mode 600 on the resulting file, and logs how many keys were added versus skipped.
_ssh_merge_keys() {
    local source_file=$1
    local target_file=$2
    local target_user=$3

    local tmp_file=$(mktemp)
    local added_keys=()
    local skipped_keys=0

    log "  Merging keys from: $source_file"

    # Add existing target keys first
    if [[ -f "$target_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if _ssh_is_valid_key "$line"; then
                echo "$line" >> "$tmp_file"
            fi
        done < "$target_file"
    fi

    # Add source keys that aren't duplicates
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines in source
        if ! _ssh_is_valid_key "$line"; then
            continue
        fi

        # Check if key already exists
        local fingerprint
        fingerprint=$(_ssh_get_key_fingerprint "$line")

        if grep -q "$(echo "$line" | awk '{print $2}')" "$tmp_file" 2>/dev/null; then
            ((skipped_keys++))
        else
            echo "$line" >> "$tmp_file"
            added_keys+=("$fingerprint")
        fi
    done < "$source_file"

    # Replace target file
    mv "$tmp_file" "$target_file"
    chown "$target_user:$target_user" "$target_file" 2>/dev/null || true
    chmod 600 "$target_file"

    log "  Added ${#added_keys[@]} keys, skipped $skipped_keys duplicates"
}

# _ssh_copy_keys copies SSH public key entries from a source file to a target file, ensures the target directory exists, sets ownership and secure permissions for the target user, and logs the number of keys copied.
_ssh_copy_keys() {
    local source_file=$1
    local target_file=$2
    local target_user=$3

    log "  Copying keys from: $source_file"

    # Ensure target directory exists
    local target_dir
    target_dir=$(dirname "$target_file")
    mkdir -p "$target_dir"
    chown "$target_user:$target_user" "$target_dir" 2>/dev/null || true
    chmod 700 "$target_dir"

    # Copy file
    cp "$source_file" "$target_file"
    chown "$target_user:$target_user" "$target_file" 2>/dev/null || true
    chmod 600 "$target_file"

    # Count keys
    local key_count
    key_count=$(grep -cE '^(ssh-rsa|ssh-ed25519|ssh-ecdsa)' "$target_file" 2>/dev/null || echo "0")
    log "  Copied $key_count keys"
}

# _ssh_merge_config merges Host blocks from a source SSH config into a target config, preserving existing Host entries, appending non-duplicate Host blocks from the source, and setting ownership and permissions for the resulting target file.
_ssh_merge_config() {
    local source_file=$1
    local target_file=$2
    local target_user=$3

    log "  Merging SSH config..."

    local tmp_file=$(mktemp)
    local merged_hosts=()

    # Add target file first
    if [[ -f "$target_file" ]]; then
        cat "$target_file" > "$tmp_file"
        # Extract host names
        merged_hosts=($(grep -E "^Host " "$target_file" 2>/dev/null | awk '{print $2}' || true))
    fi

    # Add source hosts that don't exist
    local current_host=""
    local in_host_block=false
    local skip_block=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^Host[[:space:]]+(.+)$ ]]; then
            current_host="${BASH_REMATCH[1]}"
            in_host_block=true

            # Check if host already exists
            if [[ " ${merged_hosts[*]} " =~ " ${current_host} " ]]; then
                skip_block=true
            else
                skip_block=false
                merged_hosts+=("$current_host")
                echo "$line" >> "$tmp_file"
            fi
        elif [[ "$in_host_block" == "true" ]]; then
            if [[ "$line" =~ ^[[:space:]]*$ ]]; then
                # Empty line ends host block
                in_host_block=false
                skip_block=false
                echo "" >> "$tmp_file"
            elif [[ "$skip_block" == "false" ]]; then
                echo "$line" >> "$tmp_file"
            fi
        fi
    done < "$source_file"

    mv "$tmp_file" "$target_file"
    chown "$target_user:$target_user" "$target_file" 2>/dev/null || true
    chmod 600 "$target_file"

    log "  Merged ${#merged_hosts[@]} host entries"
}

# _ssh_merge_known_hosts merges entries from a source known_hosts into a target known_hosts, appending non-duplicate host entries (deduplicated by host pattern), preserving existing entries, and setting ownership and permissions for the target user.
_ssh_merge_known_hosts() {
    local source_file=$1
    local target_file=$2
    local target_user=$3

    log "  Merging known_hosts..."

    local tmp_file=$(mktemp)
    local added_entries=0
    local skipped_entries=0

    # Add target file first
    if [[ -f "$target_file" ]]; then
        cat "$target_file" > "$tmp_file"
    fi

    # Add source entries that aren't duplicates
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        # Check if entry already exists (by host pattern)
        local host_pattern
        host_pattern=$(echo "$line" | awk '{print $1}' | cut -d',' -f1)

        if grep -q "^${host_pattern}" "$tmp_file" 2>/dev/null; then
            ((skipped_entries++))
        else
            echo "$line" >> "$tmp_file"
            ((added_entries++))
        fi
    done < "$source_file"

    mv "$tmp_file" "$target_file"
    chown "$target_user:$target_user" "$target_file" 2>/dev/null || true
    chmod 600 "$target_file"

    log "  Added $added_entries entries, skipped $skipped_entries duplicates"
}

# _ssh_copy_private_keys copies SSH private keys from a source directory into a user's target .ssh directory and prepares rollback markers when requested.
# 
# For each candidate file in source_dir that contains a private key header, the function copies the key to target_dir without overwriting existing keys, sets ownership to target_user and mode 600, and optionally creates a `.migrated` marker in backup_dir for rollback. It also copies the corresponding public key (`<key>.pub`) if present and sets its ownership and mode 644.
# 
# Parameters:
#   source_dir  - directory to scan for private key files (e.g., /root/.ssh)
#   target_dir  - destination .ssh directory for the target user
#   target_user - username owning the target files (used for chown)
#   backup_dir  - optional directory where `.migrated` marker files will be created for each copied private key (omit or pass empty to disable)
_ssh_copy_private_keys() {
    local source_dir=$1
    local target_dir=$2
    local target_user=$3
    local backup_dir=${4:-}

    log "  Copying private keys..."

    # Find private keys (id_*, no .pub extension)
    local private_keys=()
    while IFS= read -r -d '' file; do
        local basename
        basename=$(basename "$file")

        # Skip public keys and non-key files
        [[ "$basename" == *.pub ]] && continue
        [[ "$basename" == *.ppk ]] && continue
        [[ "$basename" == known_hosts ]] && continue
        [[ "$basename" == config ]] && continue
        [[ "$basename" == authorized_keys ]] && continue

        # Verify it's a private key
        if grep -q "PRIVATE KEY" "$file" 2>/dev/null; then
            private_keys+=("$basename")
        fi
    done < <(find "$source_dir" -maxdepth 1 -type f -print0 2>/dev/null)

    if [[ ${#private_keys[@]} -eq 0 ]]; then
        log "  No private keys found"
        return 0
    fi

    # Copy each private key
    for key_name in "${private_keys[@]}"; do
        local source_file="$source_dir/$key_name"
        local target_file="$target_dir/$key_name"

        # Don't overwrite existing private keys
        if [[ -f "$target_file" ]]; then
            log "  Skipping existing key: $key_name"
            continue
        fi

        cp "$source_file" "$target_file"
        chown "$target_user:$target_user" "$target_file"
        chmod 600 "$target_file"
        log "  Copied: $key_name"

        # Create marker file for rollback
        if [[ -n "$backup_dir" ]]; then
            touch "$backup_dir/${key_name}.migrated"
        fi
    done

    # Also copy public keys if they exist
    for key_name in "${private_keys[@]}"; do
        local pub_file="$source_dir/${key_name}.pub"
        if [[ -f "$pub_file" ]]; then
            cp "$pub_file" "$target_dir/"
            chown "$target_user:$target_user" "$target_dir/${key_name}.pub"
            chmod 644 "$target_dir/${key_name}.pub"
        fi
    done
}

# ssh_migrate_keys migrates SSH keys and configuration from root into a specified user account, optionally copying private keys.
# This creates backups, merges or copies authorized_keys, SSH config, and known_hosts with deduplication, copies public keys,
# can copy private keys when requested, marks migration state for idempotency, and disables root SSH login after success.
# target_user: username to receive the migrated SSH data (defaults to "ubuntu").
# include_private: "true" to also copy private keys, otherwise "false" (defaults to "false").
# Requires running as root to access /root/.ssh; returns non-zero on fatal errors (e.g., target is root or target home missing).
ssh_migrate_keys() {
    local target_user="${1:-ubuntu}"
    local include_private="${2:-false}"

    phase "SSH Migration: root → $target_user"

    local source_ssh_dir
    local target_ssh_dir
    local target_home

    source_ssh_dir=$(_ssh_get_ssh_dir "root")

    if [[ "$target_user" == "root" ]]; then
        warn "Cannot migrate to root user (same as source)"
        return 1
    fi

    target_ssh_dir=$(_ssh_get_ssh_dir "$target_user")
    target_home=$(dirname "$target_ssh_dir")

    # Check if running as root (required for accessing /root/.ssh)
    if [[ $EUID -ne 0 ]]; then
        log "SSH migration requires root access (skipping - not running as root)"
        log "  SSH migration will be handled during installation"
        return 0
    fi

    # Check if already migrated
    if _ssh_is_migrated "$target_user" "$include_private"; then
        log "SSH migration already completed for $target_user (skipping)"
        if [[ "$include_private" == "true" ]] && ! _ssh_is_migrated "$target_user" "false"; then
            log "Private keys were not migrated previously, proceeding..."
        else
            return 0
        fi
    fi

    # Check if source SSH directory exists
    if [[ ! -d "$source_ssh_dir" ]]; then
        log "No SSH directory found at $source_ssh_dir (skipping migration)"
        log "  Root user has no SSH keys to migrate"
        return 0
    fi

    # Verify target home directory exists
    if [[ ! -d "$target_home" ]]; then
        error "Target home directory not found: $target_home"
        error "Cannot proceed with SSH migration"
        return 1
    fi

    # Show what will be migrated
    log "Source: $source_ssh_dir"
    log "Target: $target_ssh_dir"
    log ""

    local files_migrated=0
    local errors=0

    # Create backup directory for rollback
    local backup_dir="/var/lib/sidedoor/ssh-backup-${target_user}"
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"

    # Backup existing target files before migration
    if [[ -f "$target_ssh_dir/authorized_keys" ]]; then
        cp "$target_ssh_dir/authorized_keys" "$backup_dir/authorized_keys"
        log "✓ Backed up authorized_keys"
    fi
    if [[ -f "$target_ssh_dir/config" ]]; then
        cp "$target_ssh_dir/config" "$backup_dir/config"
        log "✓ Backed up config"
    fi
    if [[ -f "$target_ssh_dir/known_hosts" ]]; then
        cp "$target_ssh_dir/known_hosts" "$backup_dir/known_hosts"
        log "✓ Backed up known_hosts"
    fi

    # Ensure target SSH directory exists
    mkdir -p "$target_ssh_dir"
    chown "$target_user:$target_user" "$target_ssh_dir"
    chmod 700 "$target_ssh_dir"

    # 1. Migrate authorized_keys
    if [[ -f "$source_ssh_dir/authorized_keys" ]]; then
        log "→ Migrating authorized_keys..."
        if [[ -f "$target_ssh_dir/authorized_keys" ]]; then
            _ssh_merge_keys "$source_ssh_dir/authorized_keys" "$target_ssh_dir/authorized_keys" "$target_user"
        else
            _ssh_copy_keys "$source_ssh_dir/authorized_keys" "$target_ssh_dir/authorized_keys" "$target_user"
        fi
        ((files_migrated++)) || true
    fi

    # 2. Migrate config
    if [[ -f "$source_ssh_dir/config" ]]; then
        log "→ Migrating SSH config..."
        if [[ -f "$target_ssh_dir/config" ]]; then
            _ssh_merge_config "$source_ssh_dir/config" "$target_ssh_dir/config" "$target_user"
        else
            cp "$source_ssh_dir/config" "$target_ssh_dir/config"
            chown "$target_user:$target_user" "$target_ssh_dir/config"
            chmod 600 "$target_ssh_dir/config"
            log "  Copied config file"
        fi
        ((files_migrated++)) || true
    fi

    # 3. Migrate known_hosts
    if [[ -f "$source_ssh_dir/known_hosts" ]]; then
        log "→ Migrating known_hosts..."
        if [[ -f "$target_ssh_dir/known_hosts" ]]; then
            _ssh_merge_known_hosts "$source_ssh_dir/known_hosts" "$target_ssh_dir/known_hosts" "$target_user"
        else
            cp "$source_ssh_dir/known_hosts" "$target_ssh_dir/known_hosts"
            chown "$target_user:$target_user" "$target_ssh_dir/known_hosts"
            chmod 600 "$target_ssh_dir/known_hosts"
            log "  Copied known_hosts"
        fi
        ((files_migrated++)) || true
    fi

    # 4. Copy public keys (*.pub)
    log "→ Migrating public keys..."
    while IFS= read -r -d '' pub_file; do
        local key_name
        key_name=$(basename "$pub_file")

        if [[ ! -f "$target_ssh_dir/$key_name" ]]; then
            cp "$pub_file" "$target_ssh_dir/$key_name"
            chown "$target_user:$target_user" "$target_ssh_dir/$key_name"
            chmod 644 "$target_ssh_dir/$key_name"
            # Create marker file for rollback
            touch "$backup_dir/${key_name}.migrated"
            ((files_migrated++)) || true
        fi
    done < <(find "$source_ssh_dir" -maxdepth 1 -name "*.pub" -type f -print0 2>/dev/null)

    # 5. Copy private keys (if requested)
    if [[ "$include_private" == "true" ]]; then
        log "→ Migrating private keys (--migrate-ssh-private-keys enabled)..."
        _ssh_copy_private_keys "$source_ssh_dir" "$target_ssh_dir" "$target_user" "$backup_dir"
    else
        log "→ Private keys NOT copied (use --migrate-ssh-private-keys to include)"
    fi

    # Mark as complete
    _ssh_mark_migrated "$target_user" "$include_private"

    log ""
    log "✅ SSH migration completed: $files_migrated files processed"

    # Security: Disable root SSH access after successful migration
    _ssh_disable_root_login "$target_user"

    return 0
}

# Disable root SSH login for security
# _ssh_disable_root_login disables direct root SSH access by creating an sshd_config fragment that denies root and password logins and then reloads SSH; the optional target_user (defaults to "ubuntu") is used in informational messages.
_ssh_disable_root_login() {
    local target_user="${1:-ubuntu}"

    log "🔒 Security: Disabling root SSH login..."

    local ssh_config="/etc/ssh/sshd_config.d/sidedoor-root-disable.conf"

    # Use sudo if not running as root for creating config in /etc
    local sudo_cmd=""
    if [[ $EUID -ne 0 ]]; then
        sudo_cmd="sudo"
    fi

    # Create config to disable root login
    $sudo_cmd cat > "$ssh_config" << EOF
# Security: Disable root SSH login after SSH migration
# Root SSH keys have been migrated to $target_user
# Use '$target_user@<hostname>' for SSH access instead
PermitRootLogin no
PasswordAuthentication no
EOF

    # Validate SSH configuration
    if sshd -t 2>/dev/null; then
        # Reload SSH service
        $sudo_cmd systemctl reload ssh 2>/dev/null || $sudo_cmd systemctl restart ssh
        log "✓ Root SSH login disabled"
        log "  Use '$target_user@<hostname>' for SSH access"
    else
        error "SSH configuration validation failed"
        $sudo_cmd rm -f "$ssh_config"
        return 1
    fi

    return 0
}

# _ssh_enable_root_login re-enables root SSH login by removing the sidedoor SSHD config fragment (/etc/ssh/sshd_config.d/sidedoor-root-disable.conf) if present and reloading or restarting the SSH service.
_ssh_enable_root_login() {
    log "⚠️  Re-enabling root SSH login (for debugging)..."

    local ssh_config="/etc/ssh/sshd_config.d/sidedoor-root-disable.conf"

    if [[ -f "$ssh_config" ]]; then
        # Use sudo if not running as root
        if [[ $EUID -ne 0 ]]; then
            sudo rm -f "$ssh_config"
            sudo systemctl reload ssh 2>/dev/null || sudo systemctl restart ssh
        else
            rm -f "$ssh_config"
            systemctl reload ssh 2>/dev/null || systemctl restart ssh
        fi
        log "✓ Root SSH login re-enabled"
    else
        log "Root SSH login is already enabled"
    fi

    return 0
}

# ssh_rollback_migration rolls back an SSH migration for a specified target user by restoring backed-up SSH files or removing migrated keys, re-enabling root SSH login, and clearing the migration state.
ssh_rollback_migration() {
    local target_user="${1:-ubuntu}"
    local include_private="${2:-false}"

    phase "SSH Migration Rollback: $target_user"

    local target_ssh_dir
    target_ssh_dir=$(_ssh_get_ssh_dir "$target_user")

    if [[ ! -d "$target_ssh_dir" ]]; then
        log "No SSH directory found for $target_user (nothing to rollback)"
        return 0
    fi

    # Check if migration was done
    if ! _ssh_is_migrated "$target_user" "$include_private"; then
        log "SSH migration not found for $target_user (nothing to rollback)"
        return 0
    fi

    # Check for backup files
    local backup_dir="/var/lib/sidedoor/ssh-backup-${target_user}"
    local has_backup=false

    if [[ -d "$backup_dir" ]]; then
        has_backup=true
        log "Found backup directory: $backup_dir"
    fi

    warn "This will rollback SSH migration from root to $target_user"
    if [[ "$has_backup" == "true" ]]; then
        warn "Original keys will be restored from backup"
    else
        warn "⚠️  No backup found - keys will be removed"
        warn "⚠️  Original keys for $target_user should be preserved"
    fi
    warn "⚠️  Root SSH login will be re-enabled"
    echo ""
    read -p "Continue? (yes/no): " -r
    echo

    if [[ ! "$REPLY" =~ ^[Yy][Ee][Ss]$ ]]; then
        log "Rollback cancelled"
        return 0
    fi

    log "Rolling back SSH migration..."

    # 1. Re-enable root SSH login
    _ssh_enable_root_login

    # 2. Restore from backup if available, otherwise warn user
    if [[ "$has_backup" == "true" ]]; then
        log "Restoring files from backup..."

        # Restore authorized_keys
        if [[ -f "$backup_dir/authorized_keys" ]]; then
            cp "$backup_dir/authorized_keys" "$target_ssh_dir/authorized_keys"
            chown "$target_user:$target_user" "$target_ssh_dir/authorized_keys"
            chmod 600 "$target_ssh_dir/authorized_keys"
            log "✓ Restored authorized_keys"
        fi

        # Restore config
        if [[ -f "$backup_dir/config" ]]; then
            cp "$backup_dir/config" "$target_ssh_dir/config"
            chown "$target_user:$target_user" "$target_ssh_dir/config"
            chmod 600 "$target_ssh_dir/config"
            log "✓ Restored config"
        fi

        # Restore known_hosts
        if [[ -f "$backup_dir/known_hosts" ]]; then
            cp "$backup_dir/known_hosts" "$target_ssh_dir/known_hosts"
            chown "$target_user:$target_user" "$target_ssh_dir/known_hosts"
            chmod 600 "$target_ssh_dir/known_hosts"
            log "✓ Restored known_hosts"
        fi

        # Remove migrated public keys
        while IFS= read -r -d '' pub_file; do
            local key_name
            key_name=$(basename "$pub_file")
            if [[ -f "$backup_dir/${key_name}.migrated" ]]; then
                rm -f "$target_ssh_dir/$key_name"
                log "✓ Removed migrated public key: $key_name"
            fi
        done < <(find "$target_ssh_dir" -maxdepth 1 -name "*.pub" -type f -print0 2>/dev/null)

        # Remove migrated private keys if they were migrated
        if [[ "$include_private" == "true" ]]; then
            while IFS= read -r -d '' key_file; do
                local key_name
                key_name=$(basename "$key_file")
                if [[ -f "$backup_dir/${key_name}.migrated" ]]; then
                    rm -f "$target_ssh_dir/$key_name"
                    log "✓ Removed migrated private key: $key_name"
                fi
            done < <(find "$target_ssh_dir" -maxdepth 1 -type f \
                ! -name "*.pub" \
                ! -name "authorized_keys" \
                ! -name "config" \
                ! -name "known_hosts" \
                -print0 2>/dev/null)
        fi

        # Remove backup directory
        rm -rf "$backup_dir"
        log "✓ Backup directory removed"

    else
        log ""
        warn "⚠️  No backup found - manual cleanup required"
        warn "Please review and remove migrated keys from:"
        warn "   $target_ssh_dir/authorized_keys"
        warn "   $target_ssh_dir/config"
        warn "   $target_ssh_dir/known_hosts"
        warn ""
        warn "Migrated files from root should be removed manually"
    fi

    # 3. Clear migration state
    local state_key="ssh_migrated_to_${target_user}"
    if [[ "$include_private" == "true" ]]; then
        state_key="${state_key}_with_private"
    fi

    sed -i "/^${state_key}=/d" "$SSH_MIGRATION_STATE" 2>/dev/null || true
    log "✓ Migration state cleared"

    log ""
    log "✅ Rollback complete"
    log "   Root SSH login has been re-enabled"

    return 0
}

# Export functions for use in other scripts
export -f ssh_migrate_keys
export -f ssh_rollback_migration
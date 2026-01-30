#!/usr/bin/env bash
#
# Enhanced State Management
# Provides state tracking with metadata for smart idempotency
#

# State file location
STATE_FILE="${STATE_FILE:-/var/lib/sidedoor/.setup-state}"

# Initialize state file and directory
init_state() {
    local state_dir
    state_dir=$(dirname "$STATE_FILE")
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir"
        chmod 755 "$state_dir"
    fi
    touch "$STATE_FILE"
    chmod 644 "$STATE_FILE"
}

# Binary state tracking (backward compatible)
# Usage: set_state "bun_installed"
set_state() {
    local key=$1
    # Remove existing entry
    sed -i "/^${key}=/d" "$STATE_FILE" 2>/dev/null || true
    echo "${key}=true" >> "$STATE_FILE"
}

# Check binary state (backward compatible)
# Usage: get_state "bun_installed" # returns 0 if true
get_state() {
    local key=$1
    grep -q "^${key}=true" "$STATE_FILE" 2>/dev/null
}

# Rich state with metadata
# Usage: set_state_meta "bun_installed" "1.3.0" [timestamp]
set_state_meta() {
    local key=$1
    local value=$2
    local timestamp=${3:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}

    # Remove existing entry
    sed -i "/^${key}=/d" "$STATE_FILE" 2>/dev/null || true

    # Add new entry with metadata
    echo "${key}=${value}@${timestamp}" >> "$STATE_FILE"
}

# Get value from rich state
# Usage: get_state_meta "bun_installed" # outputs: 1.3.0
get_state_meta() {
    local key=$1
    local entry
    entry=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | head -1)
    if [[ -n "$entry" ]]; then
        echo "$entry" | cut -d'=' -f2 | cut -d'@' -f1
    fi
}

# Get timestamp from rich state
# Usage: get_state_time "bun_installed" # outputs: 2024-01-15T10:30:00Z
get_state_time() {
    local key=$1
    local entry
    entry=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | head -1)
    if [[ -n "$entry" ]]; then
        echo "$entry" | cut -d'@' -f2
    fi
}

# Check if state value matches expected
# Usage: check_state_value "bun_installed" "1.3.0"
check_state_value() {
    local key=$1
    local expected=$2
    local actual
    actual=$(get_state_meta "$key")
    [[ "$actual" == "$expected" ]]
}

# Remove state entry
# Usage: clear_state "bun_installed"
clear_state() {
    local key=$1
    sed -i "/^${key}=/d" "$STATE_FILE" 2>/dev/null || true
}

# List all state keys
# Usage: list_state_keys
list_state_keys() {
    grep -oE '^[^=]+' "$STATE_FILE" 2>/dev/null | sort -u
}

# Export all state as JSON (for debugging)
# Usage: export_state_json
export_state_json() {
    echo "{"
    local first=true
    while IFS='=' read -r key value; do
        if [[ "$key" =~ ^# ]] || [[ -z "$key" ]]; then
            continue
        fi
        if [[ "$value" == *"@"* ]]; then
            local val
            local timestamp
            val=$(echo "$value" | cut -d'@' -f1)
            timestamp=$(echo "$value" | cut -d'@' -f2)
            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo ","
            fi
            echo "  \"${key}\": {\"value\": \"${val}\", \"timestamp\": \"${timestamp}\"}"
        fi
    done < "$STATE_FILE"
    echo "}"
}

#!/usr/bin/env bash
#
# Enhanced State Management
# Provides state tracking with metadata for smart idempotency
#

# State file location
STATE_FILE="${STATE_FILE:-/var/lib/sidedoor/.setup-state}"

# init_state ensures the directory containing STATE_FILE exists (creating it with mode 755 if missing) and creates STATE_FILE with mode 644.
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
# set_state sets a binary state by ensuring a single "key=true" entry for the given key in STATE_FILE (defaults to /var/lib/sidedoor/.setup-state).
set_state() {
    local key=$1
    # Remove existing entry
    sed -i "/^${key}=/d" "$STATE_FILE" 2>/dev/null || true
    echo "${key}=true" >> "$STATE_FILE"
}

# Check binary state (backward compatible)
# get_state checks whether the given key is set to `true` in the state file and exits with success if a matching line is found.
get_state() {
    local key=$1
    grep -q "^${key}=true" "$STATE_FILE" 2>/dev/null
}

# Rich state with metadata
# set_state_meta adds or updates a key in STATE_FILE with a value and an ISO 8601 UTC timestamp.
# If the optional timestamp is omitted, the current UTC time in the format YYYY-MM-DDTHH:MM:SSZ is used.
# Existing entries for the key are removed before the new "key=value@timestamp" line is appended.
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
# get_state_meta outputs the stored value (the part before `@`) for KEY from STATE_FILE and prints nothing if the key is not present.
get_state_meta() {
    local key=$1
    local entry
    entry=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | head -1)
    if [[ -n "$entry" ]]; then
        echo "$entry" | cut -d'=' -f2 | cut -d'@' -f1
    fi
}

# Get timestamp from rich state
# get_state_time prints the timestamp (the portion after `@`) of the first matching entry for the given key from STATE_FILE, or prints nothing if no entry is found.
get_state_time() {
    local key=$1
    local entry
    entry=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | head -1)
    if [[ -n "$entry" ]]; then
        echo "$entry" | cut -d'@' -f2
    fi
}

# Check if state value matches expected
# check_state_value compares the stored rich-state value for a key to the expected value and exits with success when they match.
check_state_value() {
    local key=$1
    local expected=$2
    local actual
    actual=$(get_state_meta "$key")
    [[ "$actual" == "$expected" ]]
}

# Remove state entry
# clear_state removes all entries matching "<key>=..." for the given key from STATE_FILE.
clear_state() {
    local key=$1
    sed -i "/^${key}=/d" "$STATE_FILE" 2>/dev/null || true
}

# List all state keys
# list_state_keys outputs all unique keys from STATE_FILE, one per line, sorted.
list_state_keys() {
    grep -oE '^[^=]+' "$STATE_FILE" 2>/dev/null | sort -u
}

# Export all state as JSON (for debugging)
# export_state_json outputs a JSON object representing all rich state entries from STATE_FILE.
# It reads STATE_FILE, skips commented/empty lines, and for entries of the form "key=value@timestamp" emits `"key": {"value": "<value>", "timestamp": "<timestamp>"}` to stdout.
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
#!/usr/bin/env bash
#
# Version Comparison Utilities
# Provides semantic version comparison functions for smart idempotency
#

# Compare two version strings
# Returns 0 (true) if $1 >= $2
# Usage: version_ge "1.5.0" "1.3.0"
version_ge() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Compare two version strings
# Returns 0 (true) if $1 > $2
# Usage: version_gt "1.5.0" "1.3.0"
version_gt() {
    [[ "$1" == "$2" ]] && return 1
    version_ge "$1" "$2"
}

# Compare two version strings
# Returns 0 (true) if $1 == $2
# Usage: version_eq "1.5.0" "1.5.0"
version_eq() {
    [[ "$1" == "$2" ]]
}

# Extract version from command output
# Usage: get_version "bun --version"
get_version() {
    local cmd=$1
    $cmd 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Check if Bun version meets minimum requirement
# Usage: bun_version_ok # returns 0 if >= 1.3.0
bun_version_ok() {
    local min_version="1.3.0"
    if command -v bun &>/dev/null; then
        local current
        current=$(bun --version 2>/dev/null || echo "0.0.0")
        version_ge "$current" "$min_version"
    else
        return 1
    fi
}

# Parse version string into components
# Usage: version_parse "1.5.0" # outputs: major=1 minor=5 patch=0
version_parse() {
    local version=$1
    local IFS='.'
    read -r major minor patch <<< "$version"
    echo "$major $minor $patch"
}

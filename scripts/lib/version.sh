#!/usr/bin/env bash
#
# Version Comparison Utilities
# Provides semantic version comparison functions for smart idempotency
#

# Compare two version strings
# Returns 0 (true) if $1 >= $2
# version_ge returns success (exit code 0) if the first semantic version is greater than or equal to the second; otherwise it returns a non-zero exit status.
version_ge() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Compare two version strings
# Returns 0 (true) if $1 > $2
# version_gt checks whether the first semantic version is greater than the second; exits with 0 when greater and non-zero otherwise.
version_gt() {
    [[ "$1" == "$2" ]] && return 1
    version_ge "$1" "$2"
}

# Compare two version strings
# Returns 0 (true) if $1 == $2
# version_eq checks whether two version strings are equal (exit code 0 when equal).
version_eq() {
    [[ "$1" == "$2" ]]
}

# Extract version from command output
# get_version extracts the first MAJOR.MINOR.PATCH version-like string from the stdout/stderr of the provided command and echoes it.
get_version() {
    local cmd=$1
    $cmd 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Check if Bun version meets minimum requirement
# bun_version_ok checks whether the installed Bun version meets the minimum required version 1.3.0.
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
# version_parse splits a semantic version string into major, minor, and patch components and echoes them as three space-separated values.
version_parse() {
    local version=$1
    local IFS='.'
    read -r major minor patch <<< "$version"
    echo "$major $minor $patch"
}
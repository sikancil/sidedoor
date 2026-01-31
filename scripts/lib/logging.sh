#!/usr/bin/env bash
#
# Unified Logging Library for Sidedoor Scripts
# Provides consistent logging across all scripts with file output and credential masking
#
# Usage:
#   source scripts/lib/logging.sh
#   init_logging "script_name"  # Creates log file: /var/log/sidedoor/script_name.2026-01-31T13-58-00Z.log
#   log "INFO" "message" "$LINENO"
#   log "WARN" "warning message" "$LINENO"
#   log "ERROR" "error message" "$LINENO"
#   log "DEBUG" "debug info" "$LINENO"
#   phase "PHASE 1: Description"
#   close_logging
#
# Environment Variables:
#   LOG_DIR           Override log directory (default: /var/log/sidedoor)
#   NO_LOG_FILE       Set to "true" to disable file logging
#   LOG_TIMESTAMP     Set to "false" to disable timestamps in output
#

# ========== CONFIGURATION ==========

LOG_DIR="${LOG_DIR:-/var/log/sidedoor}"
LOG_FILE=""
LOG_FD=3  # File descriptor for log output
LOG_SCRIPT_NAME=""
LOG_ENABLED=true
_LOG_INITIALIZED=false  # Prevent double initialization
_LOG_FD_OPEN=false  # Track if fd 3 is actually open

# Colors (reset if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    NC='\033[0m'  # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    NC=''
fi

# ========== LOG LEVEL FORMATTING ==========

# _log_level_color returns the ANSI color code for the given log level (`INFO`, `WARN`, `ERROR`, `DEBUG`) or the no-color code for unknown levels.
_log_level_color() {
    local level=$1
    case "$level" in
        INFO)  echo "$GREEN" ;;
        WARN)  echo "$YELLOW" ;;
        ERROR) echo "$RED" ;;
        DEBUG) echo "$CYAN" ;;
        *)     echo "$NC" ;;
    esac
}

# _log_timestamp formats and prints a UTC timestamp (ISO 8601) including milliseconds when available; if LOG_TIMESTAMP is "false" it prints nothing.
_log_timestamp() {
    if [[ "${LOG_TIMESTAMP:-true}" != "false" ]]; then
        # Try to get milliseconds, fallback to seconds
        if date +%s%3N >/dev/null 2>&1; then
            # GNU date with milliseconds
            local ms
            ms=$(date +%s%3N 2>/dev/null || echo "0")
            local sec=$((ms / 1000))
            local msec=$((ms % 1000))
            date -u -d "@$sec" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%S"
            printf ".%03dZ" "$msec"
        else
            # BSD date or without milliseconds
            date -u +"%Y-%m-%dT%H:%M:%SZ"
        fi
    fi
}

# ========== CREDENTIAL MASKING ==========

# Partial masking: show first 2 chars + middle masked + last 2 chars
# mask_partial masks a string by preserving a short prefix and suffix and replacing the middle characters with asterisks.
mask_partial() {
    local str=$1
    local len=${#str}

    if [[ $len -le 4 ]]; then
        # For short strings, show first 1 + last 1
        echo "${str:0:1}***${str: -1}"
    elif [[ $len -le 8 ]]; then
        # For medium strings, show first 2 + last 2
        local first_two="${str:0:2}"
        local last_two="${str: -2}"
        local middle_len=$((len - 4))
        local middle=$(printf '%*s' "$middle_len" '' | tr ' ' '*')
        echo "${first_two}${middle}${last_two}"
    else
        # For long strings, show first 2 + last 2
        local first_two="${str:0:2}"
        local last_two="${str: -2}"
        local middle_len=$((len - 4))
        local middle=$(printf '%*s' "$middle_len" '' | tr ' ' '*')
        echo "${first_two}${middle}${last_two}"
    fi
}

# Mask sensitive data in text
# mask_sensitive replaces common credential and key patterns (authenticatorToken, cronSecret, Bearer tokens, SSH keys/paths, private_key_path, api_key/token, and common password patterns) in the provided text with masked placeholders.
mask_sensitive() {
    local text="$1"

    # Mask authenticatorToken values
    # Pattern: "authenticatorToken": "value" or authenticatorToken=value
    text=$(echo "$text" | sed -E 's/"authenticatorToken"\s*:\s*"[^"]{8,}"/"authenticatorToken": "***MASKED**"/g')
    text=$(echo "$text" | sed -E 's/authenticatorToken=[^[:space:]]{8,}/authenticatorToken=***MASKED**/g')

    # Mask cronSecret values
    text=$(echo "$text" | sed -E 's/"cronSecret"\s*:\s*"[^"]{8,}/"cronSecret": "***MASKED**"/g')
    text=$(echo "$text" | sed -E 's/cronSecret=[^[:space:]]{8,}/cronSecret=***MASKED**/g')

    # Mask Bearer tokens
    text=$(echo "$text" | sed -E 's/Bearer\s+[A-Za-z0-9_\-\.]{20,}/Bearer ***MASKED**/g')

    # Mask SSH private key paths (but not the directory structure)
    text=$(echo "$text" | sed -E 's|/[a-z_]+/\.ssh/id_[a-z0-9]+|/[a-z_]+/.ssh/id_***KEY***|g')

    # Mask private_key_path values
    text=$(echo "$text" | sed -E 's/"private_key_path"\s*:\s*"[^"]{10,}/"private_key_path": "***MASKED**"/g')

    # Mask SSH key content (ssh-rsa, ssh-ed25519, etc.)
    text=$(echo "$text" | sed -E 's/ssh-(rsa|ed25519|ecdsa)\s+[A-Za-z0-9+/=]{20,}/ssh-\1 ***KEY*** ***REDACTED***/g')

    # Mask generic API keys and tokens
    text=$(echo "$text" | sed -E 's/[aA][pP][iI]_[kK][eE][yY]\s*[:=]\s*[A-Za-z0-9_\-\.]{20,}/api_key: ***MASKED**/g')
    text=$(echo "$text" | sed -E 's/[tT][oO][kK][eE][nN]\s*[:=]\s*[A-Za-z0-9_\-\.]{20,}/token: ***MASKED**/g')

    # Mask passwords in common patterns
    text=$(echo "$text" | sed -E 's/[pP][aA][sS][sS][wW][oO][rR][dD]\s*[:=]\s*[^\s[:space:]]{8,}/password: ***MASKED**/g')

    echo "$text"
}

# Mask a specific value for logging
# log_value returns a masked value for known credential keys (authenticatorToken, cronSecret, token, api_key, secret, password) and echoes the original value unchanged for other keys.
log_value() {
    local key=$1
    local value=$2

    case "$key" in
        authenticatorToken|cronSecret|token|api_key|secret|password)
            mask_partial "$value"
            ;;
        *)
            echo "$value"
            ;;
    esac
}

# ========== LOG INITIALIZATION ==========

# Initialize logging for a script
# init_logging initializes logging for a script by creating the log directory, creating a timestamped per-script log file, opening file descriptor 3 for log output, and installing an EXIT trap to close logging.
# It is idempotent (no-op if already initialized), sets LOG_SCRIPT_NAME, and records state via _LOG_INITIALIZED and _LOG_FD_OPEN.
# If LOG_DIR cannot be created, it falls back to /tmp/sidedoor-logs; file logging can be disabled by setting NO_LOG_FILE=true.
# The created log directory and file receive restrictive permissions when possible, and a header is written to the log file when file logging is available.
# Usage: init_logging "script_name" — script_name is used to name the log file and appear in the log header.
init_logging() {
    # Skip if already initialized (idempotent)
    [[ "$_LOG_INITIALIZED" == "true" ]] && return 0

    local script_name=$1
    LOG_SCRIPT_NAME="$script_name"

    # Create log directory if it doesn't exist
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || {
            # Fallback to /tmp if we can't create in /var/log
            LOG_DIR="/tmp/sidedoor-logs"
            mkdir -p "$LOG_DIR"
        }
    fi

    # Generate log file with timestamp
    # Format: script_name.2026-01-31T13-58-00Z.log
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
    LOG_FILE="$LOG_DIR/${script_name}.${timestamp}.log"

    # Set restrictive permissions
    chmod 700 "$LOG_DIR" 2>/dev/null || true

    # Open log file for writing (fd 3)
    # Try to open fd 3; if successful, set _LOG_FD_OPEN flag
    if [[ "${NO_LOG_FILE:-}" != "true" ]]; then
        # Redirect stderr to /dev/null for this specific exec call
        # This requires a more complex approach
        if exec 3>"$LOG_FILE" 2>/dev/null; then
            _LOG_FD_OPEN=true
            chmod 600 "$LOG_FILE" 2>/dev/null || true
        else
            # Failed to open fd 3, disable file logging
            NO_LOG_FILE="true"
            LOG_FILE=""
            _LOG_FD_OPEN=false
        fi
    fi

    # Mark as initialized before writing header
    _LOG_INITIALIZED=true

    # Write log header (only if fd 3 is valid)
    if [[ "$_LOG_FD_OPEN" == "true" ]]; then
        _write_log_header 2>/dev/null || true
    fi

    # Set trap to close logging on exit (only once)
    trap close_logging EXIT
}

# _write_log_header writes a header to file descriptor 3 with the start timestamp, system information (hostname, OS, kernel, user, PID) and script information (name, path, arguments); no-op if the log file descriptor is not open.
_write_log_header() {
    # Only write if fd 3 is confirmed open
    [[ "$_LOG_FD_OPEN" != "true" ]] && return 0

    local timestamp
    timestamp=$(_log_timestamp)

    echo "============================================" >&3
    echo "  Sidedoor Log: $LOG_SCRIPT_NAME" >&3
    echo "  Started: $timestamp" >&3
    echo "============================================" >&3
    echo "" >&3

    # System information
    echo "System Information:" >&3
    echo "  Hostname: $(hostname)" >&3
    echo "  OS: $(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')" >&3
    echo "  Kernel: $(uname -r)" >&3
    echo "  User: ${USER:-$(whoami)}" >&3
    echo "  PID: $$" >&3
    echo "" >&3

    # Script information
    echo "Script Information:" >&3
    echo "  Name: $LOG_SCRIPT_NAME" >&3
    echo "  Path: $0" >&3
    echo "  Arguments: ${*:-none}" >&3
    echo "" >&3
    echo "============================================" >&3
    echo "" >&3
}

# ========== CORE LOGGING FUNCTIONS ==========

# Internal: Safely write to fd 3, suppressing errors
# _write_to_log writes a formatted log entry to the configured log file descriptor (fd 3) when file logging is enabled.
# The entry format is "TIMESTAMP [LEVEL] [script:line] MESSAGE"; the function returns immediately if the log fd is not open.
_write_to_log() {
    local level=$1
    local message=$2
    local script="${3:-${LOG_SCRIPT_NAME:-unknown}}"
    local line=${4:-0}

    # Only write if fd 3 is confirmed open
    [[ "$_LOG_FD_OPEN" != "true" ]] && return 0

    local timestamp
    timestamp=$(_log_timestamp)

    # Format: TIMESTAMP [LEVEL] [script:line] MESSAGE
    echo "${timestamp} [${level}] [${script}:${line}] ${message}" >&3
}

# Main logging function
# log logs a message at the given level to the console (if enabled) and to the file-based log while masking sensitive content.
# Accepts a log level (e.g., INFO, WARN, ERROR, DEBUG — legacy lowercase names `info`, `warn`, `error`, `debug` are accepted and normalized), the message text, and an optional source line number used in the file log. Console output is colorized and controlled by LOG_ENABLED; the message written to the log file is passed through mask_sensitive before being recorded.
log() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local line="${3:-0}"

    # Map legacy level names
    case "$level" in
        info) level="INFO" ;;
        warn) level="WARN" ;;
        error) level="ERROR" ;;
        debug) level="DEBUG" ;;
    esac

    # Get color for level
    local color
    color=$(_log_level_color "$level")

    # Write to console (with color)
    if [[ "$LOG_ENABLED" == "true" ]]; then
        echo -e "${color}[${LOG_SCRIPT_NAME^^}]${NC} $message"
    fi

    # Write to log file (masked)
    local masked_message
    masked_message=$(mask_sensitive "$message")
    _write_to_log "$level" "$masked_message" "$LOG_SCRIPT_NAME" "$line"
}

# Convenience functions that match existing patterns

# info logs an informational message to console and the log file, masking sensitive content and accepting an optional line number for context.
info() {
    log "INFO" "$1" "${2:-0}"
}

# warn logs a warning-level message, masking sensitive content and writing it to the console (if enabled) and to the file logger; accepts a message and an optional line number.
warn() {
    log "WARN" "$1" "${2:-0}"
}

# error logs a message with ERROR level. First argument is the message to log; second optional argument is the line number to include in the log (defaults to 0).
error() {
    log "ERROR" "$1" "${2:-0}"
}

# debug logs a debug-level message; it prints the message to the console when DEBUG=true and always writes a masked debug entry to the logfile (accepts message and optional line number).
debug() {
    local message="${1:-}"
    local line="${2:-0}"

    if [[ "${DEBUG:-false}" == "true" ]]; then
        log "DEBUG" "$message" "$line"
    fi
    # Always write debug to log file
    local masked_message
    masked_message=$(mask_sensitive "$message")
    _write_to_log "DEBUG" "$masked_message" "$LOG_SCRIPT_NAME" "$line"
}

# phase prints a visual phase/header block with the given message to the console and mirrors the same block to the log file on fd 3 when open.
# message is the text displayed inside the header.
# line is an optional line number (defaults to 0) maintained for caller consistency; it is not used by this function.
phase() {
    local message=$1
    local line=${2:-0}

    echo ""
    echo -e "${BLUE}===============================================================${NC}"
    echo -e "${BLUE}  $message${NC}"
    echo -e "${BLUE}===============================================================${NC}"
    echo ""

    # Also write to log file
    if [[ "$_LOG_FD_OPEN" == "true" ]]; then
        echo "" >&3
        echo "===============================================================" >&3
        echo "  $message" >&3
        echo "===============================================================" >&3
        echo "" >&3
    fi
}

# header prints a prominent section header to the console and writes the same header to the log file.
header() {
    phase "$1" "$2"
}

# ========== COMMAND LOGGING ==========

# Log a command execution with output
# log_command runs a command, logs a descriptive entry, captures and masks its output, and records the command's success or failure.
#
# Logs an informational message describing the action, logs the command itself at debug level,
# executes the provided command with its arguments, masks sensitive data in both stdout and stderr,
# and writes the masked output to the log file (via fd 3). If the output exceeds 50 lines, the logged
# output is truncated to the first 50 lines and a debug message indicates the number of omitted lines.
# On success the function logs a debug success message; on failure it logs an ERROR including the exit code.
#
# Parameters:
#   $1 - human-readable description of the command being executed (used in log messages)
#   $2... - command and its arguments to execute
#
# Returns:
#   The exit code of the executed command.
log_command() {
    local description=$1
    shift
    local cmd="$*"
    local line=${BASH_LINENO:-0}

    log "INFO" "Executing: $description" "$line"
    debug "Command: $cmd" "$line"

    # Execute command and capture output
    local output
    local exit_code
    output=$($cmd 2>&1)
    exit_code=$?

    # Mask sensitive output
    local masked_output
    masked_output=$(mask_sensitive "$output")

    # Log output (truncated if too long)
    if [[ -n "$masked_output" ]]; then
        local max_lines=50
        local line_count
        line_count=$(echo "$masked_output" | wc -l)
        if [[ $line_count -gt $max_lines ]]; then
            debug "Output (truncated to $max_lines lines):" "$line"
            echo "$masked_output" | head -n "$max_lines" >&3
            debug "... ($((line_count - max_lines)) more lines)" "$line"
        else
            debug "Output: $masked_output" "$line"
        fi
    fi

    # Log exit code
    if [[ $exit_code -eq 0 ]]; then
        debug "Command succeeded (exit code: $exit_code)" "$line"
    else
        log "ERROR" "Command failed with exit code $exit_code: $description" "$line"
    fi

    return $exit_code
}

# ========== LOG CLOSURE ==========

# close_logging closes the log file descriptor (fd 3), writes an end-of-log summary to the log file, resets internal state, and prints the log file path to the console if the log file exists.
close_logging() {
    # Skip if fd 3 was never opened
    [[ "$_LOG_FD_OPEN" != "true" ]] && return 0

    local timestamp
    timestamp=$(_log_timestamp)

    echo "" >&3
    echo "============================================" >&3
    echo "  Log Ended: $timestamp" >&3
    echo "  Log File: $LOG_FILE" >&3
    echo "============================================" >&3

    # Close file descriptor
    exec 3>&-
    _LOG_FD_OPEN=false

    # Display log location to user (only if log file was created)
    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
        echo ""
        echo -e "${CYAN}[LOG]${NC} Log saved to: $LOG_FILE"
    fi
}

# Export functions for use in other scripts
export -f init_logging
export -f log
export -f info
export -f warn
export -f error
export -f debug
export -f phase
export -f header
export -f log_command
export -f close_logging
export -f mask_sensitive
export -f mask_partial
export -f log_value
#!/usr/bin/env bash
#
# Remove Droplet SSH Known Host Entry
# Usage: ./scripts/remove-droplet-host.sh <IP_ADDRESS>
#
# This script removes all SSH known host entries for a specific droplet IP
# from ~/.ssh/known_hosts. Useful when rebuilding droplets with the same IP.
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# log prints an informational message prefixed with "[INFO]" in green to stdout.
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# error prints an error message in red to stderr using the first argument and then exits with status 1.
error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# warn prints a warning message prefixed with [WARN] in yellow to stderr.
warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

# usage displays usage information for removing SSH known_hosts entries for a droplet IP and exits with status 1.
usage() {
    cat << EOF
Usage: $(basename "$0") <IP_ADDRESS>

Remove all SSH known host entries for a specific droplet IP from ~/.ssh/known_hosts.

Arguments:
  IP_ADDRESS    The IP address of the droplet to remove from known_hosts

Example:
  $(basename "$0") xxx.xxx.xxx.xxx

EOF
    exit 1
}

# Check arguments
if [[ $# -ne 1 ]]; then
    usage
fi

DROPLET_IP="$1"

# Validate IP format (basic check)
if [[ ! "$DROPLET_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    error "Invalid IP address format: $DROPLET_IP"
fi

KNOWN_HOSTS="$HOME/.ssh/known_hosts"

# Check if known_hosts exists
if [[ ! -f "$KNOWN_HOSTS" ]]; then
    warn "known_hosts file does not exist: $KNOWN_HOSTS"
    exit 0
fi

# Check if IP exists in known_hosts
if ! grep -q "$DROPLET_IP" "$KNOWN_HOSTS" 2>/dev/null; then
    warn "No entries found for $DROPLET_IP in $KNOWN_HOSTS"
    exit 0
fi

# Show entries that will be removed
log "Entries to be removed for $DROPLET_IP:"
grep -n "$DROPLET_IP" "$KNOWN_HOSTS" 2>/dev/null || true

# Backup known_hosts
BACKUP_FILE="${KNOWN_HOSTS}.backup.$(date +%Y%m%d_%H%M%S)"
cp "$KNOWN_HOSTS" "$BACKUP_FILE"
log "Backup created: $BACKUP_FILE"

# Remove entries (handle both GNU and BSD sed)
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS/BSD sed
    sed -i '' "/$DROPLET_IP/d" "$KNOWN_HOSTS"
else
    # GNU sed
    sed -i "/$DROPLET_IP/d" "$KNOWN_HOSTS"
fi

log "Removed all entries for $DROPLET_IP from $KNOWN_HOSTS"
log "✅ Done!"
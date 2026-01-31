#!/usr/bin/env bash
#
# Sidedoor Application Update Script
# Updates the application from git and restarts the service
#
# Usage: sudo ./scripts/update-app.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# log prints an informational message prefixed with a green "[UPDATE]" tag to stdout.
log() {
    echo -e "${GREEN}[UPDATE]${NC} $1"
}

# warn prints a warning message prefixed with [WARNING] in yellow to stdout.
warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# error prints an error message prefixed with a red [ERROR] tag and resets the color; the message is taken from the first argument.
error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Service user (read from existing config)
SERVICE_USER=$(jq -r '.user.name // "sidedoor"' /etc/sidedoor/config.json 2>/dev/null || echo "sidedoor")

log "Starting application update..."

# Pull latest changes
log "Pulling latest changes from git..."
cd "$PROJECT_ROOT"
git pull origin wizard

# Copy updated source files to /opt/sidedoor
log "Copying updated files to /opt/sidedoor..."
rsync -av --exclude='node_modules' --exclude='.git' --exclude='data' \
    "$PROJECT_ROOT/" /opt/sidedoor/

# Set ownership
chown -R "$SERVICE_USER:$SERVICE_USER" /opt/sidedoor
chown -R "$SERVICE_USER:www-data" /opt/sidedoor 2>/dev/null || true

# Restart service
log "Restarting sidedoor service..."
systemctl restart sidedoor

# Wait for service to start
sleep 2

# Check service status
if systemctl is-active --quiet sidedoor; then
    log "✅ Application updated and service is running"
    log ""
    log "To view logs: journalctl -u sidedoor -f"
    log "To check status: systemctl status sidedoor"
else
    error "Service failed to start after update"
    error "Check logs with: journalctl -u sidedoor -n 50"
    exit 1
fi
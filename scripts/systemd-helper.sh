#!/usr/bin/env bash
#
# Sidedoor Systemd Helper
# Secure wrapper for systemd operations performed by the sidedoor service
# This script runs as root and is called via sudo by the ubuntu user
#
# Usage (via sudo):
#   /usr/local/sbin/sidedoor-systemd-helper create-timer <username> <expiresAt> <cronSecret> <apiUrl>
#   /usr/local/sbin/sidedoor-systemd-helper delete-timer <username>
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# log prints a green-colored, script-prefixed message to stderr.
log() {
    echo -e "${GREEN}[$(basename "$0")]${NC} $1" >&2
}

# error prints a red-formatted error message prefixed with the script name to stderr and exits with status 1.
error() {
    echo -e "${RED}[$(basename "$0")] ERROR${NC} $1" >&2
    exit 1
}

# Validate we're running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
fi

# Get command
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    create-timer)
        if [[ $# -ne 4 ]]; then
            error "Usage: $0 create-timer <username> <expiresAt> <cronSecret> <apiUrl>"
        fi

        username="$1"
        # Convert ISO 8601 to systemd calendar format
        # Input:  2026-01-31T04:41:26.271Z
        # Output: 2026-01-31 04:41:26 UTC
        expiresAt_raw="$2"
        expiresAt_clean="${expiresAt_raw%.[0-9]*Z}"  # Strip milliseconds: 2026-01-31T04:41:26.271Z → 2026-01-31T04:41:26
        expiresAt="${expiresAt_clean//T/ } UTC"       # Replace T with space and add UTC: 2026-01-31 04:41:26 UTC
        cronSecret="$3"
        apiUrl="$4"
        timerName="sidedoor-${username}"
        serviceName="sidedoor-cleanup-${username}"

        log "Creating systemd timer for $username (expires: $expiresAt)"

        # Validate inputs
        if [[ ! "$username" =~ ^n0x[a-f0-9]{6}$ ]]; then
            error "Invalid username format. Expected: n0x + 6 hex chars"
        fi

        # Generate timer unit file
        cat > "/etc/systemd/system/${timerName}.timer" << EOF
[Unit]
Description=Sidedoor Certificate Cleanup for ${username}
Requires=${serviceName}.service

[Timer]
OnCalendar=${expiresAt}
AccuracySec=1s
Unit=${serviceName}.service

[Install]
WantedBy=timers.target
EOF

        # Generate service unit file
        cat > "/etc/systemd/system/${serviceName}.service" << EOF
[Unit]
Description=Sidedoor Certificate Cleanup for ${username}
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/curl -s -X POST ${apiUrl} \\
  -H "Authorization: Bearer ${cronSecret}" \\
  -H "X-Certificate-Id: ${username}" \\
  -H "X-Trigger: systemd"
StandardOutput=append:/var/log/sidedoor/cleanup.log
StandardError=append:/var/log/sidedoor/cleanup-errors.log
Restart=on-failure
RestartSec=30s

# Auto-delete after execution
ExecStartPost=/bin/systemctl disable ${timerName}.timer
ExecStartPost=/bin/rm -f /etc/systemd/system/${timerName}.{timer,service}
ExecStartPost=/bin/systemctl daemon-reload
EOF

        # Reload systemd and enable timer
        systemctl daemon-reload
        systemctl start "${timerName}.timer"
        systemctl enable "${timerName}.timer"

        log "✅ Created timer ${timerName}"
        ;;

    delete-timer)
        if [[ $# -ne 1 ]]; then
            error "Usage: $0 delete-timer <username>"
        fi

        username="$1"
        timerName="sidedoor-${username}"
        serviceName="sidedoor-cleanup-${username}"

        log "Deleting systemd timer for $username"

        # Stop and disable timer
        systemctl stop "${timerName}.timer" 2>/dev/null || true
        systemctl disable "${timerName}.timer" 2>/dev/null || true

        # Remove files
        rm -f "/etc/systemd/system/${timerName}.timer" 2>/dev/null || true
        rm -f "/etc/systemd/system/${serviceName}.service" 2>/dev/null || true

        # Reload systemd
        systemctl daemon-reload

        log "✅ Deleted timer ${timerName}"
        ;;

    *)
        error "Unknown command: $COMMAND

Available commands:
  create-timer <username> <expiresAt> <cronSecret> <apiUrl>
  delete-timer <username>"
        ;;
esac
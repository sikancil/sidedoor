#!/usr/bin/env bash
#
# Sidedoor Setup Verification Script
# Verifies that all components are properly installed and configured
#
# Usage:
#   sudo ./scripts/verify-setup.sh [--user USER]
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default values
SERVICE_USER="${SERVICE_USER:-sidedoor}"
API_PORT="${API_PORT:-3000}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            SERVICE_USER="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: sudo $0 [--user USER]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    exit 1
fi

# Verification counters
PASS=0
FAIL=0
WARN=0

check_pass() {
    echo -e "${GREEN}✓ PASS${NC} - $1"
    ((PASS++))
}

check_fail() {
    echo -e "${RED}✗ FAIL${NC} - $1"
    ((FAIL++))
}

check_warn() {
    echo -e "${YELLOW}⚠ WARN${NC} - $1"
    ((WARN++))
}

check_info() {
    echo -e "${BLUE}ℹ INFO${NC} - $1"
}

echo ""
echo -e "${BLUE}===============================================================${NC}"
echo -e "${BLUE}  🔍 SIDEDOOR SETUP VERIFICATION${NC}"
echo -e "${BLUE}===============================================================${NC}"
echo ""

# ========== CHECK 1: OS Version ==========
echo "Checking system prerequisites..."
if [[ -f /etc/os-release ]]; then
    if grep -q "Ubuntu 22.04" /etc/os-release || grep -q "Ubuntu 24.04" /etc/os-release; then
        check_pass "Running on supported Ubuntu version"
    else
        check_warn "Ubuntu version may not be officially supported"
    fi
else
    check_fail "Cannot determine OS version"
fi

# ========== CHECK 2: Systemd ==========
if systemctl --version &>/dev/null; then
    check_pass "systemd is available"
else
    check_fail "systemd is not available"
fi

# ========== CHECK 3: Service User ==========
echo ""
echo "Checking service user..."
if id "$SERVICE_USER" &>/dev/null; then
    check_pass "Service user '$SERVICE_USER' exists"

    # Check group membership
    if groups "$SERVICE_USER" | grep -q "sudo"; then
        check_pass "Service user is in sudo group"
    else
        check_fail "Service user is not in sudo group"
    fi

    if groups "$SERVICE_USER" | grep -q "www-data"; then
        check_pass "Service user is in www-data group"
    else
        check_warn "Service user is not in www-data group"
    fi
else
    check_fail "Service user '$SERVICE_USER' does not exist"
fi

# ========== CHECK 4: Bun Runtime ==========
echo ""
echo "Checking runtime environment..."
if command -v bun &>/dev/null; then
    BUN_VERSION=$(bun --version)
    check_pass "Bun is installed (version: $BUN_VERSION)"
else
    check_fail "Bun is not installed"
fi

# ========== CHECK 5: Application Directory ==========
echo ""
echo "Checking application installation..."
if [[ -d /opt/sidedoor ]]; then
    check_pass "Application directory exists: /opt/sidedoor"

    if [[ -f /opt/sidedoor/src/index.ts ]]; then
        check_pass "Application entry point exists"
    else
        check_fail "Application entry point not found"
    fi

    if [[ -f /opt/sidedoor/package.json ]]; then
        check_pass "package.json exists"
    else
        check_fail "package.json not found"
    fi

    # Check ownership
    OWNER=$(stat -c "%U" /opt/sidedoor 2>/dev/null || stat -f "%Su" /opt/sidedoor)
    if [[ "$OWNER" == "$SERVICE_USER" ]]; then
        check_pass "Application directory owned by $SERVICE_USER"
    else
        check_fail "Application directory owned by $OWNER (expected: $SERVICE_USER)"
    fi
else
    check_fail "Application directory not found: /opt/sidedoor"
fi

# ========== CHECK 6: Configuration ==========
echo ""
echo "Checking configuration..."
if [[ -d /etc/sidedoor ]]; then
    check_pass "Configuration directory exists: /etc/sidedoor"

    if [[ -f /etc/sidedoor/config.json ]]; then
        check_pass "Configuration file exists"

        # Validate JSON
        if python3 -m json.tool /etc/sidedoor/config.json &>/dev/null; then
            check_pass "Configuration file is valid JSON"
        else
            check_fail "Configuration file is not valid JSON"
        fi

        # Check for default/placeholder values
        if grep -q "CHANGE_THIS" /etc/sidedoor/config.json; then
            check_warn "Configuration contains placeholder values (tokens need to be set)"
        fi
    else
        check_fail "Configuration file not found: /etc/sidedoor/config.json"
    fi
else
    check_fail "Configuration directory not found: /etc/sidedoor"
fi

# ========== CHECK 7: Database ==========
echo ""
echo "Checking database..."
if [[ -d /var/lib/sidedoor ]]; then
    check_pass "Data directory exists: /var/lib/sidedoor"

    if [[ -f /var/lib/sidedoor/certificates.db ]]; then
        check_pass "Database file exists"
    else
        check_warn "Database file not found (will be created on first run)"
    fi
else
    check_fail "Data directory not found: /var/lib/sidedoor"
fi

# ========== CHECK 8: SSH Configuration ==========
echo ""
echo "Checking SSH configuration..."
if [[ -f /etc/ssh/sshd_config.d/sidedoor.conf ]]; then
    check_pass "SSH chroot configuration exists"

    # Check for n0x pattern
    if grep -q "Match User n0x\*" /etc/ssh/sshd_config.d/sidedoor.conf; then
        check_pass "SSH chroot pattern configured for n0x* users"
    else
        check_fail "SSH chroot pattern not found"
    fi

    # Validate SSH config
    if sshd -t 2>/dev/null; then
        check_pass "SSH configuration is valid"
    else
        check_fail "SSH configuration has errors"
    fi
else
    check_fail "SSH chroot configuration not found"
fi

# ========== CHECK 9: Chroot Directory ==========
if [[ -d /home/sftp ]]; then
    check_pass "Chroot base directory exists: /home/sftp"
else
    check_warn "Chroot base directory not found (will be created on first user creation)"
fi

# ========== CHECK 10: Sudoers Configuration ==========
echo ""
echo "Checking sudoers configuration..."
if [[ -f /etc/sudoers.d/sidedoor ]]; then
    check_pass "Sudoers file exists: /etc/sudoers.d/sidedoor"

    # Validate sudoers
    if visudo -c -f /etc/sudoers.d/sidedoor &>/dev/null; then
        check_pass "Sudoers configuration is valid"
    else
        check_fail "Sudoers configuration has errors"
    fi
else
    check_fail "Sudoers file not found: /etc/sudoers.d/sidedoor"
fi

# ========== CHECK 11: Systemd Service ==========
echo ""
echo "Checking systemd service..."
if [[ -f /etc/systemd/system/sidedoor.service ]]; then
    check_pass "Systemd service file exists"

    if systemctl is-enabled sidedoor &>/dev/null; then
        check_pass "Service is enabled"
    else
        check_fail "Service is not enabled"
    fi

    if systemctl is-active sidedoor &>/dev/null; then
        check_pass "Service is running"
    else
        check_fail "Service is not running"
    fi
else
    check_fail "Systemd service file not found"
fi

# ========== CHECK 12: Logs Directory ==========
echo ""
echo "Checking logs..."
if [[ -d /var/log/sidedoor ]]; then
    check_pass "Log directory exists: /var/log/sidedoor"

    OWNER=$(stat -c "%U" /var/log/sidedoor 2>/dev/null || stat -f "%Su" /var/log/sidedoor)
    if [[ "$OWNER" == "$SERVICE_USER" ]] || [[ "$OWNER" == "root" ]]; then
        check_pass "Log directory has correct ownership"
    else
        check_warn "Log directory owned by $OWNER"
    fi
else
    check_warn "Log directory not found"
fi

# ========== CHECK 13: API Health Check ==========
echo ""
echo "Checking API health..."
if command -v curl &>/dev/null; then
    if curl -s "http://localhost:${API_PORT}/health" &>/dev/null; then
        check_pass "API health check responds"
    else
        check_warn "API health check failed (service may be starting up)"
    fi
else
    check_warn "curl not available, skipping API health check"
fi

# ========== CHECK 14: Security Hardening ==========
echo ""
echo "Checking security hardening..."

# UFW
if command -v ufw &>/dev/null; then
    if ufw status | grep -q "Status: active"; then
        check_pass "UFW firewall is active"

        # Check if port 22 is limited
        if ufw status | grep -q "22.*LIMIT"; then
            check_pass "SSH port (22) has rate limiting"
        else
            check_warn "SSH port (22) does not have rate limiting"
        fi

        # Check if API port is allowed
        if ufw status | grep -q "${API_PORT}"; then
            check_pass "API port ${API_PORT} is allowed"
        else
            check_warn "API port ${API_PORT} may not be explicitly allowed"
        fi
    else
        check_warn "UFW firewall is not active"
    fi
else
    check_warn "UFW not installed"
fi

# Fail2ban
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    check_pass "Fail2ban is running"

    if fail2ban-client status sshd &>/dev/null; then
        check_pass "Fail2ban SSH jail is enabled"
    else
        check_warn "Fail2ban SSH jail may not be enabled"
    fi
else
    check_warn "Fail2ban is not running"
fi

# ========== CHECK 15: State File ==========
echo ""
echo "Checking setup state..."
if [[ -f /var/lib/sidedoor/.setup-state ]]; then
    check_pass "Setup state file exists"
    check_info "State file contents:"
    cat /var/lib/sidedoor/.setup-state | sed 's/^/    /'
else
    check_warn "Setup state file not found"
fi

# ========== SUMMARY ==========
echo ""
echo -e "${BLUE}===============================================================${NC}"
echo -e "${BLUE}  VERIFICATION SUMMARY${NC}"
echo -e "${BLUE}===============================================================${NC}"
echo ""
echo -e "  ${GREEN}Passed:${NC}   $PASS"
echo -e "  ${RED}Failed:${NC}   $FAIL"
echo -e "  ${YELLOW}Warnings:${NC} $WARN"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}✅ All critical checks passed!${NC}"
    if [[ $WARN -gt 0 ]]; then
        echo -e "${YELLOW}⚠️  There are $WARN warnings to review${NC}"
    fi
    exit 0
else
    echo -e "${RED}❌ Verification failed with $FAIL error(s)${NC}"
    echo ""
    echo "Please review the failures above and run:"
    echo "  sudo ./scripts/setup-production.sh"
    exit 1
fi

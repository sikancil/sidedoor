#!/bin/bash

# SSH Migration Rollback Test Script
# Tests the complete rollback functionality

set -e

echo "============================================"
echo "SSH Migration Rollback Test"
echo "============================================"
echo ""

# Source the SSH migration library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-migrate.sh"

# Configuration
TEST_USER="${1:-ubuntu}"
SSH_DIR="/root/.ssh"

echo "TEST 1: Initial State Check"
echo "----------------------------"
echo "Root .ssh directory:"
ls -la "$SSH_DIR/" 2>/dev/null || echo "Does not exist"

echo ""
echo "Ubuntu .ssh directory:"
ls -la ~"$TEST_USER"/.ssh/ 2>/dev/null || echo "Does not exist"

echo ""
echo "Root SSH config:"
grep "PermitRootLogin" /etc/ssh/sshd_config.d/sidedoor-root-disable.conf 2>/dev/null || echo "No root disable config"

echo ""
echo "============================================"
echo "TEST 2: Run SSH Migration"
echo "============================================"
ssh_migrate_keys "$TEST_USER" false

echo ""
echo "After migration - Ubuntu .ssh:"
ls -la ~"$TEST_USER"/.ssh/

echo ""
echo "After migration - Backup directory:"
ls -la /var/lib/sidedoor/ssh-backup-"$TEST_USER"/ 2>/dev/null || echo "No backup found"

echo ""
echo "============================================"
echo "TEST 3: Verify Migration"
echo "============================================"

echo "State file:"
cat /etc/sidedoor/.ssh-migration-state 2>/dev/null || echo "No state file"

echo ""
echo "Ubuntu authorized_keys:"
cat ~"$TEST_USER"/.ssh/authorized_keys 2>/dev/null || echo "Not found"

echo ""
echo "Root SSH disabled:"
grep "PermitRootLogin no" /etc/ssh/sshd_config.d/sidedoor-root-disable.conf && echo "✓ Root SSH disabled" || echo "✗ Root SSH still enabled"

echo ""
echo "============================================"
echo "TEST 4: Run Rollback (auto-confirm)"
echo "============================================"

# Auto-confirm by piping "yes" to the function
echo "yes" | ssh_rollback_migration "$TEST_USER" false

echo ""
echo "============================================"
echo "TEST 5: Verify Rollback"
echo "============================================"

echo "State file (should be empty or not exist):"
cat /etc/sidedoor/.ssh-migration-state 2>/dev/null || echo "✓ State file cleared"

echo ""
echo "Backup directory (should be removed):"
ls -la /var/lib/sidedoor/ssh-backup-"$TEST_USER"/ 2>/dev/null || echo "✓ Backup directory removed"

echo ""
echo "Root SSH re-enabled:"
if grep -q "PermitRootLogin no" /etc/ssh/sshd_config.d/sidedoor-root-disable.conf 2>/dev/null; then
    echo "✗ Root SSH still disabled"
else
    echo "✓ Root SSH re-enabled"
fi

echo ""
echo "============================================"
echo "TEST 6: Idempotency - Rollback Again"
echo "============================================"
echo "Running rollback again (should skip)..."
echo "no" | ssh_rollback_migration "$TEST_USER" false

echo ""
echo "============================================"
echo "✅ All Tests Complete"
echo "============================================"

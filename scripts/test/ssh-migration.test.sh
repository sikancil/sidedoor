#!/usr/bin/env bash
#
# SSH Migration Test Script
# Tests SSH migration functionality in Docker containers
#
# Usage:
#   ./scripts/test-ssh-migration.sh [scenario]
#
# Scenarios:
#   fresh       - Test fresh container (root → ubuntu)
#   private     - Test with private keys flag
#   custom-user - Test with --user flag (root → sidedoor)
#   merge       - Test merging when both users have keys
#   idempotent  - Test re-run (should skip migration)
#   rollback    - Test rollback functionality
#   all         - Run all tests
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Test tracking
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

# Container name (unique per run)
CONTAINER_NAME="ssh-migration-test-$$"

# Test SSH keys
TEST_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINpvOLUmEkPcG7qZNq4zH634mNvUCpJY5uK/MeoSXGXY test-key@example.com"
TEST_SSH_KEY_ALT="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF7kJ3qY9xZ8R2KVPpH4k7GmE2rNw8sT5LqH1mP9kX3d alt-key@another-example.com"

# Utility functions
log() { echo -e "${GREEN}[TEST]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
phase() { echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"; }

assert_pass() {
    local description="$1"
    local command="$2"

    CURRENT_TEST="$description"
    if eval "$command" &>/dev/null; then
        log "✓ $description"
        ((TESTS_PASSED++))
        return 0
    else
        error "✗ $description"
        ((TESTS_FAILED++))
        return 1
    fi
}

assert_fail() {
    local description="$1"
    local command="$2"

    CURRENT_TEST="$description"
    if ! eval "$command" &>/dev/null; then
        log "✓ $description"
        ((TESTS_PASSED++))
        return 0
    else
        error "✗ $description (should have failed)"
        ((TESTS_FAILED++))
        return 1
    fi
}

assert_equals() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    CURRENT_TEST="$description"
    if [[ "$expected" == "$actual" ]]; then
        log "✓ $description"
        ((TESTS_PASSED++))
        return 0
    else
        error "✗ $description"
        error "  Expected: $expected"
        error "  Actual: $actual"
        ((TESTS_FAILED++))
        return 1
    fi
}

assert_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"

    CURRENT_TEST="$description"
    if echo "$haystack" | grep -qF "$needle"; then
        log "✓ $description"
        ((TESTS_PASSED++))
        return 0
    else
        error "✗ $description"
        error "  Needle not found: $needle"
        ((TESTS_FAILED++))
        return 1
    fi
}

assert_file_exists() {
    local description="$1"
    local filepath="$2"

    CURRENT_TEST="$description"
    if [[ -f "$filepath" ]]; then
        log "✓ $description"
        ((TESTS_PASSED++))
        return 0
    else
        error "✗ $description: $filepath"
        ((TESTS_FAILED++))
        return 1
    fi
}

assert_file_not_exists() {
    local description="$1"
    local filepath="$2"

    CURRENT_TEST="$description"
    if [[ ! -f "$filepath" ]]; then
        log "✓ $description"
        ((TESTS_PASSED++))
        return 0
    else
        error "✗ $description: $filepath exists"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Container management
start_container() {
    local name="$1"

    phase "Starting Test Container: $name"

    # Check if container already exists
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        warn "Container $name already exists, removing..."
        docker rm -f "$name" &>/dev/null || true
    fi

    # Run container with systemd
    docker run -d \
        --name "$name" \
        --privileged \
        -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
        tmpfs /tmp:exec \
        tmpfs /run:exec \
        tmpfs /run/lock:exec \
        ubuntu:22.04 \
        /sbin/init &>/dev/null

    # Wait for container to be ready
    local max_wait=30
    local waited=0
    while ! docker exec "$name" systemctl is-system-running &>/dev/null; do
        if [[ $waited -ge $max_wait ]]; then
            error "Container failed to start"
            return 1
        fi
        sleep 1
        ((waited++))
    done

    log "Container started and ready"

    # Install basic dependencies
    docker exec "$name" bash -c "
        apt-get update -qq &&
        apt-get install -y -qq curl openssh-server sudo acl git sqlite3 2>/dev/null
    " &>/dev/null

    log "Dependencies installed"
}

stop_container() {
    local name="$1"

    phase "Stopping Container: $name"

    docker stop "$name" &>/dev/null || true
    docker rm "$name" &>/dev/null || true

    log "Container stopped and removed"
}

exec_container() {
    local name="$1"
    shift

    docker exec "$name" bash -lc "$*"
}

# Setup test SSH keys in container
setup_root_ssh_keys() {
    local container="$1"
    local include_private="${2:-false}"

    phase "Setting Up Root SSH Keys"

    # Create .ssh directory
    exec_container "$container" "
        mkdir -p /root/.ssh &&
        chmod 700 /root/.ssh
    " &>/dev/null

    # Add authorized_keys
    exec_container "$container" "
        echo '$TEST_SSH_KEY' > /root/.ssh/authorized_keys &&
        echo '$TEST_SSH_KEY_ALT' >> /root/.ssh/authorized_keys &&
        chmod 600 /root/.ssh/authorized_keys
    " &>/dev/null

    # Add config
    exec_container "$container" "
        cat > /root/.ssh/config << 'EOF'
Host test-server
    HostName example.com
    User testuser
    Port 2222

Host backup-server
    HostName backup.example.com
    User backup
EOF
        chmod 600 /root/.ssh/config
    " &>/dev/null

    # Add known_hosts
    exec_container "$container" "
        cat > /root/.ssh/known_hosts << 'EOF'
[example.com]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINpvOLUmEkPcG7qZNq4zH634mNvUCpJY5uK/MeoSXGXY
backup.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF7kJ3qY9xZ8R2KVPpH4k7GmE2rNw8sT5LqH1mP9kX3d
EOF
        chmod 600 /root/.ssh/known_hosts
    " &>/dev/null

    # Add public key
    exec_container "$container" "
        echo '$TEST_SSH_KEY' > /root/.ssh/id_test.pub &&
        chmod 644 /root/.ssh/id_test.pub
    " &>/dev/null

    # Add private key (if requested)
    if [[ "$include_private" == "true" ]]; then
        exec_container "$container" "
            cat > /root/.ssh/id_test << 'EOF'
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACB58t8ZrgvEzlw0iSL4DrJhC+PIh5ySssWvJ/mELf4e1JQAAAALJiMWllyjFp
cAAAAtzc2gtZWQyNTUxOQAAACB58t8ZrgvEzlw0iSL4DrJhC+PIh5ySssWvJ/mELf4e1JQAAAEBg
P0fKxkYMFQYpXYbwYlSqyqF+zq/LQP1W4a8F+yKFqI3sDnz3y3xmuC8TOnDSJLgOsmEL48iHnJK
hxa8n+YQv/h7UlAAAABBnl7f2GaC8TOXDSJIvgOsmEL48iHnJKyxS8n+YQt/h7UlAAAAAQ==
-----END OPENSSH PRIVATE KEY-----
EOF
            chmod 600 /root/.ssh/id_test
        " &>/dev/null
    fi

    log "Root SSH keys set up"
}

# Copy project files to container
copy_project_to_container() {
    local container="$1"

    phase "Copying Project Files"

    # Create temp directory in container
    exec_container "$container" "mkdir -p /tmp/vm-access"

    # Copy files
    docker cp "$PROJECT_ROOT" "$container:/tmp/vm-access"

    log "Project files copied"
}

# Verify SSH migration
verify_migration() {
    local container="$1"
    local target_user="$2"
    local include_private="${3:-false}"

    phase "Verifying SSH Migration: root → $target_user"

    local target_home
    if [[ "$target_user" == "root" ]]; then
        target_home="/root"
    else
        target_home="/home/$target_user"
    fi
    local target_ssh="$target_home/.ssh"

    # 1. Check .ssh directory exists
    assert_pass ".ssh directory exists for $target_user" \
        "docker exec $container test -d $target_ssh"

    # 2. Check permissions
    local ssh_perms
    ssh_perms=$(exec_container "$container" "stat -c '%a' $target_ssh 2>/dev/null || stat -f '%Lp' $target_ssh")
    assert_equals ".ssh directory has 700 permissions" "700" "$ssh_perms"

    # 3. Check ownership
    local ssh_owner
    ssh_owner=$(exec_container "$container" "stat -c '%U:%G' $target_ssh 2>/dev/null || stat -f '%Su:%Sg' $target_ssh")
    assert_equals ".ssh directory owned by $target_user" "$target_user:$target_user" "$ssh_owner"

    # 4. Check authorized_keys exists and has both keys
    assert_pass "authorized_keys exists" \
        "docker exec $container test -f $target_ssh/authorized_keys"

    local auth_keys_content
    auth_keys_content=$(exec_container "$container" "cat $target_ssh/authorized_keys")
    assert_contains "authorized_keys has test-key" "$auth_keys_content" "test-key@example.com"
    assert_contains "authorized_keys has alt-key" "$auth_keys_content" "alt-key@another-example.com"

    # 5. Check config exists and has both hosts
    assert_pass "config exists" \
        "docker exec $container test -f $target_ssh/config"

    local config_content
    config_content=$(exec_container "$container" "cat $target_ssh/config")
    assert_contains "config has test-server" "$config_content" "test-server"
    assert_contains "config has backup-server" "$config_content" "backup-server"

    # 6. Check known_hosts exists
    assert_pass "known_hosts exists" \
        "docker exec $container test -f $target_ssh/known_hosts"

    # 7. Check public key exists
    assert_pass "id_test.pub exists" \
        "docker exec $container test -f $target_ssh/id_test.pub"

    # 8. Check private key (based on flag)
    if [[ "$include_private" == "true" ]]; then
        assert_pass "id_test (private key) exists" \
            "docker exec $container test -f $target_ssh/id_test"

        local key_perms
        key_perms=$(exec_container "$container" "stat -c '%a' $target_ssh/id_test 2>/dev/null || stat -f '%Lp' $target_ssh/id_test")
        assert_equals "private key has 600 permissions" "600" "$key_perms"
    else
        assert_fail "id_test (private key) should NOT exist" \
            "docker exec $container test -f $target_ssh/id_test"
    fi

    # 9. Check state file
    assert_pass "SSH migration state file exists" \
        "docker exec $container test -f /etc/sidedoor/.ssh-migration-state"

    local state_key="ssh_migrated_to_${target_user}"
    if [[ "$include_private" == "true" ]]; then
        state_key="${state_key}_with_private"
    fi

    local state_value
    state_value=$(exec_container "$container" "grep '^${state_key}=' /etc/sidedoor/.ssh-migration-state 2>/dev/null || true")
    assert_contains "State file has migration entry" "$state_value" "$state_key="

    log "Migration verification complete"
}

# Test scenarios
test_fresh_container() {
    phase "SCENARIO 1: Fresh Container (root → ubuntu, public keys only)"

    start_container "$CONTAINER_NAME"
    setup_root_ssh_keys "$CONTAINER_NAME" "false"
    copy_project_to_container "$CONTAINER_NAME"

    # Create ubuntu user first (simulating fresh droplet)
    exec_container "$CONTAINER_NAME" "
        useradd -m -s /bin/bash ubuntu &&
        usermod -aG sudo ubuntu
    " &>/dev/null

    # Run SSH migration
    log "Running SSH migration..."
    exec_container "$CONTAINER_NAME" "
        cd /tmp/vm-access &&
        source scripts/lib/ssh-migrate.sh &&
        ssh_migrate_keys ubuntu false
    " &>/dev/null

    verify_migration "$CONTAINER_NAME" "ubuntu" "false"

    stop_container "$CONTAINER_NAME"
}

test_with_private_keys() {
    phase "SCENARIO 2: Fresh Container with Private Keys Flag"

    start_container "$CONTAINER_NAME"
    setup_root_ssh_keys "$CONTAINER_NAME" "true"
    copy_project_to_container "$CONTAINER_NAME"

    exec_container "$CONTAINER_NAME" "
        useradd -m -s /bin/bash ubuntu &&
        usermod -aG sudo ubuntu
    " &>/dev/null

    log "Running SSH migration with private keys..."
    exec_container "$CONTAINER_NAME" "
        cd /tmp/vm-access &&
        source scripts/lib/ssh-migrate.sh &&
        ssh_migrate_keys ubuntu true
    " &>/dev/null

    verify_migration "$CONTAINER_NAME" "ubuntu" "true"

    stop_container "$CONTAINER_NAME"
}

test_custom_user() {
    phase "SCENARIO 3: Custom User (root → sidedoor)"

    start_container "$CONTAINER_NAME"
    setup_root_ssh_keys "$CONTAINER_NAME" "false"
    copy_project_to_container "$CONTAINER_NAME"

    # Don't create sidedoor - let the migration handle it
    # (actually, migration won't create user, so we create it)
    exec_container "$CONTAINER_NAME" "
        useradd -r -s /bin/bash sidedoor &&
        usermod -aG sudo sidedoor
    " &>/dev/null

    log "Running SSH migration to sidedoor..."
    exec_container "$CONTAINER_NAME" "
        cd /tmp/vm-access &&
        source scripts/lib/ssh-migrate.sh &&
        ssh_migrate_keys sidedoor false
    " &>/dev/null

    verify_migration "$CONTAINER_NAME" "sidedoor" "false"

    stop_container "$CONTAINER_NAME"
}

test_merge_keys() {
    phase "SCENARIO 4: Merge Keys (both users have keys)"

    start_container "$CONTAINER_NAME"
    setup_root_ssh_keys "$CONTAINER_NAME" "false"
    copy_project_to_container "$CONTAINER_NAME"

    # Create ubuntu user with existing SSH keys
    exec_container "$CONTAINER_NAME" "
        useradd -m -s /bin/bash ubuntu &&
        usermod -aG sudo ubuntu &&
        mkdir -p /home/ubuntu/.ssh &&
        chmod 700 /home/ubuntu/.ssh &&
        echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzL5vN8xQ7dY9mK3wP2hR8tJ6nF4sD1eG2yZ9aC5bX8d existing-ubuntu-key@local' > /home/ubuntu/.ssh/authorized_keys &&
        echo 'Host existing-host' > /home/ubuntu/.ssh/config &&
        echo '    HostName local.example.com' >> /home/ubuntu/.ssh/config &&
        chmod 600 /home/ubuntu/.ssh/config &&
        chown -R ubuntu:ubuntu /home/ubuntu/.ssh
    " &>/dev/null

    log "Running SSH migration (should merge)..."
    exec_container "$CONTAINER_NAME" "
        cd /tmp/vm-access &&
        source scripts/lib/ssh-migrate.sh &&
        ssh_migrate_keys ubuntu false
    " &>/dev/null

    # Verify merged keys
    local auth_keys
    auth_keys=$(exec_container "$CONTAINER_NAME" "cat /home/ubuntu/.ssh/authorized_keys")
    assert_contains "Has existing ubuntu key" "$auth_keys" "existing-ubuntu-key@local"
    assert_contains "Has root's test-key" "$auth_keys" "test-key@example.com"
    assert_contains "Has root's alt-key" "$auth_keys" "alt-key@another-example.com"

    # Verify merged config
    local config
    config=$(exec_container "$CONTAINER_NAME" "cat /home/ubuntu/.ssh/config")
    assert_contains "Has existing-host" "$config" "existing-host"
    assert_contains "Has root's test-server" "$config" "test-server"

    stop_container "$CONTAINER_NAME"
}

test_idempotency() {
    phase "SCENARIO 5: Idempotency (re-run should skip)"

    start_container "$CONTAINER_NAME"
    setup_root_ssh_keys "$CONTAINER_NAME" "false"
    copy_project_to_container "$CONTAINER_NAME"

    exec_container "$CONTAINER_NAME" "
        useradd -m -s /bin/bash ubuntu &&
        usermod -aG sudo ubuntu
    " &>/dev/null

    # First run
    log "First migration run..."
    exec_container "$CONTAINER_NAME" "
        cd /tmp/vm-access &&
        source scripts/lib/ssh-migrate.sh &&
        ssh_migrate_keys ubuntu false
    " &>/dev/null

    # Get first run state
    local first_state
    first_state=$(exec_container "$CONTAINER_NAME" "cat /etc/sidedoor/.ssh-migration-state")

    # Second run (should skip)
    log "Second migration run (should skip)..."
    exec_container "$CONTAINER_NAME" "
        cd /tmp/vm-access &&
        source scripts/lib/ssh-migrate.sh &&
        ssh_migrate_keys ubuntu false
    " &>/dev/null

    # Get second run state
    local second_state
    second_state=$(exec_container "$CONTAINER_NAME" "cat /etc/sidedoor/.ssh-migration-state")

    # States should be identical
    assert_equals "State unchanged on re-run" "$first_state" "$second_state"

    stop_container "$CONTAINER_NAME"
}

test_rollback() {
    phase "SCENARIO 6: Rollback Migration"

    start_container "$CONTAINER_NAME"
    setup_root_ssh_keys "$CONTAINER_NAME" "false"
    copy_project_to_container "$CONTAINER_NAME"

    exec_container "$CONTAINER_NAME" "
        useradd -m -s /bin/bash ubuntu &&
        usermod -aG sudo ubuntu &&
        mkdir -p /home/ubuntu/.ssh &&
        chmod 700 /home/ubuntu/.ssh
    " &>/dev/null

    # First, create an existing key for ubuntu
    exec_container "$CONTAINER_NAME" "
        echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzL5vN8xQ7dY9mK3wP2hR8tJ6nF4sD1eG2yZ9aC5bX8d original-ubuntu-key@local' > /home/ubuntu/.ssh/authorized_keys &&
        chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys &&
        chmod 600 /home/ubuntu/.ssh/authorized_keys
    " &>/dev/null

    # Run migration
    exec_container "$CONTAINER_NAME" "
        cd /tmp/vm-access &&
        source scripts/lib/ssh-migrate.sh &&
        ssh_migrate_keys ubuntu false
    " &>/dev/null

    # Verify migration worked
    local auth_keys
    auth_keys=$(exec_container "$CONTAINER_NAME" "cat /home/ubuntu/.ssh/authorized_keys")
    assert_contains "Has migrated keys" "$auth_keys" "test-key@example.com"

    # Rollback
    log "Rolling back migration..."
    exec_container "$CONTAINER_NAME" "
        cd /tmp/vm-access &&
        source scripts/lib/ssh-migrate.sh &&
        ssh_rollback_migration ubuntu false <<< 'yes'
    " &>/dev/null

    # Verify state cleared
    assert_pass "Migration state cleared" \
        "docker exec $CONTAINER_NAME bash -c '! grep -q \"ssh_migrated_to_ubuntu\" /etc/sidedoor/.ssh-migration-state'"

    log "Note: Manual review recommended for key removal"
    log "Original ubuntu key should remain: original-ubuntu-key@local"

    stop_container "$CONTAINER_NAME"
}

# Run all tests
run_all_tests() {
    phase "RUNNING ALL SSH MIGRATION TESTS"

    test_fresh_container
    test_with_private_keys
    test_custom_user
    test_merge_keys
    test_idempotency
    test_rollback
}

# Main
main() {
    local scenario="${1:-all}"

    echo ""
    echo "============================================"
    echo "  SSH Migration Test Suite"
    echo "============================================"
    echo ""
    echo "Scenario: ${GREEN}$scenario${NC}"
    echo "Container: ${CYAN}$CONTAINER_NAME${NC}"
    echo ""

    case "$scenario" in
        fresh) test_fresh_container ;;
        private) test_with_private_keys ;;
        custom-user) test_custom_user ;;
        merge) test_merge_keys ;;
        idempotent) test_idempotency ;;
        rollback) test_rollback ;;
        all) run_all_tests ;;
        *)
            echo "Usage: $0 [scenario]"
            echo ""
            echo "Scenarios:"
            echo "  fresh       - Test fresh container (root → ubuntu)"
            echo "  private     - Test with private keys flag"
            echo "  custom-user - Test with --user flag"
            echo "  merge       - Test merging when both users have keys"
            echo "  idempotent  - Test re-run (should skip migration)"
            echo "  rollback    - Test rollback functionality"
            echo "  all         - Run all tests"
            echo ""
            exit 1
            ;;
    esac

    # Summary
    echo ""
    phase "TEST SUMMARY"
    echo -e "${GREEN}Passed:${NC} $TESTS_PASSED"
    echo -e "${RED}Failed:${NC} $TESTS_FAILED"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo ""
        log "🎉 All tests passed!"
        return 0
    else
        echo ""
        error "Some tests failed"
        return 1
    fi
}

# Run main
main "$@"

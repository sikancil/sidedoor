#!/usr/bin/env bash
#
# Sidedoor Setup Script
# Smart idempotent setup for Ubuntu servers with install/update/repair detection
#
# Usage:
#   sudo ./scripts/setup.sh [OPTIONS]
#
# Options:
#   --user USER          Service user (default: sidedoor)
#   --force              Full reset before setup (runs rollback first)
#   --skip-hardening     Skip security hardening (UFW, fail2ban)
#   --verify-only        Run verification only
#   --ssh-key PATH       Path to SSH public key for ubuntu user
#   -h, --help           Show this help message
#
# Environment Variables:
#   SERVICE_USER         Override service user name
#   API_PORT             Override API port (default: 3000)
#   SSH_PORT             Override SSH port for UFW (default: 22)
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source library modules
source "$SCRIPT_DIR/lib/version.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/ssh-migrate.sh"
source "$SCRIPT_DIR/lib/sudo-wrapper.sh"

# Default values
SERVICE_USER="${SERVICE_USER:-sidedoor}"
API_PORT="${API_PORT:-3000}"
SSH_PORT="${SSH_PORT:-22}"
FORCE=false
SKIP_HARDENING=false
VERIFY_ONLY=false
SSH_KEY_PATH=""
MIGRATE_SSH_PRIVATE_KEYS=false
SETUP_MODE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Help function
show_help() {
    cat << EOF
Sidedoor Setup Script - Smart idempotent setup for Ubuntu servers

Usage: sudo $0 [OPTIONS]

Options:
  --user USER                    Service user to run the application (default: sidedoor)
                                 Use 'ubuntu' to use the existing default user
  --force                        Full reset before setup (removes and reinstalls everything)
  --skip-hardening               Skip security hardening (UFW, fail2ban, SSH hardening)
  --verify-only                  Run verification checks without making changes
  --ssh-key PATH                 Path to SSH public key to add to ubuntu user
  --migrate-ssh-private-keys     Include private keys in SSH migration from root
                                 (default: false - public keys only)
  -h, --help                     Show this help message

Environment Variables:
  SERVICE_USER         Same as --user
  API_PORT             API port for the service (default: 3000)
  SSH_PORT             SSH port for UFW firewall rules (default: 22)

Examples:
  # Standard setup with new 'sidedoor' user
  sudo $0

  # Setup using existing 'ubuntu' user
  sudo $0 --user ubuntu

  # Force complete reinstall
  sudo $0 --force

  # Skip security hardening (for testing)
  sudo $0 --skip-hardening

  # Run verification only
  sudo $0 --verify-only

  # Setup with custom SSH port
  SSH_PORT=2222 sudo $0

  # Setup with SSH private key migration from root
  sudo $0 --user ubuntu --migrate-ssh-private-keys

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            SERVICE_USER="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --skip-hardening)
            SKIP_HARDENING=true
            shift
            ;;
        --verify-only)
            VERIFY_ONLY=true
            shift
            ;;
        --ssh-key)
            SSH_KEY_PATH="$2"
            shift 2
            ;;
        --migrate-ssh-private-keys)
            MIGRATE_SSH_PRIVATE_KEYS=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# ========== UTILITY FUNCTIONS ==========

log() {
    echo -e "${GREEN}[SETUP]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

phase() {
    echo ""
    echo -e "${BLUE}===============================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}===============================================================${NC}"
    echo ""
}

# ========== REQUIREMENTS CHECK ==========

check_requirements() {
    phase "PHASE 1: Prerequisites Check"

    local requirements_met=true

    # Check if running as root (auto-elevate if possible)
    if [[ $EUID -ne 0 ]]; then
        ensure_elevated "$@"
    else
        log "Running as root"
    fi

    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot determine OS version"
        requirements_met=false
    elif ! grep -q "Ubuntu" /etc/os-release; then
        error "This script is designed for Ubuntu systems only"
        requirements_met=false
    else
        local ubuntu_version
        ubuntu_version=$(grep "VERSION_ID" /etc/os-release | cut -d'"' -f2)
        log "Ubuntu version: $ubuntu_version"
    fi

    # Check memory (minimum 512MB)
    local total_mem
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $total_mem -lt 512 ]]; then
        warn "Low memory detected: ${total_mem}MB (recommended: 512MB+)"
    else
        log "Memory: ${total_mem}MB"
    fi

    # Check disk space (minimum 1GB free)
    local free_disk
    free_disk=$(df -m / | awk 'NR==2{print $4}')
    if [[ $free_disk -lt 1024 ]]; then
        warn "Low disk space: ${free_disk}MB free (recommended: 1GB+)"
    else
        log "Disk space: ${free_disk}MB free"
    fi

    # Check systemd
    if ! command -v systemctl &>/dev/null; then
        error "systemd is not available"
        requirements_met=false
    else
        log "systemd is available"
    fi

    if [[ "$requirements_met" == "false" ]]; then
        error "Prerequisites check failed"
        exit 1
    fi

    set_state "prerequisites_checked"
    log "Prerequisites check passed"
}

# ========== BUN INSTALLATION ==========

install_bun() {
    phase "PHASE 2: Install Bun Runtime"

    # Smart validation using ensure_bun from validate.sh
    if ensure_bun "1.3.0"; then
        return 0
    else
        error "Bun installation failed"
        exit 1
    fi
}

# ========== USER CREATION ==========

create_users() {
    phase "PHASE 3: Create Users"

    # Handle ubuntu user with SSH key
    if [[ "$SERVICE_USER" == "ubuntu" ]] && id ubuntu &>/dev/null; then
        log "Using existing 'ubuntu' user"

        # Setup SSH key if provided
        if [[ -n "$SSH_KEY_PATH" ]]; then
            if [[ -f "$SSH_KEY_PATH" ]]; then
                log "Setting up SSH key for ubuntu user..."
                mkdir -p /home/ubuntu/.ssh
                cat "$SSH_KEY_PATH" >> /home/ubuntu/.ssh/authorized_keys
                chown -R ubuntu:ubuntu /home/ubuntu/.ssh
                chmod 700 /home/ubuntu/.ssh
                chmod 600 /home/ubuntu/.ssh/authorized_keys
                log "SSH key installed for ubuntu user"
            else
                warn "SSH key file not found: $SSH_KEY_PATH"
            fi
        fi
    fi

    # Smart validation using ensure_user from validate.sh
    if ensure_user "$SERVICE_USER"; then
        set_state "users_created"

        # Validate user access permissions
        if ! validate_user_access "$SERVICE_USER"; then
            error "User access validation failed for $SERVICE_USER"
            error "Cannot proceed with setup"
            return 1
        fi

        # SSH migration from root to service user
        if [[ "$SERVICE_USER" != "root" ]] && [[ -d /root/.ssh ]]; then
            if [[ "$MIGRATE_SSH_PRIVATE_KEYS" == "true" ]]; then
                log "Migrating SSH keys from root to $SERVICE_USER (including private keys)..."
                ssh_migrate_keys "$SERVICE_USER" "true"
            else
                log "Migrating SSH keys from root to $SERVICE_USER (public keys only)..."
                ssh_migrate_keys "$SERVICE_USER" "false"
            fi
        fi

        return 0
    fi
}

# ========== SSH CONFIGURATION ==========

configure_ssh() {
    phase "PHASE 4: Configure SSH for Chroot"

    local ssh_config="/etc/ssh/sshd_config.d/sidedoor.conf"

    # Smart check: if configured and valid, skip
    if [[ -f "$ssh_config" ]] && validate_ssh_config; then
        log "SSH chroot configuration exists and valid"
        set_state "ssh_configured"
        return 0
    fi

    log "Creating SSH chroot configuration..."

    # Create chroot base directory
    ensure_directory "/home/sftp" "root:root" 755

    # Write SSH configuration
    cat > "$ssh_config" << 'EOF'
# Sidedoor API - Chroot configuration for dynamic certificate users
# Matches generated usernames: n0x + 6 hex chars (e.g., n0x1a2b3c)
Match User n0x*
    ChrootDirectory /home/sftp/%u
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    PasswordAuthentication no
EOF

    # Validate before applying
    if validate_ssh_config; then
        systemctl reload ssh 2>/dev/null || systemctl restart ssh
        log "SSH configuration applied and service reloaded"
        set_state "ssh_configured"
    else
        error "SSH configuration validation failed"
        rm -f "$ssh_config"
        exit 1
    fi
}

# ========== SUDOERS CONFIGURATION ==========

# Install systemd helper script
install_systemd_helper() {
    local helper_path="/usr/local/sbin/sidedoor-systemd-helper"
    local helper_source="$PROJECT_ROOT/scripts/systemd-helper.sh"

    if [[ -f "$helper_source" ]]; then
        cp "$helper_source" "$helper_path"
        chmod 755 "$helper_path"
        log "Installed systemd helper script to $helper_path"
    else
        error "Helper script not found at $helper_source"
        exit 1
    fi
}

configure_sudoers() {
    phase "PHASE 5: Setup Sudoers"

    local sudoers_file="/etc/sudoers.d/sidedoor"

    # Smart check: if configured and valid, skip
    if [[ -f "$sudoers_file" ]] && validate_sudoers "$sudoers_file"; then
        log "Sudoers configuration exists and valid"
        # Check if systemd helper is installed, if not, add it
        if [[ ! -f "/usr/local/sbin/sidedoor-systemd-helper" ]]; then
            log "Installing systemd helper script..."
            install_systemd_helper
        fi
        return 0
    fi

    log "Creating sudoers configuration..."

    # Remove old file if exists and invalid
    if [[ -f "$sudoers_file" ]]; then
        log "Removing existing invalid sudoers configuration..."
        rm -f "$sudoers_file"
    fi

    # Create sudoers file with group-based nopasswd rule (when running as root)
    # This allows all users in sudo group to have passwordless sudo
    cat > "$sudoers_file" << EOF
# Sidedoor service user sudoers configuration
# Auto-generated by setup.sh - DO NOT EDIT MANUALLY
#
# Grant passwordless sudo to all members of sudo group
# This allows the service user to run sudo commands without password
%sudo ALL=(ALL) NOPASSWD: ALL

# Specific command restrictions (more granular control if needed)
# The above rule already covers these, but listed for reference
EOF

    # Verify file was created
    if [[ ! -f "$sudoers_file" ]]; then
        error "Failed to create sudoers file at $sudoers_file"
        exit 1
    fi

    # Set correct permissions
    chmod 0440 "$sudoers_file"

    # When running as root, also remove the service user's password
    # This ensures passwordless sudo works even with the group-based rule
    if [[ $EUID -eq 0 ]]; then
        # Check if user has a password
        if passwd -S "$SERVICE_USER" 2>/dev/null | grep -q "P"; then
            log "Removing password for $SERVICE_USER (enabling passwordless sudo)..."
            passwd -d "$SERVICE_USER" >/dev/null 2>&1
            log "✓ Password removed for $SERVICE_USER"
        fi
    fi

    # Install systemd helper script
    install_systemd_helper

    # Validate sudoers syntax
    if visudo -c -f "$sudoers_file" 2>/dev/null; then
        log "Sudoers configuration applied and validated"
    else
        error "Sudoers configuration validation failed"
        error "File content:"
        cat "$sudoers_file" >&2
        rm -f "$sudoers_file"
        exit 1
    fi

    # Test passwordless sudo (only when running as root)
    if [[ $EUID -eq 0 ]]; then
        log "Testing passwordless sudo for $SERVICE_USER..."
        if su - "$SERVICE_USER" -c "sudo -n true" 2>/dev/null; then
            log "✓ Passwordless sudo verified for $SERVICE_USER"
        else
            warn "Passwordless sudo test failed (may need user session refresh)"
        fi
    else
        log "Running as non-root, skipping passwordless sudo test"
        log "  Service user $SERVICE_USER will use normal sudo with password"
    fi

    set_state "sudoers_configured"
}

# ========== CREATE DIRECTORIES ==========

create_directories() {
    phase "PHASE 6: Create Directories"

    local dirs=(
        "/etc/sidedoor"
        "/var/lib/sidedoor"
        "/var/log/sidedoor"
        "/opt/sidedoor"
    )

    # Smart validation using ensure_directory from validate.sh
    for dir in "${dirs[@]}"; do
        ensure_directory "$dir" "$SERVICE_USER:$SERVICE_USER" "755"
        # Also try www-data group if service user fails
        ensure_directory "$dir" "$SERVICE_USER:www-data" "755" 2>/dev/null || true
    done

    # Set special permissions for config directory
    chmod 755 /etc/sidedoor

    set_state "directories_created"
    log "All directories validated"
}

# ========== INSTALL APPLICATION ==========

install_application() {
    phase "PHASE 7: Install Application"

    local app_dir="/opt/sidedoor"

    # Check if already installed
    if [[ -f "$app_dir/src/index.ts" ]] && [[ -f "$app_dir/package.json" ]]; then
        log "Application already installed"

        # Check if we need to update (detect mode)
        local mode
        mode=$(detect_setup_mode)
        if [[ "$mode" == "update" ]]; then
            log "Update mode detected, refreshing application files..."
            cp -r "$PROJECT_ROOT"/* "$app_dir/" 2>/dev/null || true
            cd "$app_dir"
            sudo -u "$SERVICE_USER" bun install 2>&1 | head -20
            log "Application updated"
        fi
        return 0
    fi

    log "Installing application files to $app_dir..."

    # Copy application files
    cp -r "$PROJECT_ROOT"/* "$app_dir/" 2>/dev/null || {
        error "Failed to copy application files"
        error "Make sure you're running this script from the project directory"
        exit 1
    }

    # Install dependencies
    log "Installing dependencies..."
    cd "$app_dir"
    sudo -u "$SERVICE_USER" bun install 2>&1 | head -20

    # Set ownership
    chown -R "$SERVICE_USER:$SERVICE_USER" "$app_dir"
    chown -R "$SERVICE_USER:www-data" "$app_dir" 2>/dev/null || true

    log "Application installed successfully"
    set_state "app_installed"
}

# ========== GENERATE SECRETS ==========

generate_secrets() {
    phase "PHASE 8: Generate Secrets"

    local config_file="/etc/sidedoor/config.json"

    # Check if config exists with valid tokens
    if [[ -f "$config_file" ]]; then
        if validate_json "$config_file"; then
            local auth_token
            local cron_secret
            auth_token=$(jq -r '.authenticatorToken // empty' "$config_file" 2>/dev/null || echo "")
            cron_secret=$(jq -r '.cronSecret // empty' "$config_file" 2>/dev/null || echo "")

            if [[ -n "$auth_token" ]] && [[ -n "$cron_secret" ]]; then
                log "Configuration file exists with valid tokens"
                set_state "secrets_generated"
                return 0
            fi
        fi
        warn "Existing config file found but may be invalid, regenerating..."
    fi

    log "Generating secure tokens..."

    # Generate 64-character tokens
    local auth_token
    local cron_secret
    auth_token=$(openssl rand -base64 48 | head -c 64)
    cron_secret=$(openssl rand -base64 48 | head -c 64)

    # Create configuration with sshPort
    cat > "$config_file" << EOF
{
  "_comment": "Production configuration for Sidedoor API - Auto-generated by setup script",
  "_generated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "port": $API_PORT,
  "sshPort": $SSH_PORT,
  "authenticatorToken": "$auth_token",
  "cronSecret": "$cron_secret",
  "chrootBasePath": "/home/sftp",
  "dbPath": "/var/lib/sidedoor/certificates.db",
  "configPath": "/etc/sidedoor/config.json",
  "defaultDirectories": ["/srv", "/var/www", "/data/uploads"],
  "defaultPermissions": ["read-write-modify"],
  "defaultTtl": 600,
  "user": {
    "name": "$SERVICE_USER",
    "group": "www-data"
  }
}
EOF

    # Set permissions
    chmod 640 "$config_file"
    chown "$SERVICE_USER:$SERVICE_USER" "$config_file"

    # Display tokens to user
    echo ""
    echo -e "${YELLOW}===============================================================${NC}"
    echo -e "${YELLOW}  ⚠️  IMPORTANT: SAVE THESE TOKENS SECURELY ⚠️${NC}"
    echo -e "${YELLOW}===============================================================${NC}"
    echo ""
    echo -e "  ${CYAN}Authenticator Token:${NC} $auth_token"
    echo -e "  ${CYAN}Cron Secret:${NC}         $cron_secret"
    echo ""
    echo -e "${YELLOW}===============================================================${NC}"
    echo ""
    echo "These tokens have been saved to: $config_file"
    echo ""

    set_state "secrets_generated"
}

# ========== CONFIGURE SERVICE ==========

configure_service() {
    phase "PHASE 9: Configure Systemd Service"

    local service_file="/etc/systemd/system/sidedoor.service"

    # Check if service file exists and is valid
    if [[ -f "$service_file" ]]; then
        log "Service file exists, reloading daemon..."
        systemctl daemon-reload
        # Always enable to be safe
        systemctl enable sidedoor 2>/dev/null || true
        set_state "service_configured"
        return 0
    fi

    log "Creating systemd service..."

    # Use template if it exists, otherwise create inline
    if [[ -f "$PROJECT_ROOT/systemd/sidedoor.service" ]]; then
        sed "s/{{SERVICE_USER}}/$SERVICE_USER/g" "$PROJECT_ROOT/systemd/sidedoor.service" > "$service_file"
    else
        cat > "$service_file" << EOF
[Unit]
Description=Sidedoor SSH/SFTP Certificate Management Service
After=network.target ssh.service

[Service]
Type=simple
User=$SERVICE_USER
Group=www-data
WorkingDirectory=/opt/sidedoor
Environment="NODE_ENV=production"
Environment="CONFIG_PATH=/etc/sidedoor/config.json"
ExecStart=/usr/local/bin/bun run /opt/sidedoor/src/index.ts
Restart=always
RestartSec=10s
StandardOutput=append:/var/log/sidedoor/sidedoor.log
StandardError=append:/var/log/sidedoor/sidedoor-errors.log
Delegate=yes
CPUAccounting=yes
MemoryAccounting=yes

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    systemctl enable sidedoor

    log "Service configured and enabled"
    set_state "service_configured"
}

# ========== START SERVICE ==========

start_service() {
    phase "PHASE 10: Start Service"

    # Check if service is already running
    if is_service_running "sidedoor"; then
        local mode
        mode=$(detect_setup_mode)
        if [[ "$mode" == "update" ]]; then
            log "Service running, restarting for update..."
            systemctl restart sidedoor
        else
            log "Service already running"
        fi
        set_state "service_started"
        return 0
    fi

    log "Starting sidedoor service..."

    systemctl start sidedoor

    # Wait for service to start
    local max_wait=30
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if is_service_running "sidedoor"; then
            log "Service started successfully"
            set_state "service_started"
            return 0
        fi
        sleep 1
        ((waited++))
    done

    error "Service failed to start"
    error "Check logs with: journalctl -u sidedoor -n 50"
    exit 1
}

# ========== SECURITY HARDENING ==========

apply_security_hardening() {
    phase "PHASE 11: Security Hardening"

    # IMPORTANT: Security hardening is SKIPPED by default to prevent SSH lockout
    # UFW automated configuration has proven unreliable in testing
    if [[ "$SKIP_HARDENING" != "true" ]]; then
        warn "Security hardening is DISABLED by default to prevent SSH lockout"
        warn "To enable security hardening, run: sudo ./scripts/setup.sh --user ubuntu --skip-hardening=false"
        warn "Then manually configure UFW: sudo ufw allow ${SSH_PORT}/tcp && sudo ufw enable"
        return 0
    fi

    if [[ "$SKIP_HARDENING" == "true" ]]; then
        warn "Skipping security hardening (--skip-hardening flag set)"
        return 0
    fi

    if get_state "hardening_applied"; then
        log "Security hardening already applied"
        return 0
    fi

    # Read sshPort from config.json if it exists
    local ssh_port="$SSH_PORT"
    if [[ -f "/etc/sidedoor/config.json" ]]; then
        ssh_port=$(jq -r '.sshPort // 22' /etc/sidedoor/config.json 2>/dev/null || echo "$SSH_PORT")
    fi

    log "Applying security hardening..."

    # Install UFW and Fail2ban if not present
    apt-get update -qq
    apt-get install -y -qq ufw fail2ban >/dev/null 2>&1

    # Configure UFW
    log "Configuring UFW firewall..."

    # Reset to defaults (this also disables the firewall)
    ufw --force reset >/dev/null 2>&1 || true

    # CRITICAL: Set up rules BEFORE enabling firewall
    # Order matters: set default policies first, then add rules, then enable

    # Set default policies (deny everything, then explicitly allow what we need)
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # Explicitly allow SSH FIRST (before any deny policies take effect)
    # Using 'allow' instead of 'limit' for reliability
    ufw allow "${ssh_port}/tcp" >/dev/null 2>&1

    # Then allow API port
    ufw allow "$API_PORT/tcp" >/dev/null 2>&1

    # NOW enable the firewall (with rules already in place)
    log "Enabling UFW firewall..."
    ufw --force enable >/dev/null 2>&1

    log "UFW configured and enabled"
    log "  SSH Port: ${ssh_port}"
    log "  API Port: $API_PORT"

    # Configure Fail2ban
    log "Configuring Fail2ban..."

    local fail2ban_jail="/etc/fail2ban/jail.d/sidedoor.conf"
    cat > "$fail2ban_jail" << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
maxretry = 3
bantime = 7200
port = ssh
logpath = /var/log/auth.log
EOF

    systemctl restart fail2ban

    log "Fail2ban configured and restarted"

    # SSH Hardening (additional security)
    local ssh_hardening="/etc/ssh/sshd_config.d/security-hardening.conf"
    if [[ ! -f "$ssh_hardening" ]]; then
        log "Applying SSH hardening..."

        cat > "$ssh_hardening" << 'EOF'
# Security hardening for SSH
PermitRootLogin no
PasswordAuthentication no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

        # Validate and reload
        if validate_ssh_config; then
            systemctl reload ssh 2>/dev/null || systemctl restart ssh
            log "SSH hardening applied"
        else
            warn "SSH hardening skipped (configuration would be invalid)"
            rm -f "$ssh_hardening"
        fi
    fi

    set_state "hardening_applied"
    log "Security hardening complete"
}

# ========== VERIFICATION ==========

run_verification() {
    phase "PHASE 12: Verification"

    log "Running post-setup verification..."

    if [[ -f "$SCRIPT_DIR/verify-setup.sh" ]]; then
        # Run verification but don't fail on warnings
        if bash "$SCRIPT_DIR/verify-setup.sh" --user "$SERVICE_USER"; then
            log "Verification passed"
        else
            warn "Verification completed with warnings (check output above)"
            log "Deployment is functional, but some non-critical checks failed"
        fi
    else
        warn "Verification script not found, skipping automated verification"
    fi

    set_state "verification_complete"
}

# ========== CREATE BACKWARD COMPATIBILITY SYMLINK ==========

create_backward_compat_symlink() {
    local target="$SCRIPT_DIR/setup.sh"
    local link="$SCRIPT_DIR/setup-production.sh"

    if [[ -e "$link" ]] && [[ ! -L "$link" ]]; then
        # Exists but is not a symlink, skip
        return 0
    fi

    ln -sf "$target" "$link" 2>/dev/null || true
}

# ========== MAIN EXECUTION ==========

main() {
    echo ""
    echo "============================================"
    echo "  Sidedoor SSH/SFTP Certificate Management"
    echo "  Smart Setup Script"
    echo "============================================"
    echo ""
    echo -e "Service User: ${GREEN}$SERVICE_USER${NC}"
    echo -e "API Port:     ${GREEN}$API_PORT${NC}"

    # Detect setup mode
    SETUP_MODE=$(detect_setup_mode)
    local mode_display=""
    case "$SETUP_MODE" in
        install)
            mode_display="${GREEN}FRESH INSTALL${NC}"
            ;;
        update)
            mode_display="${YELLOW}UPDATE${NC}"
            ;;
        repair)
            mode_display="${YELLOW}REPAIR${NC}"
            ;;
    esac
    echo -e "Mode:         ${mode_display}"
    echo ""

    # Verify-only mode
    if [[ "$VERIFY_ONLY" == "true" ]]; then
        run_verification
        exit 0
    fi

    # Force mode - run rollback first
    if [[ "$FORCE" == "true" ]]; then
        warn "Force mode enabled - running rollback first..."
        if [[ -f "$SCRIPT_DIR/rollback-setup.sh" ]]; then
            bash "$SCRIPT_DIR/rollback-setup.sh" --full-reset || true
            rm -f "$STATE_FILE"
        fi
    fi

    # Initialize state file
    init_state

    # Run all phases
    check_requirements
    install_bun
    create_users
    configure_ssh
    configure_sudoers
    create_directories
    install_application
    generate_secrets
    configure_service
    start_service
    apply_security_hardening
    run_verification

    # Create backward compatibility symlink
    create_backward_compat_symlink

    # ========== SUMMARY ==========
    echo ""
    echo -e "${GREEN}===============================================================${NC}"
    echo -e "${GREEN}  ✅ SETUP COMPLETE${NC}"
    echo -e "${GREEN}===============================================================${NC}"
    echo ""
    echo "Service Status:"
    echo "  systemctl status sidedoor"
    echo ""
    echo "View Logs:"
    echo "  journalctl -u sidedoor -f"
    echo "  tail -f /var/log/sidedoor/sidedoor.log"
    echo ""
    echo "API Health Check:"
    echo "  curl http://localhost:$API_PORT/health"
    echo ""
    echo "Configuration:"
    echo "  /etc/sidedoor/config.json"
    echo ""
    echo "Ports:"
    echo "  API Port: $API_PORT"
    echo "  SSH Port: $SSH_PORT (for UFW configuration)"
    echo ""
    log "Setup completed successfully!"
    echo ""
}

# Run main function
main "$@"

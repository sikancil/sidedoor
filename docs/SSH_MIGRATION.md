# SSH Migration Documentation

Sidedoor automatically migrates SSH keys from root to the service user during installation, providing a secure transition from initial droplet access to service-user-based access.

---

## Overview

**Location**: `scripts/lib/ssh-migrate.sh` (~750 lines)

**Purpose**: Merge SSH configuration from root user to service user

**Features**:
- Merges `authorized_keys` with deduplication
- Merges SSH `config` files (preserves host entries)
- Merges `known_hosts` with deduplication
- Copies public keys by default
- Optionally copies private keys (with flag)
- Tracks state for idempotency
- Supports rollback with backup
- Disables root SSH login after migration

---

## When Migration Occurs

### Automatic During Installation

SSH migration is automatically triggered during installation when:

1. Running as root or via sudo
2. Service user is NOT root
3. `/root/.ssh/` directory exists

### Install Script

```bash
# Triggers automatic migration
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo bash
```

### Setup Script

```bash
# Manual setup also triggers migration
sudo ./scripts/setup.sh --user ubuntu
```

---

## Migration Modes

### Default Mode (Public Keys Only)

**Safe default**: Merges authorized_keys, config, known_hosts, and public keys

```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo bash
```

**What gets migrated**:
- `authorized_keys` - Merged (deduplicated by key fingerprint)
- `config` - Merged (host entries preserved)
- `known_hosts` - Merged (deduplicated)
- `*.pub` files - Copied
- Private keys - NOT copied

### Private Key Mode

**Advanced**: Includes private key files

```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | \
  sudo MIGRATE_SSH_PRIVATE_KEYS=true bash
```

**Additional migrations**:
- `id_rsa`, `id_ed25519`, `id_ecdsa`, etc. - Copied (if not existing)
- `*.pub` files - Copied for each private key

**Warning**: Only use if you understand the security implications.

---

## Migration Process

### Phase 1: Detection

1. Checks if running as root
2. Verifies service user is not root
3. Checks for `/root/.ssh/` directory
4. Checks if migration already completed (idempotent)

### Phase 2: Backup

Creates backup of existing service user SSH files:

```
/var/lib/sidedoor/ssh-backup-ubuntu/
├── authorized_keys       # Backup before merge
├── config                # Backup before merge
├── known_hosts           # Backup before merge
├── id_rsa.migrated       # Marker for migrated files
└── id_ed25519.migrated   # Marker for migrated files
```

### Phase 3: Migration

| Source File | Target File | Operation |
|-------------|-------------|-----------|
| `/root/.ssh/authorized_keys` | `~ubuntu/.ssh/authorized_keys` | Merge (deduplicate) |
| `/root/.ssh/config` | `~ubuntu/.ssh/config` | Merge (host entries) |
| `/root/.ssh/known_hosts` | `~ubuntu/.ssh/known_hosts` | Merge (deduplicate) |
| `/root/.ssh/*.pub` | `~ubuntu/.ssh/*.pub` | Copy |
| `/root/.ssh/id_*` | `~ubuntu/.ssh/id_*` | Copy (with flag only) |

### Phase 4: Security

Disables root SSH login for security:

```
/etc/ssh/sshd_config.d/sidedoor-root-disable.conf
  PermitRootLogin no
  PasswordAuthentication no
```

Reloads SSH service to apply changes.

### Phase 5: State

Records migration in state file:

```
/etc/sidedoor/.ssh-migration-state
  ssh_migrated_to_ubuntu=2026-01-31T14:02:15Z
  ssh_migrated_to_ubuntu_with_private=2026-01-31T14:02:15Z
```

---

## Deduplication

### authorized_keys

Keys are deduplicated by SSH key fingerprint:

```bash
# Extract fingerprint from key
ssh-keygen -lf ~/.ssh/id_rsa.pub

# Check if key already exists
# If yes: skip (keep existing)
# If no: add to target file
```

### known_hosts

Entries are deduplicated by host pattern:

```bash
# Extract host pattern
# If host exists: skip (keep existing)
# If host doesn't exist: add to target file
```

### config

Host entries are merged intelligently:

```bash
# If host exists in target: skip (keep existing)
# If host doesn't exist: add entire host block
```

---

## Idempotency

SSH migration is idempotent - safe to run multiple times.

### Check for Previous Migration

```bash
# State file tracks migration
cat /etc/sidedoor/.ssh-migration-state
# ssh_migrated_to_ubuntu=2026-01-31T14:02:15Z
```

### Behavior on Re-run

| Scenario | Behavior |
|----------|----------|
| Already migrated (public) | Skips (logs "already completed") |
| Already migrated (private) | Skips (logs "already completed") |
| Partial migration | Continues from last state |
| New keys in source | Merges new keys only |

---

## Rollback

If needed, you can rollback SSH migration:

### Automatic Rollback

```bash
# From setup script
sudo ./scripts/setup.sh --user ubuntu --ssh-rollback
```

### Manual Rollback

```bash
# Source library and run rollback
sudo source /path/to/sidedoor/scripts/lib/ssh-migrate.sh
sudo ssh_rollback_migration "ubuntu"
```

### Rollback Process

1. **Backup check**: Looks for backup directory
2. **Restore**: Restores files from backup (if available)
3. **Cleanup**: Removes migrated keys marked with `.migrated` files
4. **State**: Clears migration state from state file
5. **Security**: Re-enables root SSH login

### Rollback with Backup

If backup exists:
- Restores original `authorized_keys`, `config`, `known_hosts`
- Removes migrated public/private keys
- Removes backup directory

### Rollback without Backup

If no backup exists:
- Warns user about manual cleanup
- Re-enables root SSH login
- Clears migration state

---

## Security

### Root SSH Login Disabled

After successful migration, root SSH login is disabled:

```
/etc/ssh/sshd_config.d/sidedoor-root-disable.conf
  # Security: Disable root SSH login after SSH migration
  # Root SSH keys have been migrated to ubuntu
  # Use 'ubuntu@<hostname>' for SSH access instead
  PermitRootLogin no
  PasswordAuthentication no
```

### Validation

SSH configuration is validated before reload:

```bash
# Test configuration
sudo sshd -t

# Only reload if valid
sudo systemctl reload ssh
```

### Private Key Protection

Private keys have restrictive permissions:

```bash
# Directory: 700 (drwx------)
chmod 700 ~/.ssh

# Private keys: 600 (-rw-------)
chmod 600 ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_ed25519
```

---

## State Management

### State File

```
Location: /etc/sidedoor/.ssh-migration-state
Permissions: 600 (-rw-------)
```

### State Entries

```
ssh_migrated_to_ubuntu=2026-01-31T14:02:15Z
ssh_migrated_to_ubuntu_with_private=2026-01-31T14:02:15Z
```

### State Functions

```bash
# Check if migrated
_ssh_is_migrated "ubuntu" "false"  # Public keys only
_ssh_is_migrated "ubuntu" "true"   # With private keys

# Mark as migrated
_ssh_mark_migrated "ubuntu" "false" "2026-01-31T14:02:15Z"
_ssh_mark_migrated "ubuntu" "true" "2026-01-31T14:02:15Z"
```

---

## Troubleshooting

### Migration Not Running

Check if conditions are met:

```bash
# Must be root
echo $EUID  # Should be 0

# Service user must not be root
echo $SERVICE_USER  # Should NOT be "root"

# Root SSH directory must exist
ls -la /root/.ssh/
```

### Keys Not Migrated

Check migration state:

```bash
# View migration state
sudo cat /etc/sidedoor/.ssh-migration-state

# Check if already migrated
sudo grep "ssh_migrated" /etc/sidedoor/.ssh-migration-state
```

### Root SSH Still Enabled

Check SSH configuration:

```bash
# Check if config exists
sudo cat /etc/ssh/sshd_config.d/sidedoor-root-disable.conf

# Validate SSH config
sudo sshd -t

# Check if SSH was reloaded
sudo systemctl status ssh
```

### Rollback Fails

Check for backup directory:

```bash
# Check if backup exists
sudo ls -la /var/lib/sidedoor/ssh-backup-ubuntu/

# If no backup, manual cleanup required
sudo ls -la ~/.ubuntu/.ssh/
```

---

## Manual Migration

If automatic migration doesn't work, you can manually migrate keys:

```bash
# Source the library
sudo source /path/to/sidedoor/scripts/lib/ssh-migrate.sh

# Run migration
sudo ssh_migrate_keys "ubuntu"          # Public keys only
sudo ssh_migrate_keys "ubuntu" "true"   # With private keys
```

---

## Examples

### Fresh Droplet

```bash
# New droplet with root SSH access
ssh root@droplet-ip

# Run installer (triggers automatic migration)
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo bash

# Root SSH disabled, use ubuntu user
ssh ubuntu@droplet-ip
```

### Existing Setup

```bash
# Re-run setup (skips if already migrated)
sudo ./scripts/setup.sh --user ubuntu

# Force migration with private keys
sudo MIGRATE_SSH_PRIVATE_KEYS=true ./scripts/setup.sh --user ubuntu
```

### Rollback

```bash
# Rollback migration
sudo ./scripts/setup.sh --user ubuntu --ssh-rollback

# Root SSH re-enabled
ssh root@droplet-ip
```

---

## Best Practices

1. **Test migration** in non-production environment first
2. **Backup SSH keys** before migration (automatic with script)
3. **Verify access** after migration before closing root session
4. **Use private key mode** only if necessary and understood
5. **Keep backup** until service user access is verified
6. **Document migration** for audit trail
7. **Test rollback** procedure for disaster recovery

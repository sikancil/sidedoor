# Installation Guide

This guide covers installing Sidedoor SSH/SFTP Certificate Management system.

---

## Quick Install (One-Command)

### Standard Installation (Ubuntu Default User)

```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo bash
```

This installs with default settings:
- **Service User**: `ubuntu`
- **Branch**: `wizard`
- **SSH Migration**: Public keys only

### Custom Installation Options

```bash
# Custom branch
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo SIDEDOOR_BRANCH=main bash

# Custom service user
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo SIDEDOOR_USER=sidedoor bash

# Include SSH private keys in migration
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo MIGRATE_SSH_PRIVATE_KEYS=true bash

# Combine options
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo SIDEDOOR_USER=sidedoor MIGRATE_SSH_PRIVATE_KEYS=true bash
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIDEDOOR_BRANCH` | `wizard` | Git branch to clone |
| `SIDEDOOR_USER` | `ubuntu` | Service user name |
| `SKIP_SETUP` | `false` | Skip setup.sh execution |
| `MIGRATE_SSH_PRIVATE_KEYS` | `false` | Include private keys in SSH migration |
| `DEBUG` | `false` | Enable debug logging |

---

## Manual Installation

### Prerequisites

- **OS**: Ubuntu 22.04+ or 24.04+
- **Privileges**: Root or sudo access
- **Dependencies**: git, curl, jq, unzip, ca-certificates (auto-installed)

### Step 1: Clone Repository

```bash
git clone -b wizard --depth 1 https://github.com/sikancil/sidedoor.git /tmp/sidedoor-bootstrap
cd /tmp/sidedoor-bootstrap
```

### Step 2: Run Setup Script

```bash
# Standard setup (default ubuntu user)
sudo ./scripts/setup.sh --user ubuntu

# With custom user
sudo ./scripts/setup.sh --user sidedoor

# Include SSH private keys
sudo ./scripts/setup.sh --user ubuntu --migrate-ssh-private-keys

# Skip security hardening
sudo ./scripts/setup.sh --user ubuntu --skip-hardening

# Verification mode (no changes)
sudo ./scripts/setup.sh --user ubuntu --verify-only
```

---

## Setup Script Options

| Option | Description |
|--------|-------------|
| `--user <name>` | Service user name (default: ubuntu) |
| `--force` | Force re-setup even if already set up |
| `--skip-hardening` | Skip security hardening steps |
| `--verify-only` | Verify setup without making changes |
| `--ssh-key <path>` | Path to SSH public key for service user |
| `--migrate-ssh-private-keys` | Include private keys in SSH migration |

---

## What Gets Installed

### System Components

1. **Service User**: Created with sudo and www-data group membership
2. **Systemd Service**: `/etc/systemd/system/sidedoor.service`
3. **Application Files**: `/opt/sidedoor/`
4. **Configuration**: `/etc/sidedoor/config.json`
5. **Database**: `/var/lib/sidedoor/certificates.db`
6. **Log Directory**: `/var/log/sidedoor/`

### SSH Components

1. **SSH Configuration**: `/etc/ssh/sshd_config.d/sidedoor.conf`
2. **SFTP Base Directory**: `/home/sftp/`
3. **Chroot Setup**: Per-certificate chroot jails
4. **Bind Mounts**: Source directories mounted in chroots

### Security Components

1. **Systemd Helper**: `/usr/local/sbin/sidedoor-systemd-helper`
2. **Sudoers Entry**: `/etc/sudoers.d/sidedoor`
3. **UFW Rules**: Port 3000/tcp (configurable)
4. **Root SSH Login**: Disabled after migration

---

## SSH Migration

During installation, SSH keys are migrated from root to the service user:

### Default Behavior (Public Keys Only)

Merges authorized_keys, config, known_hosts, and public keys:
```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo bash
```

### Include Private Keys

```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo MIGRATE_SSH_PRIVATE_KEYS=true bash
```

**Warning**: Private key migration is sensitive. Only use if you understand the security implications.

### What Gets Migrated

| Source | Target | Description |
|--------|--------|-------------|
| `/root/.ssh/authorized_keys` | `~ubuntu/.ssh/authorized_keys` | Merged (deduplicated) |
| `/root/.ssh/config` | `~ubuntu/.ssh/config` | Merged (host entries) |
| `/root/.ssh/known_hosts` | `~ubuntu/.ssh/known_hosts` | Merged (deduplicated) |
| `/root/.ssh/*.pub` | `~ubuntu/.ssh/*.pub` | Copied |
| `/root/.ssh/id_*` | `~ubuntu/.ssh/id_*` | Copied (with flag only) |

### Rollback SSH Migration

If needed, you can rollback SSH migration:

```bash
# From the cloned repo
sudo bash /path/to/sidedoor/scripts/setup.sh --user ubuntu --ssh-rollback

# Or manually
sudo source /path/to/sidedoor/scripts/lib/ssh-migrate.sh
sudo ssh_rollback_migration "ubuntu"
```

---

## Post-Installation

### Verify Service Status

```bash
# Check service is running
sudo systemctl status sidedoor

# Check service logs
sudo journalctl -u sidedoor -f

# Check recent log file
sudo tail -f /var/log/sidedoor/setup.*.log
```

### Verify API Health

```bash
curl http://localhost:3000/health
```

Expected response:
```json
{
  "status": "healthy",
  "checks": {
    "database": "ok",
    "ssh": "ok"
  }
}
```

### Test Certificate Creation

```bash
curl -X POST http://localhost:3000/api/certificates \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -d '{
    "directoryPath": "/home/sftp/test/uploads",
    "permissions": ["sftp", "read-write"],
    "ttl": 3600,
    "authenticatorToken": "YOUR_TOKEN"
  }'
```

---

## Service Management

### Start/Stop/Restart

```bash
sudo systemctl start sidedoor
sudo systemctl stop sidedoor
sudo systemctl restart sidedoor
```

### Enable at Boot

```bash
sudo systemctl enable sidedoor
```

### View Logs

```bash
# Service logs
sudo journalctl -u sidedoor -f

# Application logs
sudo tail -f /var/log/sidedoor/sidedoor.*.log

# All logs
sudo ls -la /var/log/sidedoor/
```

---

## Troubleshooting

### Installation Fails

1. **Check OS compatibility**:
   ```bash
   grep "Ubuntu" /etc/os-release
   ```

2. **Check available disk space**:
   ```bash
   df -h
   ```

3. **Check network connectivity**:
   ```bash
   curl -I https://github.com
   ```

4. **Review installation logs**:
   ```bash
   sudo cat /var/log/sidedoor/install.*.log
   sudo cat /var/log/sidedoor/setup.*.log
   ```

### Service Won't Start

1. **Check service status**:
   ```bash
   sudo systemctl status sidedoor
   ```

2. **Check service logs**:
   ```bash
   sudo journalctl -u sidedoor -n 50
   ```

3. **Verify configuration**:
   ```bash
   sudo cat /etc/sidedoor/config.json
   ```

4. **Check database**:
   ```bash
   sudo ls -la /var/lib/sidedoor/
   ```

### SSH Access Issues

1. **Check SSH configuration**:
   ```bash
   sudo sshd -t
   ```

2. **Check SSH service**:
   ```bash
   sudo systemctl status ssh
   ```

3. **Verify chroot setup**:
   ```bash
   sudo ls -la /home/sftp/
   ```

### Port Already in Use

```bash
# Check what's using port 3000
sudo lsof -i :3000

# Change port in config
sudo nano /etc/sidedoor/config.json
sudo systemctl restart sidedoor
```

---

## Uninstallation

See [UNINSTALLATION.md](UNINSTALLATION.md) for complete uninstall instructions.

```bash
# Preview what would be removed
sudo ./scripts/uninstall.sh --dry-run

# Actual uninstall
sudo ./scripts/uninstall.sh
```

---

## Next Steps

After installation:

1. Configure your authenticator token in `/etc/sidedoor/config.json`
2. Set up firewall rules for port 3000
3. Configure bind mount directories for SFTP access
4. Review logs in `/var/log/sidedoor/`
5. Test certificate creation and SFTP access

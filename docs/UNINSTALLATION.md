# Uninstallation Guide

This guide covers removing Sidedoor from your system.

---

## Quick Uninstall

### Preview Mode (Safe, No Changes)

```bash
sudo ./scripts/uninstall.sh --dry-run
```

### Actual Uninstall

```bash
sudo ./scripts/uninstall.sh
```

---

## What Gets Removed

### Services and Timers

- **Sidedoor service**: Stopped and disabled
- **Systemd timers**: All `sidedoor-*.timer` units removed
- **Systemd helper**: `/usr/local/sbin/sidedoor-systemd-helper`

### Dynamic Users

- **Certificate users**: All `n0x######` format users (e.g., `n0x1a2b3c`)
- **Home directories**: `/home/sftp/n0x*/`
- **Processes**: All user processes killed

### Data and Configuration

- **Database**: `/var/lib/sidedoor/certificates.db`
- **Configuration**: `/etc/sidedoor/config.json`
- **State files**: `.setup-state`, `.ssh-migration-state`
- **Application files**: `/opt/sidedoor/`

### SSH Configuration

- **SSH config**: `/etc/ssh/sshd_config.d/sidedoor.conf`
- **Bind mounts**: All chroot bind mounts (lazy unmount)
- **SFTP base**: `/home/sftp/` (only if empty)

### Repository Clone

- **Cloned repo**: `/tmp/sidedoor-bootstrap-*` (on remote systems)
- **Droplet clone**: `/home/ubuntu/sidedoor` or `/home/sidedoor/sidedoor`

---

## What Gets Preserved

### Users

- **Service users**: `ubuntu`, `SERVICE_USER` (custom service user)
- **SSH keys**: All `~/.ssh/*` files

### Development Environment

- **Local codebase**: `/Users/dimasarif/DATA/WORK/Pegasus/vm-access/`
- **Source directories**: Real directories behind chroot bind mounts

### System

- **Systemd**: NOT removed (only Sidedoor units)
- **Other services**: NOT affected
- **User data**: NOT touched

---

## Dry-Run Mode

Always run dry-run first to preview what will be removed:

```bash
sudo ./scripts/uninstall.sh --dry-run
```

Example output:
```
[DRY-RUN] Would stop service: sidedoor
[DRY-RUN] Would disable and remove: /etc/systemd/system/sidedoor-n0x1a2b3c.timer (2.1 KB)
[DRY-RUN] Would remove user: n0x1a2b3c (home: /home/sftp/n0x1a2b3c, 2 processes)
[DRY-RUN] Would unmount: /home/sftp/n0x1a2b3c/srv/data (from: /srv/data)
[DRY-RUN] Would remove: /var/lib/sidedoor/certificates.db (128 KB)
[DRY-RUN] Would remove: /opt/sidedoor/ (2.3 MB - 45 files)

=== Removal Summary ===
Services stopped: 1
Timers removed: 3
Users removed: 2
Files removed: 156 MB across 156 files
Mount points unmounted: 6
```

---

## Uninstall Phases

The uninstall script runs through 10 phases:

### Phase 1: Stop Services

Stops the Sidedoor service and all timers.

```bash
systemctl stop sidedoor
systemctl stop 'sidedoor-*.timer'
```

### Phase 2: Remove Systemd Units

Disables and removes systemd unit files.

```bash
# Remove timers
systemctl disable sidedoor-n0x*.timer
rm -f /etc/systemd/system/sidedoor-*.timer

# Remove service
systemctl disable sidedoor
rm -f /etc/systemd/system/sidedoor.service
rm -f /etc/systemd/system/sidedoor-helper@.service

# Reload daemon
systemctl daemon-reload
```

### Phase 3: Remove Dynamic Users

Finds and removes all `n0x######` certificate users.

```bash
# Find all n0x* users
grep -E '^n0x[0-9a-f]{6}:' /etc/passwd | cut -d: -f1

# Kill processes and remove user
pkill -u n0x1a2b3c
userdel -r n0x1a2b3c
```

### Phase 4: Cleanup Chroot Mounts

Lazy unmounts all bind mounts under chroot homes.

```bash
# Lazy unmount to avoid damaging source directories
umount -l /home/sftp/n0x1a2b3c/srv/data
umount -l /home/sftp/n0x1a2b3c/var/www
```

### Phase 5: Remove Database

Deletes the SQLite certificate database.

```bash
rm -f /var/lib/sidedoor/certificates.db
rmdir /var/lib/sidedoor  # Only if empty
```

### Phase 6: Remove Configuration

Removes Sidedoor configuration files.

```bash
rm -f /etc/sidedoor/config.json
rmdir /etc/sidedoor  # Only if empty
```

### Phase 7: Remove Application Files

Removes installed application artifacts.

```bash
rm -rf /opt/sidedoor
rm -f /usr/local/bin/sidedoor-systemd-helper
```

### Phase 8: Remove State Files

Removes setup and migration state files.

```bash
rm -f /var/lib/sidedoor/.setup-state
rm -f /var/lib/sidedoor/.ssh-migration-state
```

### Phase 9: Remove Repository Clone

Removes cloned repository (only on remote systems).

```bash
rm -rf /tmp/sidedoor-bootstrap-*
rm -rf /home/ubuntu/sidedoor
```

**Note**: Skips local development directory at `/Users/dimasarif/DATA/WORK/Pegasus/vm-access/`

### Phase 10: Verification

Verifies cleanup was successful and shows removal summary.

---

## Manual Uninstall

If the script doesn't work, you can manually remove components:

### 1. Stop Service

```bash
sudo systemctl stop sidedoor
sudo systemctl disable sidedoor
```

### 2. Remove Certificate Users

```bash
# List all n0x* users
getent passwd | grep '^n0x'

# Remove each user
for user in $(getent passwd | grep -o '^n0x[a-f0-9]\{6\}'); do
    sudo pkill -u "$user" 2>/dev/null || true
    sudo userdel -r "$user"
done
```

### 3. Unmount Chroots

```bash
# Find and unmount all bind mounts
mount | grep '/home/sftp/' | awk '{print $3}' | while read mount; do
    sudo umount -l "$mount"
done
```

### 4. Remove Files

```bash
# Systemd units
sudo rm -f /etc/systemd/system/sidedoor.service
sudo rm -f /etc/systemd/system/sidedoor*.timer
sudo rm -f /etc/systemd/system/sidedoor-helper@.service
sudo systemctl daemon-reload

# Application files
sudo rm -rf /opt/sidedoor

# Database and config
sudo rm -rf /var/lib/sidedoor
sudo rm -rf /etc/sidedoor

# SSH config
sudo rm -f /etc/ssh/sshd_config.d/sidedoor.conf
sudo systemctl reload ssh

# Sudoers
sudo rm -f /etc/sudoers.d/sidedoor

# Helper script
sudo rm -f /usr/local/bin/sidedoor-systemd-helper
```

### 5. Remove SFTP Base (if empty)

```bash
# Only remove if empty
sudo rmdir /home/sftp 2>/dev/null || echo "Directory not empty"
```

---

## Verification

After uninstall, verify everything is removed:

### Check Service

```bash
sudo systemctl status sidedoor
# Expected: Unit sidedoor.service could not be found
```

### Check Users

```bash
getent passwd | grep '^n0x'
# Expected: No output
```

### Check Mounts

```bash
mount | grep '/home/sftp/'
# Expected: No output
```

### Check Files

```bash
sudo ls -la /var/lib/sidedoor
# Expected: No such file or directory

sudo ls -la /etc/sidedoor
# Expected: No such file or directory
```

---

## Reinstallation

After uninstall, you can reinstall:

```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo bash
```

Or with custom options:

```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | \
  sudo SIDEDOOR_USER=ubuntu MIGRATE_SSH_PRIVATE_KEYS=true bash
```

---

## Troubleshooting

### Users Cannot Be Removed

If users have running processes:

```bash
# Force kill processes
for user in $(getent passwd | grep -o '^n0x[a-f0-9]\{6\}'); do
    sudo pkill -9 -u "$user" 2>/dev/null || true
    sudo userdel -r "$user"
done
```

### Mount Points Cannot Be Unmounted

```bash
# Lazy unmount (force)
mount | grep '/home/sftp/' | awk '{print $3}' | while read mount; do
    sudo umount -l -f "$mount" 2>/dev/null || true
done
```

### Files Cannot Be Removed

```bash
# Check what's using the file
sudo lsof +D /opt/sidedoor

# Force remove
sudo rm -rf /opt/sidedoor
```

### Script Fails Partway Through

The uninstall script is idempotent. You can safely re-run it:

```bash
sudo ./scripts/uninstall.sh
```

---

## Logs

Uninstall logs are preserved for forensic audit trail:

```bash
# View recent uninstall log
sudo cat /var/log/sidedoor/uninstall.*.log

# List all logs
sudo ls -la /var/log/sidedoor/
```

Logs are NOT removed during uninstall to maintain audit history.

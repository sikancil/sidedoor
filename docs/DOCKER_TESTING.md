# Docker Testing Guide

## Overview

This project uses systemd for certificate timer management. Testing in Docker has different considerations based on your host platform.

## Platform-Specific Notes

### Linux Host
Full systemd support is available. Use:
```bash
docker compose up -d
```

### macOS with Docker Desktop

**Known Limitation:** Docker Desktop on macOS has limited systemd support due to cgroup mounting in the underlying Linux VM.

The production `docker-compose.yml` (systemd-based) may **not work properly** on Docker Desktop for Mac.

#### Recommended Testing Approach for macOS:

1. **Use droplet testing** (Primary testing environment)
   ```bash
   curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | bash
   ```

2. **Use development mode** (SKIP_SYSTEMD=true)
   ```bash
   docker compose -f docker-compose.dev.yml up -d
   ```
   This skips systemd timer creation but allows testing other features.

3. **Use Colima or Lima** for full systemd support:
   ```bash
   # Install Colima
   brew install colima

   # Start with systemd support
   colima start --cpu 4 --memory 8 --mount-type virtiofs

   # Then run docker compose
   docker compose up -d
   ```

### Windows with Docker Desktop

Similar limitations as macOS. Use WSL2 with Colima or test directly on a Linux droplet/VM.

## Testing Scenarios

### Production Docker (with systemd)
```bash
docker compose up -d
```
- Requires: Linux host or Colima/Lima
- Features: Full systemd timer support
- Status: ✅ Tested on Ubuntu 24.04 droplet
- Status: ⚠️ Limited on Docker Desktop (Mac/Windows)

### Development Docker (without systemd)
```bash
docker compose -f docker-compose.dev.yml up -d
```
- Requires: Any platform
- Features: Certificate creation, SSH/SFTP (no auto-cleanup timers)
- Status: ✅ Works on Docker Desktop (Mac/Windows)

## Security Implementation

The systemd helper script (`scripts/systemd-helper.sh`) provides secure privileged operations:

1. **Root validation**: Script validates it's running as root
2. **Username validation**: Regex check for `n0x[a-f0-9]{6}` format
3. **Command whitelist**: Only `create-timer` and `delete-timer` allowed
4. **Sudoers restriction**: Specific commands only, no shell access

## Verification Checklist

- [ ] Helper script installed: `/usr/local/sbin/sidedoor-systemd-helper`
- [ ] Sudoers entry exists: `cat /etc/sudoers.d/sidedoor`
- [ ] Certificate creation creates systemd timer
- [ ] Timer scheduled to fire at expiration
- [ ] Timer cleanup works after expiration

## Current Testing Status

| Environment | Systemd | Status |
|-------------|---------|--------|
| Ubuntu 24.04 Droplet | ✅ Full | ✅ Tested & Working |
| Docker Desktop (Mac) | ⚠️ Limited | Use dev mode |
| Colima/Lima (Mac) | ✅ Full | Untested |
| Linux Host | ✅ Full | Untested |

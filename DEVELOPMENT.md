# VM Access API - Development & Testing Guide

This guide covers how to develop and test the VM Access API on macOS.

---

## Overview

The VM Access API requires Linux-specific features:
- `useradd`/`userdel` for system user management
- `sshd` with chroot configuration
- `systemctl` for service management
- `sudo` for privileged operations

Since macOS doesn't have these, we need to simulate a Linux environment.

---

## Testing Options

### Option 1: Docker (Quick Development Testing)

**Best for:** Quick API testing, CI/CD, development iterations

**Pros:** Fast, easy to set up, works great for API logic testing
**Cons:** Limited SSH functionality (no systemd), requires privileged mode

#### Quick Start

```bash
# Build and run
./scripts/docker-test.sh build
./scripts/docker-test.sh run

# In another terminal, test the API
./scripts/docker-test.sh test

# Or use docker-compose
./scripts/docker-test.sh compose
```

#### Manual Docker Commands

```bash
# Build image
docker build -t vm-access-api .

# Run container
docker run --rm -it \
  --privileged \
  -p 3000:3000 \
  -p 2222:22 \
  -v "$(pwd)/data:/app/data" \
  vm-access-api

# Access container shell
docker exec -it <container-id> bash

# Test SFTP from host
sftp -P 2222 -i private_key cert_user_xxx@localhost
```

---

### Option 2: Multipass VM (Full Integration Testing) ⭐ Recommended

**Best for:** Full integration testing, realistic environment, SSH/SFTP testing

**Pros:** Full Ubuntu Linux with systemd, complete SSH server, realistic testing
**Cons:** Slower startup, uses more resources

#### Prerequisites

```bash
# Install Multipass on macOS
brew install --cask multipass
```

#### Quick Start

```bash
# One-time setup
./scripts/setup-multipass.sh

# SSH into the VM
multipass shell vm-access-dev

# Inside the VM, run as tempo user
sudo -u tempo bash -lc "cd /home/ubuntu/vm-access && bun run src/index.ts"
```

#### Multipass Commands

```bash
# VM Management
multipass list                           # List all VMs
multipass shell vm-access-dev            # SSH into VM
multipass start vm-access-dev            # Start VM
multipass stop vm-access-dev             # Stop VM
multipass delete --purge vm-access-dev   # Delete VM

# Execute commands from macOS
multipass exec vm-access-dev -- ls -la
multipass exec vm-access-dev -- bash -lc "cd /home/ubuntu/vm-access && bun run src/index.ts"

# Forward port to access API from macOS
multipass exec vm-access-dev -- bash -lc "cd /home/ubuntu/vm-access && sudo -u tempo bun run src/index.ts" &

# Get VM IP address
multipass info vm-access-dev --format json | jq -r '.info.vm-access-dev.ipv4[0]'
```

---

### Option 3: Lima (Alternative to Multipass)

**Best for:** Users who prefer Lima over Multipass

```bash
# Install Lima
brew install lima

# Create VM
limactl start --name=vm-access-dev --tty=false

# Copy and run project
limactl shell vm-access-dev
cd /mnt/host
sudo -u tempo bun run src/index.ts
```

---

## Development Workflow

### Option A: Using Multipass (Recommended for Full Testing)

```bash
# Terminal 1: Start the VM and API
multipass start vm-access-dev
multipass shell vm-access-dev
# Inside VM:
sudo -u tempo bash -lc "cd /home/ubuntu/vm-access && bun run src/index.ts"

# Terminal 2: Test API from macOS
curl http://$(multipass info vm-access-dev --format json | jq -r '.info.vm-access-dev.ipv4[0]'):3000/health

# Terminal 3: Hot-reload development (use mounted directory)
# Edit files on macOS, they're automatically synced to VM
# Then restart API in Terminal 1
```

### Option B: Using Docker (Quick Iterations)

```bash
# Terminal 1: Run with docker-compose
docker-compose up

# Terminal 2: Test API
curl http://localhost:3000/health

# Make code changes
docker-compose up --build  # Rebuild with changes
```

---

## Testing Checklist

### 1. Health Check
```bash
curl http://localhost:3000/health
```
Expected: All checks pass (database, ssh, workers)

### 2. Create Certificate
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

### 3. List Certificates
```bash
curl http://localhost:3000/api/certificates \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### 4. Test SFTP Connection
```bash
# Download private key first
CERT_ID="<from-create-response>"
curl http://localhost:3000/api/download/$CERT_ID/key \
  -H "Authorization: Bearer YOUR_TOKEN" -o private_key
chmod 600 private_key

# Connect via SFTP
sftp -i private_key cert_user_$CERT_ID@localhost
# Or with Docker port mapping
sftp -P 2222 -i private_key cert_user_$CERT_ID@localhost
```

### 5. Verify System Resources
```bash
# In Multipass VM:
getent passwd cert_user_<id>      # Check user exists
ls -la /home/sftp/<username>/     # Check chroot directory
sudo cat /etc/ssh/sshd_config.d/vm-access.conf  # Check SSH config
sudo systemctl status sshd        # Check SSH service
```

---

## Troubleshooting

### Docker Issues

**Port already in use:**
```bash
lsof -ti:3000 | xargs kill -9
```

**Permission denied on useradd:**
```bash
docker run --privileged ...  # Ensure privileged mode
```

### Multipass Issues

**VM not starting:**
```bash
multipass stop vm-access-dev
multipass start vm-access-dev
```

**Cannot mount directory:**
```bash
multipass unmount vm-access-dev:/home/ubuntu/vm-access
multipass mount "$PWD" vm-access-dev:/home/ubuntu/vm-access
```

**SSH connection refused:**
```bash
multipass shell vm-access-dev
sudo systemctl restart sshd
```

---

## Recommended Setup

For the best development experience:

1. **Use Multipass** for your main development environment
   - Full Linux feature support
   - Realistic testing environment
   - Easy SSH/SFTP testing

2. **Use Docker** for quick smoke tests
   - Fast iteration
   - CI/CD integration

3. **Workflow:**
   ```bash
   # Start VM (once)
   ./scripts/setup-multipass.sh

   # Daily workflow
   multipass start vm-access-dev
   multipass shell vm-access-dev
   # Inside VM, run as tempo user
   sudo -u tempo bash -lc "cd /home/ubuntu/vm-access && bun run src/index.ts"
   ```

---

## Quick Reference

| Task | Docker | Multipass |
|------|--------|-----------|
| Setup | `docker build` | `./scripts/setup-multipass.sh` |
| Start | `docker-compose up` | `multipass start vm-access-dev` |
| Stop | `docker-compose down` | `multipass stop vm-access-dev` |
| Shell | `docker exec -it <id> bash` | `multipass shell vm-access-dev` |
| SSH Test | `localhost:2222` | `$(multipass info ...):22` |
| API Test | `localhost:3000` | `$(multipass info ...):3000` |
| Full SSH | ⚠️ Limited | ✅ Full support |
| Systemd | ❌ No | ✅ Yes |
| Performance | ⚡ Fast | 🐢 Slower |

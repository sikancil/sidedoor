# Sidedoor - Development & Testing Guide

This guide covers developing and testing the Sidedoor SSH/SFTP Certificate Management system.

---

## Overview

Sidedoor requires Linux-specific features:
- `useradd`/`userdel` for system user management
- `sshd` with chroot configuration
- `systemctl` for service and timer management
- `sudo` for privileged operations

Since macOS doesn't have these, development requires a Linux environment.

---

## Quick Start

### Option 1: DigitalOcean Droplet (Production Testing)

**Best for**: Full integration testing, realistic environment

```bash
# Create Ubuntu 24.04 droplet
# Then run one-command install
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo bash
```

### Option 2: Docker (Quick Development)

**Best for**: Quick API testing, CI/CD, development iterations

**Limitations**: Limited SSH functionality, no systemd timers on Docker Desktop (Mac/Windows)

```bash
# Development mode (without systemd)
docker compose -f docker-compose.dev.yml up -d

# Access API
curl http://localhost:3000/health
```

### Option 3: Colima/Lima (Full Docker Systemd)

**Best for**: Docker with full systemd support on macOS

```bash
# Install Colima
brew install colima

# Start with systemd support
colima start --cpu 4 --memory 8 --mount-type virtiofs

# Then run production docker compose
docker compose up -d
```

---

## Development Workflow

### Local Development (macOS)

1. **Edit code** on macOS in `/Users/dimasarif/DATA/WORK/Pegasus/vm-access/`
2. **Test API** locally with Docker or on droplet
3. **Verify SSH** on droplet only
4. **Check logs** in `/var/log/sidedoor/`

### Remote Development (Droplet)

1. **SSH to droplet**:
   ```bash
   ssh ubuntu@your-droplet-ip
   ```

2. **Clone repository**:
   ```bash
   git clone https://github.com/sikancil/sidedoor.git /home/ubuntu/sidedoor
   cd /home/ubuntu/sidedoor
   ```

3. **Run setup**:
   ```bash
   sudo ./scripts/setup.sh --user ubuntu --force
   ```

4. **Start service**:
   ```bash
   sudo systemctl start sidedoor
   ```

5. **View logs**:
   ```bash
   sudo journalctl -u sidedoor -f
   sudo tail -f /var/log/sidedoor/sidedoor.*.log
   ```

---

## Project Structure

```
vm-access/
├── install.sh                 # Bootstrap curl installer
├── DEVELOPMENT.md             # This file
├── README.md                  # Main documentation
├── docs/                      # Additional documentation
│   ├── INSTALLATION.md        # Installation guide
│   ├── UNINSTALLATION.md      # Uninstall guide
│   ├── LOGGING.md             # Logging system docs
│   ├── SSH_MIGRATION.md       # SSH migration docs
│   └── DOCKER_TESTING.md      # Docker testing guide
├── scripts/
│   ├── setup.sh               # Main setup script
│   ├── uninstall.sh           # Uninstall script
│   ├── systemd-helper.sh      # Systemd privileged operations
│   ├── docker-test.sh         # Docker testing helper
│   ├── lib/
│   │   ├── common.sh          # Common utilities
│   │   ├── logging.sh         # Unified logging library
│   │   ├── state.sh           # State file management
│   │   └── ssh-migrate.sh     # SSH migration library
│   ├── src/
│   │   └── setup/             # Setup step libraries
│   ├── systemd/
│   │   ├── sidedoor.service   # Main service unit
│   │   ├── sidedoor-helper@.service  # Helper service
│   │   └── sidedoor.conf      # Systemd drop-in
│   └── ssh/
│       └── sidedoor.conf      # SSH config
├── src/                       # TypeScript application
│   ├── index.ts               # Application entry point
│   ├── config/
│   │   ├── index.ts           # Configuration loader
│   │   ├── constants.ts       # Constants
│   │   └── schema.ts          # Zod validation schemas
│   ├── db/
│   │   ├── schema.sql         # Database schema
│   │   └── index.ts           # Database client
│   ├── routes/
│   │   ├── admin.routes.ts    # Admin endpoints
│   │   ├── certificates.routes.ts  # Certificate CRUD
│   │   ├── config.routes.ts   # Config management
│   │   ├── download.routes.ts # Key download
│   │   └── health.routes.ts   # Health check
│   └── utils/
│       ├── crypto.ts          # Cryptographic utilities
│       ├── logger.ts          # Application logger
│       ├── systemd.ts         # Systemd operations
│       └── sftp.ts            # SFTP utilities
├── systemd/
│   └── sudoers               # Sudoers configuration
├── docker-compose.yml         # Production Docker
├── docker-compose.dev.yml     # Development Docker
├── Dockerfile                 # Production image
├── Dockerfile.dev             # Development image
├── bun.lockb                  # Bun lockfile
└── package.json               # Dependencies
```

---

## Tech Stack

- **Runtime**: Bun (JavaScript runtime)
- **Framework**: Elysia (web framework)
- **Language**: TypeScript
- **Database**: SQLite (bun:sqlite)
- **Validation**: Zod
- **System**: Linux systemd (Ubuntu 22.04+ / 24.04+)

---

## Configuration

### Configuration File

```
/etc/sidedoor/config.json
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | API port | `3000` |
| `HOST` | API host | `0.0.0.0` |
| `DATABASE_PATH` | SQLite database path | `/var/lib/sidedoor/certificates.db` |
| `LOG_LEVEL` | Logging level | `info` |

### Configuration Schema

```json
{
  "port": 3000,
  "host": "0.0.0.0",
  "databasePath": "/var/lib/sidedoor/certificates.db",
  "authenticatorToken": "your-token-here",
  "cronSecret": "your-cron-secret",
  "sftp": {
    "baseDirectory": "/home/sftp",
    "bindMounts": ["/srv/data", "/var/www"]
  },
  "ufw": {
    "enabled": true,
    "port": 3000
  },
  "defaults": {
    "ttl": 3600,
    "permissions": ["sftp", "read-only"]
  }
}
```

---

## API Endpoints

### Health

```
GET /health
```

### Certificate Management

```
POST   /api/certificates          # Create certificate
GET    /api/certificates          # List all certificates
GET    /api/certificates/:id      # Get certificate details
DELETE /api/certificates/:id      # Delete certificate
```

### Admin

```
GET    /admin/config              # Get configuration
PATCH  /admin/config              # Update configuration
POST   /admin/config/reload       # Reload configuration
GET    /admin/config/validate-ufw # Validate UFW rules
POST   /admin/config/sync-ufw     # Sync UFW rules
```

### Download

```
GET    /api/download/:id/key      # Download private key
GET    /api/download/:id/info     # Download connection info
```

---

## Testing

### Health Check

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

### Create Certificate

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

### List Certificates

```bash
curl http://localhost:3000/api/certificates \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### Test SFTP Connection

```bash
# Download private key
CERT_ID="<from-create-response>"
curl http://localhost:3000/api/download/$CERT_ID/key \
  -H "Authorization: Bearer YOUR_TOKEN" -o private_key
chmod 600 private_key

# Connect via SFTP
sftp -i private_key n0x1a2b3c@localhost
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
# Service logs (journald)
sudo journalctl -u sidedoor -f

# Application logs (file-based)
sudo tail -f /var/log/sidedoor/sidedoor.*.log

# All logs
sudo ls -la /var/log/sidedoor/
```

### View Systemd Timers

```bash
# List all timers
sudo systemctl list-timers 'sidedoor-*'

# View timer details
sudo systemctl status sidedoor-n0x1a2b3c.timer

# View timer logs
sudo journalctl -u sidedoor-n0x1a2b3c.timer
```

---

## Development Scripts

### Run Application (Development)

```bash
# From project root
bun run src/index.ts
```

### Run Tests

```bash
# Run all tests
bun test

# Run specific test file
bun test src/routes/certificates.test.ts
```

### Build for Production

```bash
# Build TypeScript
bun build src/index.ts --outdir dist
```

---

## Troubleshooting

### Service Won't Start

```bash
# Check service status
sudo systemctl status sidedoor

# Check service logs
sudo journalctl -u sidedoor -n 50

# Check application logs
sudo tail -f /var/log/sidedoor/sidedoor.*.log

# Verify configuration
sudo cat /etc/sidedoor/config.json

# Check database
sudo ls -la /var/lib/sidedoor/
```

### Port Already in Use

```bash
# Check what's using port 3000
sudo lsof -i :3000

# Change port in config
sudo nano /etc/sidedoor/config.json
sudo systemctl restart sidedoor
```

### Docker Issues

```bash
# Port already in use
lsof -ti:3000 | xargs kill -9

# Permission denied on useradd
docker run --privileged ...

# Build fails
docker-compose build --no-cache
```

### SSH Access Issues

```bash
# Check SSH configuration
sudo sshd -t

# Check SSH service
sudo systemctl status ssh

# Verify chroot setup
sudo ls -la /home/sftp/

# Test SSH manually
ssh -v n0x1a2b3c@localhost
```

---

## Reinstallation

After code changes, you can reinstall:

```bash
# From cloned repository
cd /path/to/sidedoor
sudo ./scripts/setup.sh --user ubuntu --force
```

Or use the bootstrap installer:

```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo bash
```

---

## Code Quality

### Linting

```bash
# Run linter
bun run lint
```

### Type Checking

```bash
# Type check TypeScript
bun run typecheck
```

### Formatting

```bash
# Format code
bun run format
```

---

## Documentation

- **Installation**: See [docs/INSTALLATION.md](docs/INSTALLATION.md)
- **Uninstallation**: See [docs/UNINSTALLATION.md](docs/UNINSTALLATION.md)
- **Logging**: See [docs/LOGGING.md](docs/LOGGING.md)
- **SSH Migration**: See [docs/SSH_MIGRATION.md](docs/SSH_MIGRATION.md)
- **Docker Testing**: See [docs/DOCKER_TESTING.md](docs/DOCKER_TESTING.md)
- **Main README**: See [README.md](README.md)

---

## Quick Reference

| Task | Droplet | Docker (Dev) |
|------|---------|--------------|
| Install | `curl ... \| sudo bash` | `docker compose -f docker-compose.dev.yml up` |
| Start | `sudo systemctl start sidedoor` | `docker compose up` |
| Stop | `sudo systemctl stop sidedoor` | `docker compose down` |
| Logs | `sudo journalctl -u sidedoor -f` | `docker compose logs -f` |
| Status | `sudo systemctl status sidedoor` | `docker compose ps` |
| Config | `/etc/sidedoor/config.json` | `config.json` (mounted) |
| Database | `/var/lib/sidedoor/certificates.db` | `data/certificates.db` |
| Full SSH | Yes | Limited |
| Systemd | Yes | No (dev mode) |

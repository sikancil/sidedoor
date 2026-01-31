# Sidedoor SSH/SFTP Certificate Management Service

A temporary SSH certificate management system using **Bun + Elysia + TypeScript + Zod** with systemd-based automatic cleanup.

## Overview

Sidedoor provides time-limited SSH certificates with chrooted SFTP access, usage tracking, and geolocation data. Each certificate gets a **unique dynamic Linux user** (format: `n0x######`) with individual chroot environment and per-certificate systemd timer for automatic cleanup.

## Quick Start

### One-Command Installation (Ubuntu)

```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo bash
```

This installs:
- Bun runtime
- Dependencies (git, curl, jq, unzip, sqlite3)
- Systemd service
- Configuration with auto-generated secure tokens
- SSH migration from root to service user

### Create Your First Certificate

```bash
curl -X POST http://localhost:3000/api/certificates \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Response:**
```json
{
  "success": true,
  "data": {
    "id": "n0x1a2b3c",
    "username": "n0x1a2b3c",
    "directoryPath": "/srv",
    "privateKey": "-----BEGIN OPENSSH PRIVATE KEY-----..."
  }
}
```

## Architecture

### Dynamic User Model (v2.0)

Sidedoor creates a unique Linux user for each certificate:
- **Dynamic User**: Generated as `n0x######` (9 characters total, e.g., `n0x1a2b3c`)
  - Format: `n0x` + 6 hex characters
  - `n` letter prefix (required by Linux - usernames cannot start with digits)
  - `0x` literal hex identifier for visual clarity
  - 6 hex digits (a-f, 0-9) = 16,777,216 possible combinations
- **Authentication**: Individual SSH keys in `/home/sftp/n0x######/.ssh/authorized_keys`
- **Chroot**: Individual chroot at `/home/sftp/n0x######` per certificate
- **Directory Access**: Bind mounts (e.g., `/srv` → `/home/sftp/n0x1a2b3c/srv`)
- **Certificate Expiration**: Per-certificate systemd timer fires once at expiration
- **Cleanup**: Systemd timer triggers admin endpoint → deletes user, chroot, timer

### Key Benefits

| Feature | Static User (v1) | Dynamic User (v2) |
|---------|-----------------|-------------------|
| User per certificate | No (shared `tempo`) | Yes (`n0x######`) |
| Cleanup complexity | O(n) polling | O(1) per certificate |
| Expiration precision | ±60 seconds | ±1 millisecond |
| Isolation | Poor (shared chroot) | Excellent (per-user chroot) |

### Technology Stack

| Component | Choice |
|-----------|--------|
| Runtime | Bun (latest) |
| Language | TypeScript |
| Web Framework | Elysia (Bun-first, type-safe) |
| Validation | Zod |
| Database | SQLite (`bun:sqlite`) |
| Process Manager | systemd (per-certificate timers) |
| ID Generation | nanoid (6 hex chars) |
| Container | Docker with systemd support |

## Project Structure

```
vm-access/
├── src/                             # Application source code
│   ├── index.ts                     # Entry point with recovery service
│   ├── config/
│   │   ├── index.ts                 # Config loader with auto-creation
│   │   ├── database.ts              # SQLite setup with migration
│   │   └── constants.ts             # Defaults, generateUsername()
│   ├── models/
│   │   ├── Certificate.model.ts     # SQLite operations with cleanup logs
│   │   └── schemas/
│   │       └── certificate.schema.ts # Zod schemas
│   ├── routes/
│   │   ├── certificates.routes.ts   # CRUD endpoints
│   │   ├── download.routes.ts       # File download/render
│   │   ├── health.routes.ts         # Health check (ready/live)
│   │   ├── admin.routes.ts          # Admin cleanup endpoints
│   │   └── config.routes.ts         # Config management endpoints
│   ├── services/
│   │   ├── certificate.service.ts   # Business logic (dynamic users)
│   │   ├── ssh.service.ts           # OS integration (bind mounts, chroot)
│   │   ├── systemd.service.ts       # Timer management
│   │   ├── recovery.service.ts      # Startup recovery & orphan cleanup
│   │   └── geolocation.service.ts   # ip-api.com integration
│   ├── utils/
│   │   ├── crypto.utils.ts          # SSH key generation
│   │   └── markdown.utils.ts        # README generation
│   └── middleware/
│       ├── auth.middleware.ts       # Bearer token validation
│       ├── admin-auth.middleware.ts # Admin auth (CRON_SECRET)
│       └── error.middleware.ts
├── scripts/                         # Installation & management scripts
│   ├── setup.sh                     # Smart idempotent setup
│   ├── uninstall.sh                 # Complete uninstall with --dry-run
│   ├── systemd-helper.sh            # Secure systemd operations wrapper
│   └── lib/                         # Script libraries
│       ├── logging.sh                # Unified logging with credential masking
│       ├── state.sh                  # State management with metadata
│       ├── ssh-migrate.sh            # SSH migration from root
│       ├── validate.sh               # Input validation
│       ├── sudo-wrapper.sh          # Safe sudo execution
│       └── version.sh                # Version tracking
├── systemd/
│   └── sidedoor.service              # Production systemd unit file
├── install.sh                        # Bootstrap curl installer
├── data/
│   ├── certificates.db               # SQLite database
│   └── certificates/                 # Generated keys
├── config.json.example               # Example configuration
├── docker-compose.yml                # Production Docker (systemd)
├── docker-compose.dev.yml           # Development Docker (systemd)
├── Dockerfile                        # Production container
├── Dockerfile.dev                   # Development container
└── ecosystem.config.json             # PM2 configuration
```

## Installation

### Option 1: One-Command Installation (Recommended)

**For Ubuntu 24.04:**
```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo bash
```

**Custom branch:**
```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | SIDEDOOR_BRANCH=main sudo bash
```

**Custom service user:**
```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | SIDEDOOR_USER=sidedoor sudo bash
```

**With SSH private key migration:**
```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | MIGRATE_SSH_PRIVATE_KEYS=true sudo bash
```

### Option 2: Manual Installation

See [docs/INSTALLATION.md](docs/INSTALLATION.md) for detailed manual installation instructions.

## Configuration

Sidedoor reads configuration from `/etc/sidedoor/config.json` (production) or `./config.json` (development).

### Configuration Options

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | number | 3000 | API server port |
| `sshPort` | number | 22 | SSH port for UFW configuration |
| `authenticatorToken` | string | (auto-generated) | Bearer token for API authentication |
| `cronSecret` | string | (from env/file) | Secret for admin cleanup endpoints |
| `chrootBasePath` | string | `/home/sftp` | Base chroot directory |
| `dbPath` | string | `/var/lib/sidedoor/certificates.db` | SQLite database path |
| `defaultDirectories` | string[] | `["/srv", "/var/www", "/data/uploads"]` | Default accessible directories |
| `defaultPermissions` | string[] | `["read-write-modify"]` | Default permissions |
| `defaultTtl` | number | 600 | Default TTL in seconds (10 minutes) |
| `user` | object | `{name: "sidedoor", group: "www-data"}` | Service user configuration |

### Example Configuration

```json
{
  "port": 3000,
  "sshPort": 22,
  "authenticatorToken": "your-secure-token-min-32-chars",
  "cronSecret": "your-cron-secret-min-32-chars",
  "chrootBasePath": "/home/sftp",
  "dbPath": "/var/lib/sidedoor/certificates.db",
  "configPath": "/etc/sidedoor/config.json",
  "defaultDirectories": ["/srv", "/var/www", "/data/uploads"],
  "defaultPermissions": ["read-write-modify"],
  "defaultTtl": 600,
  "user": {
    "name": "sidedoor",
    "group": "www-data"
  }
}
```

## API Endpoints

### Certificates

| Method | Endpoint | Auth | Description |
|--------|----------|-----|-------------|
| POST | `/api/certificates` | Bearer | Generate certificate (creates dynamic user) |
| GET | `/api/certificates` | Bearer | List all with geolocation |
| GET | `/api/certificates/:id` | Bearer | Get single with access history |
| PATCH | `/api/certificates/:id` | Bearer | Update TTL, permissions, or revoke |
| DELETE | `/api/certificates/:id` | Bearer | Delete and cleanup user/chroot |

### Downloads

| Method | Endpoint | Auth | Description |
|--------|----------|-----|-------------|
| GET | `/api/download/:id/key` | Bearer | Download private key file |
| GET | `/api/download/:id/readme` | Bearer | Download README markdown |
| GET | `/api/download/:id/content` | Bearer | Get README as JSON {markdown, html} |

### Admin (requires `CRON_SECRET`)

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/admin/cleanup/:username` | Manual cleanup (triggered by systemd timer) |
| GET | `/admin/certificates/active` | List active certificates with timers |
| GET | `/admin/certificates/:username/logs` | Get certificate cleanup logs |
| GET | `/admin/timers` | List all systemd timers |
| GET | `/admin/health` | Admin health check with orphan detection |

### Config Management (Admin)

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/admin/config` | Get current configuration (secrets masked) |
| PATCH | `/admin/config` | Update configuration (triggers reload/restart) |
| POST | `/admin/config/reload` | Reload configuration |
| GET | `/admin/config/validate-ufw` | Validate UFW matches config |
| POST | `/admin/config/sync-ufw` | Sync UFW with config |

### Health

| Method | Endpoint | Auth | Description |
|--------|----------|-----|-------------|
| GET | `/health` | None | Health check (db, ssh, timers) |
| GET | `/health/ready` | None | Readiness check |
| GET | `/health/live` | None | Liveness check |

## Usage Examples

### Create Certificate (with defaults)

```bash
curl -X POST http://localhost:3000/api/certificates \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
```

### Create Certificate (with custom values)

```bash
curl -X POST http://localhost:3000/api/certificates \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "directoryPath": "/srv/uploads",
    "permissions": ["sftp", "read-write"],
    "ttl": 3600
  }'
```

### Test SFTP Connection

```bash
# Save private key to file
echo "PRIVATE_KEY_HERE" > /tmp/test_key
chmod 600 /tmp/test_key

# Connect via SFTP (username is the certificate ID)
sftp -i /tmp/test_key n0x1a2b3c@localhost
```

### Manual Cleanup (admin)

```bash
curl -X POST http://localhost:3000/admin/cleanup/n0x1a2b3c \
  -H "Authorization: Bearer CRON_SECRET"
```

## Development

### Install Dependencies

```bash
bun install
```

### Run Development Server

```bash
bun run dev
# or
bun start
```

### Run Tests

```bash
bun test
```

### Type Check

```bash
bun run typecheck
```

### Lint

```bash
bun run lint
```

### Format

```bash
bun run format
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for complete development guide.

## Docker

### Build and Run (Production)

```bash
# Build image
docker build -t sidedoor-api .

# Run with docker-compose
docker-compose up -d
```

### Build and Run (Development)

```bash
# Build dev image
docker-compose -f docker-compose.dev.yml build

# Run dev container
docker-compose -f docker-compose.dev.yml up -d
```

### View Logs

```bash
# Application logs
docker-compose logs -f --tail=100 sidedoor-api

# Systemd logs (requires shell access)
docker-compose exec sidedoor-api tail -f /var/log/sidedoor/sidedoor.log
```

### List Active Timers

```bash
docker-compose exec sidedoor-api systemctl list-timers sidedoor-*
```

See [docs/DOCKER_TESTING.md](docs/DOCKER_TESTING.md) for Docker testing guide.

## Uninstallation

### Quick Uninstall

```bash
# Preview what would be removed
sudo bash /opt/sidedoor/scripts/uninstall.sh --dry-run

# Actual uninstall
echo 'y' | sudo bash /opt/sidedoor/scripts/uninstall.sh
```

### What Gets Removed

- Sidedoor service and systemd timers
- Dynamic `n0x*` certificate users
- SQLite certificate database
- Configuration files
- SSH config at `/etc/ssh/sshd_config.d/sidedoor.conf`
- Application files at `/opt/sidedoor/`
- State files
- Cloned repository (remote only)
- Chroot bind mounts (NOT source directories)

### What Gets Preserved

- Service users (`ubuntu`, `SERVICE_USER`)
- All SSH keys in `~/.ssh/*`
- Local codebase
- Source directories behind chroot bind mounts
- **Install logs** (in `/var/log/sidedoor/` for forensic audit)

See [docs/UNINSTALLATION.md](docs/UNINSTALLATION.md) for complete uninstall guide.

## Logging

Sidedoor includes a comprehensive logging system:

- **Location**: `/var/log/sidedoor/`
- **Format**: `{script_name}.{iso8601timestamp}.log`
- **Log Levels**: INFO, WARN, ERROR, DEBUG
- **Features**:
  - ISO 88601 timestamps with millisecond precision
  - System information in log headers
  - **Credential masking** (first 2 + last 2 chars: `si******0r`)
  - Forensic audit trail (logs preserved during uninstall)

Example log entries:
```
2026-01-31T16:29:16.038Z [INFO] [setup:920] Setup started with SERVICE_USER=ubuntu, API_PORT=3000
2026-01-31T16:30:39.444Z [INFO] [setup:883] Generated authenticatorToken: Oj************************************************************6A (64 chars)
2026-01-31T16:30:39.506Z [INFO] [setup:883] Generated cronSecret: HX************************************************************5x (64 chars)
```

See [docs/LOGGING.md](docs/LOGGING.md) for complete logging documentation.

## SSH Migration

During installation, SSH keys are automatically migrated from `root` to the service user (`ubuntu` or custom):

**What gets migrated:**
- `authorized_keys` (merged, deduplicated)
- `known_hosts` (merged, deduplicated)
- SSH `config` (preserves host entries)
- Public keys (by default)
- Private keys (only with `--migrate-ssh-private-keys` flag)

**State tracking:** `/etc/sidedoor/.ssh-migration-state`

See [docs/SSH_MIGRATION.md](docs/SSH_MIGRATION.md) for complete SSH migration documentation.

## Production Deployment

### Quick Production Install

```bash
curl -fsSL https://raw.githubusercontent.com/sikancil/sidedoor/wizard/install.sh | sudo bash
```

### Post-Installation

1. **Save your tokens securely:**
   ```bash
   sudo cat /etc/sidedoor/config.json | grep -E "(authenticatorToken|cronSecret)"
   ```

2. **Verify service status:**
   ```bash
   systemctl status sidedoor
   ```

3. **Check logs:**
   ```bash
   journalctl -u sidedoor -f
   tail -f /var/log/sidedoor/sidedoor.log
   ```

4. **API health check:**
   ```bash
   curl http://localhost:3000/health
   ```

### Manual Production Setup

See [docs/INSTALLATION.md](docs/INSTALLATION.md) for detailed manual production setup.

## Security

### Credential Masking in Logs

The logging system automatically masks sensitive data:
- `authenticatorToken`: `***MASKED***`
- `cronSecret`: `***MASKED***`
- Bearer tokens: `Bearer ***MASKED***`
- SSH keys: `ssh-rsa ***KEY*** ***REDACTED***`
- API keys: `api_key: ***MASKED***`
- Passwords: `password: ***MASKED***`

### Systemd Helper Security Model

The systemd helper (`/usr/local/sbin/sidedoor-systemd-helper`) provides secure privileged operations:

1. **Root validation**: Script validates it's running as root
2. **Username validation**: Regex check for `n0x[a-f0-9]{6}` format
3. **Command whitelist**: Only `create-timer` and `delete-timer` allowed
4. **Sudoers restriction**: Specific commands only, no shell access

### SSH Security

- **Chroot jail**: Each session confined to `/home/sftp/n0x######`
- **ForceCommand**: Internal SFTP only (no shell access)
- **No port forwarding**: `AllowTcpForwarding no`, `PermitTunnel no`
- **Key-only auth**: `PasswordAuthentication no`
- **Per-certificate isolation**: Users cannot see other certificates

## Troubleshooting

### Common Issues

**Service fails to start:**
```bash
# Check logs
journalctl -u sidedoor -n 50

# Check configuration
sudo cat /etc/sidedoor/config.json

# Check if bun is installed
which bun
```

**Cannot create certificates:**
```bash
# Check service status
curl http://localhost:3000/health

# Check database permissions
ls -la /var/lib/sidedoor/

# Check logs
tail -f /var/log/sidedoor/sidedoor.log
```

**SSH connection refused:**
```bash
# Check if SSH is running
sudo systemctl status sshd

# Reload SSH after config changes
sudo systemctl reload sshd

# Check SSH config
sudo sshd -t
```

**Orphaned certificates:**
```bash
# Check for orphans
curl -H "Authorization: Bearer CRON_SECRET" http://localhost:3000/admin/health
```

### Getting Help

For issues or questions:
- Check logs in `/var/log/sidedoor/`
- Review [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- Check GitHub Issues: https://github.com/sikancil/sidedoor/issues

## License

MIT

# Sidedoor API

SSH/SFTP Certificate Management Service - A temporary SSH certificate management system using **Bun + Elysia + TypeScript + Zod** with systemd-based cleanup.

## Overview

Sidedoor provides time-limited SSH certificates with chrooted SFTP access, usage tracking, and geolocation data. Each certificate gets a **unique dynamic Linux user** (format: `n0x######`) with individual chroot environment and per-certificate systemd timer for automatic cleanup.

## Architecture

### Dynamic User Model (v2.0)

Sidedoor creates a unique Linux user for each certificate:
- **Dynamic User**: Generated as `n0x######` (9 characters total, e.g., `n0x1a2b3c`, `n0x9f8e7d`)
  - Format: `n0x` + 6 hex characters
  - `n` letter prefix (required by Linux - usernames cannot start with digits)
  - `0x` literal hex identifier for visual clarity
  - 6 hex digits (a-f, 0-9) = 16,777,216 possible combinations
- **Authentication**: Individual SSH keys in `/home/n0x######/.ssh/authorized_keys`
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
| Database | SQLite (built into Bun) |
| Process Manager | systemd (per-certificate timers) |
| ID Generation | nanoid (6 hex chars) |
| Container | Docker with systemd support |

## Project Structure

```
vm-access/
├── src/
│   ├── index.ts                      # Entry point with recovery service
│   ├── config/
│   │   ├── index.ts                  # Config loader
│   │   ├── database.ts               # SQLite setup with migration
│   │   └── constants.ts              # Default values and generateUsername()
│   ├── models/
│   │   ├── Certificate.model.ts      # SQLite operations with cleanup logs
│   │   └── schemas/
│   │       └── certificate.schema.ts # Zod schemas
│   ├── routes/
│   │   ├── certificates.routes.ts    # CRUD endpoints
│   │   ├── download.routes.ts        # File download/render
│   │   ├── health.routes.ts          # Health check
│   │   └── admin.routes.ts           # Admin cleanup endpoints
│   ├── services/
│   │   ├── certificate.service.ts    # Business logic (dynamic users)
│   │   ├── ssh.service.ts            # OS integration (bind mounts, chroot)
│   │   ├── systemd.service.ts        # Timer management
│   │   ├── recovery.service.ts       # Startup recovery
│   │   └── geolocation.service.ts    # ip-api.com integration
│   ├── utils/
│   │   ├── crypto.utils.ts           # SSH key generation
│   │   └── markdown.utils.ts         # README generation
│   └── middleware/
│       ├── auth.middleware.ts        # Bearer token validation
│       ├── admin-auth.middleware.ts  # Admin auth (CRON_SECRET)
│       └── error.middleware.ts
├── data/
│   ├── certificates.db               # SQLite database
│   └── certificates/                 # Generated keys
├── config.json.example               # Example configuration
├── Dockerfile                        # Container with systemd
├── docker-compose.yml                # Local development
└── ecosystem.config.json             # PM2 configuration
```

## Configuration

Sidedoor reads configuration from `/etc/sidedoor/config.json` (production) or `./config.json` (development).

### Example Configuration

```json
{
  "port": 3000,
  "authenticatorToken": "your-secure-token-min-32-chars",
  "cronSecret": "your-cron-secret-min-32-chars",
  "chrootBasePath": "/home/sftp",
  "dbPath": "./data/certificates.db",
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

### Configuration Options

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | number | 3000 | API server port |
| `authenticatorToken` | string | (auto-generated) | Bearer token for API authentication |
| `cronSecret` | string | (from env) | Secret for admin cleanup endpoints |
| `chrootBasePath` | string | `/home/sftp` | Base chroot directory |
| `dbPath` | string | `./data/certificates.db` | SQLite database path |
| `defaultDirectories` | string[] | `["/srv", "/var/www", "/data/uploads"]` | Default accessible directories |
| `defaultPermissions` | string[] | `["read-write-modify"]` | Default permissions |
| `defaultTtl` | number | 600 | Default TTL in seconds (10 minutes) |

## API Endpoints

### Certificates

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/certificates` | Generate certificate (creates dynamic user) |
| GET | `/api/certificates` | List all with geolocation |
| GET | `/api/certificates/:id` | Get single with access history |
| PATCH | `/api/certificates/:id` | Update TTL, permissions, or revoke |
| DELETE | `/api/certificates/:id` | Delete and cleanup user/chroot |

### Downloads

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/download/:id/key` | Download private key file |
| GET | `/api/download/:id/readme` | Download README markdown |
| GET | `/api/download/:id/content` | Get README as JSON {markdown, html} |

### Admin (requires `CRON_SECRET`)

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/admin/cleanup/:username` | Manual cleanup (triggered by systemd timer) |
| GET | `/admin/certificates/active` | List active certificates with timers |
| GET | `/admin/certificates/:username/logs` | Get certificate cleanup logs |
| GET | `/admin/timers` | List all systemd timers |
| GET | `/admin/health` | Admin health check with orphan detection |

### Other

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Health check (db, ssh, timers) |

## Usage

### Create Certificate (with defaults)

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

### Create Certificate (with custom values)

```bash
curl -X POST http://localhost:3000/api/certificates \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "directoryPath": "/srv/uploads",
    "permissions": ["sftp", "read-write"],
    "ttl": 3600,
    "responseType": "cert"
  }'
```

### Test SFTP Connection

```bash
# Save private key to file
echo "PRIVATE_KEY_HERE" > /tmp/test_key
chmod 600 /tmp/test_key

# Connect via SFTP (username is the certificate ID)
sftp -P 2222 -i /tmp/test_key n0x1a2b3c@localhost
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
```

### Run with PM2

```bash
bun run pm2:start
```

### View Logs

```bash
bun run pm2:logs
```

## Docker

### Build

```bash
docker build -t sidedoor-api .
```

### Run with Docker Compose

```bash
docker-compose up -d
```

### View Logs

```bash
# Application logs
docker-compose exec sidedoor-api tail -f /var/log/sidedoor/sidedoor.log

# Systemd logs
docker-compose exec sidedoor-api journalctl -u sidedoor -f
```

### List Active Timers

```bash
docker-compose exec sidedoor-api systemctl list-timers sidedoor-*
```

## Production Deployment

1. **Generate secure secrets:**
   ```bash
   # Generate authenticator token
   openssl rand -base64 32

   # Generate cron secret
   openssl rand -base64 32
   ```

2. **Create production config:**
   ```bash
   sudo mkdir -p /etc/sidedoor
   sudo editor /etc/sidedoor/config.json
   ```

   ```json
   {
     "port": 3000,
     "authenticatorToken": "GENERATED_TOKEN_HERE",
     "cronSecret": "GENERATED_CRON_SECRET_HERE",
     "chrootBasePath": "/home/sftp",
     "dbPath": "/var/lib/sidedoor/certificates.db",
     "defaultDirectories": ["/srv", "/var/www", "/data/uploads"],
     "defaultPermissions": ["read-write-modify"],
     "defaultTtl": 600,
     "user": {
       "name": "sidedoor",
       "group": "www-data"
     }
   }
   ```

   ```bash
   sudo chmod 600 /etc/sidedoor/config.json
   ```

3. **Create directories:**
   ```bash
   sudo mkdir -p /var/lib/sidedoor /var/log/sidedoor /home/sftp
   sudo chown -R sidedoor:sidedoor /var/log/sidedoor
   ```

4. **Start with PM2:**
   ```bash
   bun run pm2:start
   bun run pm2:save
   ```

## Security Notes

- **Private keys**: Stored with 600 permissions, downloadable with certificate response
- **Chroot jail**: Each session confined to `/home/sftp/n0x######`
- **Dynamic users**: Isolated per certificate, cannot see other users
- **Bind mounts**: Source directories must have proper permissions
- **Sudo permissions**: Minimal, specific commands only in `/etc/sudoers.d/sidedoor`
- **API Authentication**: Bearer token required for API endpoints
- **Admin Authentication**: Separate `CRON_SECRET` for admin endpoints
- **Automatic cleanup**: Systemd timers ensure resources are cleaned up on expiration
- **SSH config**: `Match User n0x*` applies chroot to all dynamic users

## Breaking Changes (v1.x → v2.0)

| Change | v1.x (Static) | v2.0 (Dynamic) |
|--------|---------------|----------------|
| Username format | `tempo` (all certificates) | `n0x######` (unique per cert) |
| Chroot location | `/home/sftp/tempo` | `/home/sftp/n0x######` |
| Cleanup mechanism | TTL worker (polling) | Systemd timers (event-driven) |
| Directory access | ACLs on `/home/sftp/tempo` | Bind mounts to source |
| Certificate ID | Random hex | Username (`n0x######`) |
| SFTP login | `tempo@host` | `n0x######@host` |

## License

MIT

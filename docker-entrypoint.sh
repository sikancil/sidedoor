#!/bin/bash
set -e

# Generate host keys if they don't exist
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -A
fi

# Create default config file if it doesn't exist
if [ ! -f /etc/sidedoor/config.json ]; then
    echo "Creating default config at /etc/sidedoor/config.json"
    cat > /etc/sidedoor/config.json << 'EOF'
{
  "port": 3000,
  "authenticatorToken": "dev-token-change-in-production-min-32-chars",
  "chrootBasePath": "/home/sftp",
  "cronSecret": "change-me-in-production-use-secure-random-string",
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
EOF
fi

# Ensure directories exist with correct permissions
mkdir -p /home/sftp
chown root:root /home/sftp
chmod 755 /home/sftp

mkdir -p /var/log/sidedoor
chown sidedoor:sidedoor /var/log/sidedoor
chmod 755 /var/log/sidedoor

# Note: This entrypoint is only used for non-systemd containers
# For systemd containers, the main process is /sbin/init
# The sidedoor service is managed by systemd

echo "Sidedoor container initialized with systemd"
echo "Services will be started by systemd:"
echo "  - sshd.service (SSH server)"
echo "  - sidedoor.service (API server)"

# Start systemd (this will start all enabled services)
exec /sbin/init

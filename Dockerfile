FROM ubuntu:22.04

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Install systemd and dependencies
RUN apt-get update && apt-get install -y \
    systemd systemd-sysv \
    openssh-server \
    sudo \
    curl \
    sqlite3 \
    ca-certificates \
    unzip \
    acl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Bun using official installation script
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# Create log directory
RUN mkdir -p /var/log/sidedoor

# Create service user with sudo permissions for dynamic user management
RUN useradd -r -s /bin/bash sidedoor && \
    usermod -aG sudo sidedoor && \
    usermod -aG www-data sidedoor && \
    echo "sidedoor ALL=(ALL) NOPASSWD: /usr/sbin/useradd, /usr/sbin/userdel, /usr/sbin/usermod" >> /etc/sudoers.d/sidedoor && \
    echo "sidedoor ALL=(ALL) NOPASSWD: /usr/bin/chage" >> /etc/sudoers.d/sidedoor && \
    echo "sidedoor ALL=(ALL) NOPASSWD: /bin/mkdir, /bin/chown, /bin/chmod, /bin/rm, /bin/rm -rf" >> /etc/sudoers.d/sidedoor && \
    echo "sidedoor ALL=(ALL) NOPASSWD: /usr/sbin/sshd" >> /etc/sudoers.d/sidedoor && \
    echo "sidedoor ALL=(ALL) NOPASSWD: /bin/systemctl daemon-reload, /bin/systemctl start, /bin/systemctl stop, /bin/systemctl enable, /bin/systemctl disable, /bin/systemctl restart" >> /etc/sudoers.d/sidedoor && \
    echo "sidedoor ALL=(ALL) NOPASSWD: /usr/bin/mount, /usr/bin/umount" >> /etc/sudoers.d/sidedoor && \
    echo "sidedoor ALL=(ALL) NOPASSWD: /usr/sbin/sshd -t" >> /etc/sudoers.d/sidedoor && \
    echo "sidedoor ALL=(ALL) NOPASSWD: /usr/bin/pkill, /usr/bin/killall" >> /etc/sudoers.d/sidedoor && \
    echo "sidedoor ALL=(ALL) NOPASSWD: /bin/mount -l" >> /etc/sudoers.d/sidedoor && \
    echo "sidedoor ALL=(ALL) NOPASSWD: /usr/local/sbin/sidedoor-systemd-helper" >> /etc/sudoers.d/sidedoor && \
    chmod 0440 /etc/sudoers.d/sidedoor

# Install systemd helper script
COPY scripts/systemd-helper.sh /usr/local/sbin/sidedoor-systemd-helper
RUN chmod 755 /usr/local/sbin/sidedoor-systemd-helper

# Configure SSH for dynamic users
# Matches generated usernames: n0x + 6 hex chars (e.g., n0x1a2b3c)
RUN mkdir -p /etc/ssh/sshd_config.d /home/sftp /var/run/sshd /var/log/sidedoor
RUN ssh-keygen -A

RUN echo "Match User n0x*" > /etc/ssh/sshd_config.d/sidedoor.conf && \
    echo "    ChrootDirectory /home/sftp/%u" >> /etc/ssh/sshd_config.d/sidedoor.conf && \
    echo "    ForceCommand internal-sftp" >> /etc/ssh/sshd_config.d/sidedoor.conf && \
    echo "    AllowTcpForwarding no" >> /etc/ssh/sshd_config.d/sidedoor.conf && \
    echo "    X11Forwarding no" >> /etc/ssh/sshd_config.d/sidedoor.conf && \
    echo "    PermitTunnel no" >> /etc/ssh/sshd_config.d/sidedoor.conf && \
    echo "    PasswordAuthentication no" >> /etc/ssh/sshd_config.d/sidedoor.conf

# Create systemd service for Sidedoor API
RUN cat > /etc/systemd/system/sidedoor.service << 'EOF'
[Unit]
Description=Sidedoor SSH/SFTP Certificate Management Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/app
Environment="NODE_ENV=production"
Environment="PATH=/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/root/.bun/bin/bun run src/index.ts
Restart=always
RestartSec=10s
StandardOutput=append:/var/log/sidedoor/sidedoor.log
StandardError=append:/var/log/sidedoor/sidedoor-errors.log

# Grant access to systemd for creating timers
Delegate=yes
CPUAccounting=yes
MemoryAccounting=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable services
# Note: sshd.service is symlinked to ssh.service in Ubuntu, so we enable the actual target
RUN systemctl enable sidedoor.service
RUN systemctl enable ssh.service

# Expose ports
EXPOSE 3000 22

# Set working directory
WORKDIR /app

# Copy project files
COPY package.json bun.lockb* ./
RUN bun install

COPY . .

# Create data and config directories
RUN mkdir -p data/certificates data/logs /var/lib/sidedoor /etc/sidedoor

# Set ownership
RUN chown -R sidedoor:sidedoor /app
RUN chown -R sidedoor:sidedoor /var/log/sidedoor
RUN chown -R sidedoor:sidedoor /var/lib/sidedoor

# Create entrypoint script for systemd on Docker Desktop
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

# Setup cgroups for systemd (Docker Desktop Mac workaround)
if [ ! -d /sys/fs/cgroup/systemd ]; then
    mkdir -p /sys/fs/cgroup/systemd 2>/dev/null || true
    mount -t cgroup -o none,name=systemd cgroup /sys/fs/cgroup/systemd 2>/dev/null || true
fi

# Start systemd as init
exec /sbin/init
EOF

RUN chmod +x /entrypoint.sh

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/entrypoint.sh"]

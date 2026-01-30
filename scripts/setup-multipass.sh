#!/bin/bash

# VM Access API - Multipass VM Setup Script
# This script creates a Ubuntu VM with all dependencies for testing

set -e

VM_NAME="vm-access-dev"
CPU_COUNT=2
MEMORY_SIZE="4G"
DISK_SIZE="20G"
CLOUD_INIT="cloud-init.yaml"

echo "🔧 Setting up VM Access API development environment with Multipass..."

# Check if multipass is installed
if ! command -v multipass &> /dev/null; then
    echo "❌ Multipass is not installed. Please install it first:"
    echo "   brew install --cask multipass"
    exit 1
fi

# Check if VM already exists
if multipass info "$VM_NAME" &> /dev/null; then
    echo "⚠️  VM '$VM_NAME' already exists. Deleting it..."
    multipass delete --purge "$VM_NAME"
fi

echo "📝 Creating cloud-init configuration..."
cat > "$CLOUD_INIT" << 'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages:
  - curl
  - git
  - build-essential
  - openssh-server
  - sudo

runcmd:
  # Create tempo user with sudo permissions
  - useradd -r -s /bin/bash -m tempo || true
  - usermod -aG sudo tempo || true
  - echo "tempo ALL=(ALL) NOPASSWD: /usr/sbin/useradd, /usr/sbin/userdel, /usr/sbin/usermod" >> /etc/sudoers.d/vm-access
  - echo "tempo ALL=(ALL) NOPASSWD: /usr/bin/chage" >> /etc/sudoers.d/vm-access
  - echo "tempo ALL=(ALL) NOPASSWD: /bin/mkdir, /bin/chown, /bin/chmod, /bin/rm" >> /etc/sudoers.d/vm-access
  - echo "tempo ALL=(ALL) NOPASSWD: /usr/sbin/sshd, /bin/systemctl restart sshd" >> /etc/sudoers.d/vm-access
  - echo "tempo ALL=(ALL) NOPASSWD: /usr/bin/tail /var/log/auth.log" >> /etc/sudoers.d/vm-access
  - chmod 0440 /etc/sudoers.d/vm-access

  # Install Bun
  - curl -fsSL https://bun.sh/install | bash
  - export PATH="/home/ubuntu/.bun/bin:$PATH"

  # Create chroot base directory
  - mkdir -p /home/sftp
  - chmod 755 /home/sftp

  # Configure SSH chroot
  - mkdir -p /etc/ssh/sshd_config.d
  - |
    cat > /etc/ssh/sshd_config.d/vm-access.conf << 'SSHCFG'
    Match User cert_user_*
        ChrootDirectory /home/sftp/%u
        ForceCommand internal-sftp
        AllowTcpForwarding no
        X11Forwarding no
        PermitTunnel no
        PasswordAuthentication no
    SSHCFG

  # Restart SSH to apply config
  - systemctl restart sshd

  # Create project directory
  - mkdir -p /home/ubuntu/vm-access
  - chown ubuntu:ubuntu /home/ubuntu/vm-access

  # Print success message
  - |
    cat >> /etc/motd << 'MOTD'
    ╔═══════════════════════════════════════════════════════════╗
    ║       VM Access API Development Environment Ready!        ║
    ╠═══════════════════════════════════════════════════════════╣
    ║   SSH access:  multipass shell vm-access-dev               ║
    ║   Project dir: /home/ubuntu/vm-access                      ║
    ║   Username:    ubuntu (sudo access)                        ║
    ║   Service:     tempo (for app user)                        ║
    ╚═══════════════════════════════════════════════════════════╝
    MOTD
EOF

echo "🚀 Launching Ubuntu VM with $CPU_COUNT CPUs, $MEMORY_SIZE RAM, $DISK_SIZE disk..."
multipass launch \
    --name "$VM_NAME" \
    --cpus "$CPU_COUNT" \
    --memory "$MEMORY_SIZE" \
    --disk "$DISK_SIZE" \
    --cloud-init "$CLOUD_INIT" \
    jammy

echo "⏳ Waiting for VM to be ready..."
sleep 10

# Get VM IP
VM_IP=$(multipass info "$VM_NAME" --format json | jq -r '.info.'"$VM_NAME"'.ipv4[0]')
echo "🌐 VM IP Address: $VM_IP"

echo "📦 Copying project files to VM..."
# The VM is just initialized, so we need to wait and then copy
sleep 5

# Mount local project directory
echo "📂 Mounting local project directory..."
multipass mount "$PWD" "$VM_NAME:/home/ubuntu/vm-access"

echo "🔧 Installing dependencies in VM..."
multipass exec "$VM_NAME" -- bash -lc "
  export PATH=\"/home/ubuntu/.bun/bin:\$PATH\"
  cd /home/ubuntu/vm-access
  bun install
"

echo ""
echo "✅ Setup complete!"
echo ""
echo "🎯 Quick Start Commands:"
echo "   multipass shell $VM_NAME              # SSH into the VM"
echo "   multipass exec $VM_NAME -- bun run    # Run from macOS"
echo "   multipass stop $VM_NAME               # Stop the VM"
echo "   multipass start $VM_NAME              # Start the VM"
echo "   multipass delete --purge $VM_NAME     # Delete the VM"
echo ""
echo "🧪 Testing the API:"
echo "   multipass shell $VM_NAME"
echo "   cd /home/ubuntu/vm-access"
echo "   sudo -u tempo bun run src/index.ts"
echo ""

# Clean up cloud-init file
rm -f "$CLOUD_INIT"

echo "💡 Tip: Forward the API port to access from macOS:"
echo "   multipass exec $VM_NAME -- bash -c 'sudo -u tempo bun run src/index.ts' &"
echo "   multipass exec $VM_NAME -- curl http://localhost:3000/health"

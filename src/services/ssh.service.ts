import { promises as fs } from 'node:fs';
import { SSH_CONFIG_PATH } from '../config/constants';
import { getConfig } from '../config';

export interface SSHCommandResult {
  success: boolean;
  stdout?: string;
  stderr?: string;
  exitCode?: number;
}

export class SSHService {
  private config = getConfig();

  /**
   * Execute a shell command with sudo
   */
  private async execSudo(command: string, args: string[]): Promise<SSHCommandResult> {
    const proc = Bun.spawn(['sudo', ...args], {
      stdout: 'pipe',
      stderr: 'pipe',
    });

    const exitCode = await proc.exited;
    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();

    return {
      success: exitCode === 0,
      stdout,
      stderr,
      exitCode,
    };
  }

  /**
   * Create a new system user
   */
  async createUser(username: string, homeDirectory?: string): Promise<SSHCommandResult> {
    const args = ['/usr/sbin/useradd', '-r'];

    if (homeDirectory) {
      args.push('-d', homeDirectory);
    }

    args.push('-s', '/bin/bash', username);

    return this.execSudo('useradd', args);
  }

  /**
   * Delete a system user
   */
  async deleteUser(username: string, removeHome: boolean = true): Promise<SSHCommandResult> {
    const args = ['/usr/sbin/userdel'];

    if (removeHome) {
      args.push('--remove');
    }

    args.push(username);

    return this.execSudo('userdel', args);
  }

  /**
   * Add public key to user's authorized_keys
   */
  async addPublicKey(username: string, publicKey: string): Promise<SSHCommandResult> {
    const sshDir = `/home/${username}/.ssh`;
    const authKeysFile = `${sshDir}/authorized_keys`;

    // Create .ssh directory
    const mkdirProc = Bun.spawn(['sudo', 'mkdir', '-p', sshDir], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await mkdirProc.exited;

    // Set ownership
    const chownProc = Bun.spawn(['sudo', 'chown', '-R', `${username}:${username}`, sshDir], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await chownProc.exited;

    // Set permissions
    const chmodProc = Bun.spawn(['sudo', 'chmod', '700', sshDir], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await chmodProc.exited;

    // Write public key to authorized_keys
    const writeProc = Bun.spawn(['sudo', 'tee', authKeysFile], {
      stdin: new TextEncoder().encode(`${publicKey}\n`),
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await writeProc.exited;

    // Set authorized_keys ownership (must be done after writing)
    const authKeysChownProc = Bun.spawn(
      ['sudo', 'chown', `${username}:${username}`, authKeysFile],
      {
        stdout: 'pipe',
        stderr: 'pipe',
      }
    );
    await authKeysChownProc.exited;

    // Set authorized_keys permissions
    const authKeysChmodProc = Bun.spawn(['sudo', 'chmod', '600', authKeysFile], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await authKeysChmodProc.exited;

    return { success: true };
  }

  /**
   * Remove public key from user's authorized_keys
   */
  async removePublicKey(username: string, publicKey: string): Promise<SSHCommandResult> {
    const authKeysFile = `/home/${username}/.ssh/authorized_keys`;

    // Read current file
    let content: string;
    try {
      content = await fs.readFile(authKeysFile, 'utf-8');
    } catch {
      return { success: true };
    }

    const lines = content.split('\n');
    const filtered = lines.filter((line) => {
      const key = line.trim().split(' ').slice(1).join(' ');
      return key !== publicKey.trim();
    });

    // Write back
    const writeProc = Bun.spawn(['sudo', 'tee', authKeysFile], {
      stdin: new TextEncoder().encode(filtered.join('\n')),
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await writeProc.exited;

    return { success: true };
  }

  /**
   * Restart SSH service
   */
  async restartSSH(): Promise<SSHCommandResult> {
    const proc = Bun.spawn(['sudo', '/bin/systemctl', 'restart', 'ssh'], {
      stdout: 'pipe',
      stderr: 'pipe',
    });

    const exitCode = await proc.exited;
    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();

    return {
      success: exitCode === 0,
      stdout,
      stderr,
      exitCode,
    };
  }

  /**
   * Check if SSH service is running
   */
  async checkSSHStatus(): Promise<SSHCommandResult> {
    const proc = Bun.spawn(['sudo', '/bin/systemctl', 'is-active', 'ssh'], {
      stdout: 'pipe',
      stderr: 'pipe',
    });

    const exitCode = await proc.exited;
    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();

    return {
      success: exitCode === 0,
      stdout: stdout.trim(),
      stderr,
      exitCode,
    };
  }

  /**
   * Read auth.log for SFTP access logs
   */
  async readAuthLog(lines: number = 100): Promise<SSHCommandResult> {
    const proc = Bun.spawn(['sudo', '/usr/bin/tail', '-n', String(lines), '/var/log/auth.log'], {
      stdout: 'pipe',
      stderr: 'pipe',
    });

    const exitCode = await proc.exited;
    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();

    return {
      success: exitCode === 0,
      stdout,
      stderr,
      exitCode,
    };
  }

  /**
   * Check if user exists
   */
  async userExists(username: string): Promise<boolean> {
    const proc = Bun.spawn(['getent', 'passwd', username], {
      stdout: 'pipe',
      stderr: 'pipe',
    });

    const exitCode = await proc.exited;
    return exitCode === 0;
  }

  /**
   * Verify SSH config syntax
   */
  async testSSHConfig(): Promise<SSHCommandResult> {
    const proc = Bun.spawn(['sudo', '/usr/sbin/sshd', '-t'], {
      stdout: 'pipe',
      stderr: 'pipe',
    });

    const exitCode = await proc.exited;
    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();

    return {
      success: exitCode === 0,
      stdout,
      stderr,
      exitCode,
    };
  }

  // ========== Dynamic User Methods (NEW) ==========

  /**
   * Create dynamic Linux user with chroot for certificate
   * Each certificate gets its own user: n0x1a2b3c format (9 characters total)
   * Format: n0x + 6 hex chars (e.g., n0x1a2b3c, n0x9f8e7d)
   */
  async createUserWithChroot(username: string): Promise<SSHCommandResult> {
    // Create user
    const createResult = await this.createUser(username, `/home/${username}`);
    if (!createResult.success) {
      return createResult;
    }

    // Create chroot directory
    const chrootPath = `/home/sftp/${username}`;
    const mkdirProc = Bun.spawn(['sudo', 'mkdir', '-p', chrootPath], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await mkdirProc.exited;

    // Set ownership (must be root:root for chroot)
    const chownProc = Bun.spawn(['sudo', 'chown', 'root:root', chrootPath], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await chownProc.exited;

    // Set permissions
    const chmodProc = Bun.spawn(['sudo', 'chmod', '755', chrootPath], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await chmodProc.exited;

    // Create .ssh directory in user's home
    const sshDir = `/home/${username}/.ssh`;
    const sshMkdirProc = Bun.spawn(['sudo', 'mkdir', '-p', sshDir], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await sshMkdirProc.exited;

    const sshChownProc = Bun.spawn(['sudo', 'chown', '-R', `${username}:${username}`, sshDir], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await sshChownProc.exited;

    const sshChmodProc = Bun.spawn(['sudo', 'chmod', '700', sshDir], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await sshChmodProc.exited;

    return { success: true, stdout: `User ${username} with chroot created` };
  }

  /**
   * Create bind mount for directory access
   * Allows user inside chroot to access external directories
   */
  async createBindMount(
    username: string,
    sourcePath: string,
    mountPoint: string
  ): Promise<SSHCommandResult> {
    const chrootPath = `/home/sftp/${username}`;
    const fullMountPoint = `${chrootPath}${mountPoint}`;

    // Create mount point directory
    const mkdirProc = Bun.spawn(['sudo', 'mkdir', '-p', fullMountPoint], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await mkdirProc.exited;

    // Create bind mount
    const mountProc = Bun.spawn(['sudo', 'mount', '--bind', sourcePath, fullMountPoint], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    const exitCode = await mountProc.exited;
    const stderr = await new Response(mountProc.stderr).text();

    if (exitCode !== 0) {
      return { success: false, stderr, exitCode };
    }

    return { success: true, stdout: `Mounted ${sourcePath} to ${fullMountPoint}` };
  }

  /**
   * Unmount bind mount
   * Uses lazy unmount to detach even if busy
   */
  async unmountBindMount(mountPoint: string): Promise<SSHCommandResult> {
    // Lazy unmount (detach even if busy)
    const proc = Bun.spawn(['sudo', 'umount', '-l', mountPoint], {
      stdout: 'pipe',
      stderr: 'pipe',
    });

    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();

    return {
      success: exitCode === 0,
      stderr,
      exitCode,
    };
  }

  /**
   * Delete user and chroot
   * Cleans up all resources for a certificate
   */
  async deleteUserWithChroot(username: string): Promise<SSHCommandResult> {
    const chrootPath = `/home/sftp/${username}`;

    // Kill any user processes first
    const killProc = Bun.spawn(['sudo', 'pkill', '-u', username], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await killProc.exited;
    // Ignore if pkill fails (no processes running)

    // Unmount any bind mounts
    const mountProc = Bun.spawn(['sudo', 'mount', '-l'], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    const mounts = await new Response(mountProc.stdout).text();
    const mountLines = mounts
      .split('\n')
      .filter((line) => line.trim() && line.includes(chrootPath));

    for (const mountLine of mountLines) {
      const parts = mountLine.split(/\s+/);
      if (parts.length > 2) {
        const mountPoint = parts[2];
        if (mountPoint) {
          await this.unmountBindMount(mountPoint);
        }
      }
    }

    // Remove chroot directory
    const rmProc = Bun.spawn(['sudo', 'rm', '-rf', chrootPath], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await rmProc.exited;

    // Remove user home directory
    const homeRmProc = Bun.spawn(['sudo', 'rm', '-rf', `/home/${username}`], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await homeRmProc.exited;

    // Delete user
    return await this.deleteUser(username, true);
  }

  /**
   * Configure SSH chroot for dynamic users (n0x* pattern)
   * Each user gets their own chroot directory at /home/sftp/{username}
   * Match User n0x* applies to all generated usernames (e.g., n0x1a2b3c)
   */
  async configureSSHChroot(): Promise<SSHCommandResult> {
    const configContent = `
# Sidedoor API - Chroot configuration for dynamic certificate users
# Matches all generated usernames: n0x + 6 hex chars (e.g., n0x1a2b3c)
Match User n0x*
    ChrootDirectory /home/sftp/%u
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    PasswordAuthentication no
`;

    const writeProc = Bun.spawn(['sudo', 'tee', SSH_CONFIG_PATH], {
      stdin: new TextEncoder().encode(configContent),
      stdout: 'pipe',
      stderr: 'pipe',
    });
    await writeProc.exited;

    return this.restartSSH();
  }

  /**
   * Get list of bind mounts for a user
   */
  async getBindMounts(username: string): Promise<string[]> {
    const chrootPath = `/home/sftp/${username}`;

    const proc = Bun.spawn(['sudo', 'mount', '-l', '-t', 'none'], {
      stdout: 'pipe',
      stderr: 'pipe',
    });

    const output = await new Response(proc.stdout).text();
    const lines = output.split('\n');

    return lines
      .filter((line) => line.includes(chrootPath))
      .map((line) => {
        const parts = line.split(/\s+/);
        return parts.length > 2 ? (parts[2] ?? '') : '';
      })
      .filter((mount): mount is string => mount.length > 0);
  }
}

// Lazy singleton instance
let _sshServiceInstance: SSHService | null = null;
export function getSSHService(): SSHService {
  if (!_sshServiceInstance) {
    _sshServiceInstance = new SSHService();
  }
  return _sshServiceInstance;
}

// Convenience export for backward compatibility
export const sshService = new Proxy({} as SSHService, {
  get(target, prop) {
    return getSSHService()[prop as keyof SSHService];
  },
});

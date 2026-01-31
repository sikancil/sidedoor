import { promises as fs } from 'node:fs';
import type { SSHCommandResult } from './ssh.service';
import { getConfig } from '../config';

export interface SystemdTimerConfig {
  username: string;
  expiresAt: Date;
  cleanupEndpoint: string;
}

export class SystemdService {
  /**
   * Create systemd timer and service for certificate cleanup
   * Timer fires once at expiration time and triggers cleanup endpoint
   * Uses privileged helper script for secure systemd operations
   */
  async createCleanupTimer(config: SystemdTimerConfig): Promise<void> {
    const { username, expiresAt, cleanupEndpoint } = config;
    const cronSecret = process.env.CRON_SECRET || 'default-secret';

    // Get API port from config
    const appConfig = getConfig();
    const apiUrl = `http://localhost:${appConfig.port}${cleanupEndpoint}`;

    // Format date for systemd OnCalendar (RFC 3339 format)
    const calendarTime = expiresAt.toISOString();

    // Call privileged helper script via sudo
    const args = [
      'create-timer',
      username,
      calendarTime,
      cronSecret,
      apiUrl
    ];

    await this.execHelper(args);

    console.log(`Created systemd timer for ${username}: expires at ${calendarTime}`);
  }

  /**
   * Delete systemd timer and service
   */
  async deleteCleanupTimer(username: string): Promise<void> {
    // Call privileged helper script via sudo
    const args = ['delete-timer', username];
    await this.execHelper(args);

    console.log(`Deleted systemd timer for ${username}`);
  }

  /**
   * List all sidedoor timers
   */
  async listTimers(): Promise<string[]> {
    const proc = Bun.spawn(['systemctl', 'list-timers', 'sidedoor-*', '--no-pager', '--plain'], {
      stdout: 'pipe',
      stderr: 'pipe',
    });

    const output = await new Response(proc.stdout).text();
    const lines = output.split('\n');

    // Extract timer names from output
    // Matches: sidedoor-n0x + 6 hex chars (e.g., sidedoor-n0x1a2b3c.timer)
    return lines
      .filter(line => line.includes('sidedoor-'))
      .map(line => {
        const match = line.match(/(sidedoor-n0x[a-f0-9]+)\.timer/);
        return match ? match[1] : null;
      })
      .filter((name): name is string => name !== null);
  }

  /**
   * Get timer status for a specific user
   */
  async getTimerStatus(username: string): Promise<{ active: boolean; nextRun?: string } | null> {
    const timerName = `sidedoor-${username}.timer`;

    const proc = Bun.spawn(['systemctl', 'show', timerName, '--no-pager'], {
      stdout: 'pipe',
      stderr: 'pipe',
    });

    const output = await new Response(proc.stdout).text();
    const lines = output.split('\n');

    const isActive = lines.some(line => line.startsWith('ActiveState=active'));
    const nextRunLine = lines.find(line => line.startsWith('NextElapseUSecMonotonic='));
    const nextRun = nextRunLine?.split('=')[1];

    if (!isActive) {
      return null;
    }

    return { active: isActive, nextRun };
  }

  /**
   * Recreate timers for active certificates (startup recovery)
   */
  async recoverActiveTimers(activeCertificates: Array<{
    username: string;
    expires_at: string;
  }>): Promise<void> {
    const recovered: string[] = [];
    const failed: Array<{ username: string; error: string }> = [];

    for (const cert of activeCertificates) {
      const expiresAt = new Date(cert.expires_at);
      const now = new Date();

      // Only recreate if not already expired
      if (expiresAt > now) {
        try {
          await this.createCleanupTimer({
            username: cert.username,
            expiresAt,
            cleanupEndpoint: `/admin/cleanup/${cert.username}`,
          });
          recovered.push(cert.username);
        } catch (error) {
          failed.push({
            username: cert.username,
            error: (error as Error).message,
          });
        }
      }
    }

    console.log(`Timer recovery: ${recovered.length} recovered, ${failed.length} failed`);
    if (failed.length > 0) {
      console.warn('Failed to recover timers:', failed);
    }
  }

  /**
   * Check if a timer exists for a user
   */
  async timerExists(username: string): Promise<boolean> {
    const timers = await this.listTimers();
    return timers.includes(`sidedoor-${username}`);
  }

  /**
   * Ensure log directory exists
   */
  async ensureLogDirectory(): Promise<void> {
    await fs.mkdir('/var/log/sidedoor', { recursive: true });
  }

  /**
   * Execute privileged helper script via sudo
   * Routes systemd operations through secure wrapper
   */
  private async execHelper(args: string[]): Promise<string> {
    const helperPath = '/usr/local/sbin/sidedoor-systemd-helper';
    const command = `sudo ${helperPath} ${args.join(' ')}`;

    const proc = Bun.spawn(['/bin/sh', '-c', command], { stdout: 'pipe', stderr: 'pipe' });
    const exitCode = await proc.exited;
    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();

    if (exitCode !== 0) {
      throw new Error(`Helper script failed: ${command}\n${stderr}`);
    }

    return stdout;
  }

  /**
   * Execute shell command
   */
  private async exec(command: string): Promise<string> {
    // Split command into array for Bun.spawn
    const args = ['/bin/sh', '-c', command];
    const proc = Bun.spawn(args, { stdout: 'pipe', stderr: 'pipe' });
    const exitCode = await proc.exited;
    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();

    if (exitCode !== 0) {
      throw new Error(`Command failed: ${command}\n${stderr}`);
    }

    return stdout;
  }
}

// Lazy singleton instance
let _systemdServiceInstance: SystemdService | null = null;
export function getSystemdService(): SystemdService {
  if (!_systemdServiceInstance) {
    _systemdServiceInstance = new SystemdService();
  }
  return _systemdServiceInstance;
}

// Convenience export
export const systemdService = new Proxy({} as SystemdService, {
  get(target, prop) {
    return getSystemdService()[prop as keyof SystemdService];
  }
});

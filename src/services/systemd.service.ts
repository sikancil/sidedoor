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
   */
  async createCleanupTimer(config: SystemdTimerConfig): Promise<void> {
    const { username, expiresAt, cleanupEndpoint } = config;
    const timerName = `sidedoor-${username}`;
    const serviceName = `sidedoor-cleanup-${username}`;
    const cronSecret = process.env.CRON_SECRET || 'default-secret';

    // Get API port from config (instead of hardcoding 3000)
    const appConfig = getConfig();
    const apiUrl = `http://localhost:${appConfig.port}${cleanupEndpoint}`;

    // Format date for systemd OnCalendar (RFC 3339 format)
    const calendarTime = expiresAt.toISOString();

    // Generate timer unit file
    const timerContent = `[Unit]
Description=Sidedoor Certificate Cleanup for ${username}
Requires=${serviceName}.service

[Timer]
OnCalendar=${calendarTime}
AccuracySec=1ms
Unit=${serviceName}.service

[Install]
WantedBy=timers.target
`;

    // Generate service unit file
    const serviceContent = `[Unit]
Description=Sidedoor Certificate Cleanup for ${username}
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/curl -s -X POST ${apiUrl} \\
  -H "Authorization: Bearer ${cronSecret}" \\
  -H "X-Certificate-Id: ${username}" \\
  -H "X-Trigger: systemd"
StandardOutput=append:/var/log/sidedoor/cleanup.log
StandardError=append:/var/log/sidedoor/cleanup-errors.log
Restart=on-failure
RestartSec=30s

# Auto-delete after execution
ExecStartPost=/bin/systemctl disable ${timerName}.timer
ExecStartPost=/bin/rm -f /etc/systemd/system/${timerName}.{timer,service}
ExecStartPost=/bin/systemctl daemon-reload
`;

    // Ensure systemd directory exists
    await fs.mkdir('/etc/systemd/system', { recursive: true });

    // Write systemd files
    await fs.writeFile(`/etc/systemd/system/${timerName}.timer`, timerContent);
    await fs.writeFile(`/etc/systemd/system/${serviceName}.service`, serviceContent);

    // Reload systemd and start timer
    await this.exec('systemctl daemon-reload');
    await this.exec(`systemctl start ${timerName}.timer`);
    await this.exec(`systemctl enable ${timerName}.timer`);

    console.log(`Created systemd timer for ${username}: expires at ${calendarTime}`);
  }

  /**
   * Delete systemd timer and service
   */
  async deleteCleanupTimer(username: string): Promise<void> {
    const timerName = `sidedoor-${username}`;
    const serviceName = `sidedoor-cleanup-${username}`;

    // Stop and disable timer
    await this.exec(`systemctl stop ${timerName}.timer`).catch(() => {});
    await this.exec(`systemctl disable ${timerName}.timer`).catch(() => {});

    // Remove files
    await fs.unlink(`/etc/systemd/system/${timerName}.timer`).catch(() => {});
    await fs.unlink(`/etc/systemd/system/${serviceName}.service`).catch(() => {});

    // Reload systemd
    await this.exec('systemctl daemon-reload');

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
   * Execute shell command
   */
  private async exec(command: string): Promise<string> {
    const proc = Bun.spawn(command, { shell: true, stdout: 'pipe', stderr: 'pipe' });
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

import { getCertificateModel } from '../models/Certificate.model';
import { getSSHService } from './ssh.service';
import { getSystemdService } from './systemd.service';

export class RecoveryService {
  /**
   * Recover timers for active certificates on startup
   * Recreates systemd timers for any active certificates that don't have timers
   */
  async recoverTimers(): Promise<void> {
    const activeCerts = getCertificateModel().findAll({ status: 'active' });
    const timers = await getSystemdService().listTimers();

    // Find certificates without timers
    const certsNeedingTimers = activeCerts.filter(
      (cert) => !timers.includes(`sidedoor-${cert.username}`)
    );

    if (certsNeedingTimers.length === 0) {
      console.log('Timer recovery: All active certificates have timers');
      return;
    }

    console.log(`Recovering timers for ${certsNeedingTimers.length} active certificates...`);

    await getSystemdService().recoverActiveTimers(
      certsNeedingTimers.map((cert) => ({
        username: cert.username,
        expires_at: cert.expires_at,
      }))
    );

    console.log('Timer recovery complete');
  }

  /**
   * Cleanup orphaned resources
   * Finds certificates with status=active but no user/timer and marks them as revoked
   */
  async cleanupOrphans(): Promise<{ cleaned: number; errors: string[] }> {
    const activeCerts = getCertificateModel().findAll({ status: 'active' });
    const cleaned: string[] = [];
    const errors: string[] = [];

    for (const cert of activeCerts) {
      const userExists = await getSSHService().userExists(cert.username);
      const timers = await getSystemdService().listTimers();
      const hasTimer = timers.includes(`sidedoor-${cert.username}`);

      // If no user and no timer, mark as revoked
      if (!userExists && !hasTimer) {
        console.log(`Cleaning up orphaned certificate: ${cert.username}`);
        try {
          getCertificateModel().update(cert.id, {
            status: 'revoked',
            revoked_at: new Date().toISOString(),
            revoked_by: 'recovery-service',
            revoke_reason: 'orphaned_no_user_no_timer',
          });
          cleaned.push(cert.username);
        } catch (error) {
          errors.push(`${cert.username}: ${(error as Error).message}`);
        }
      }
    }

    return {
      cleaned: cleaned.length,
      errors,
    };
  }

  /**
   * Validate system state
   * Checks for inconsistencies between certificates, users, and timers
   */
  async validateState(): Promise<{
    valid: boolean;
    issues: Array<{ type: string; description: string; certificate_id?: string }>;
  }> {
    const issues: Array<{ type: string; description: string; certificate_id?: string }> = [];
    const activeCerts = getCertificateModel().findAll({ status: 'active' });
    const timers = await getSystemdService().listTimers();

    for (const cert of activeCerts) {
      const userExists = await getSSHService().userExists(cert.username);
      const hasTimer = timers.includes(`sidedoor-${cert.username}`);

      if (!userExists) {
        issues.push({
          type: 'missing_user',
          description: `Certificate ${cert.username} has no system user`,
          certificate_id: cert.id,
        });
      }

      if (!hasTimer) {
        issues.push({
          type: 'missing_timer',
          description: `Certificate ${cert.username} has no systemd timer`,
          certificate_id: cert.id,
        });
      }

      // Check if expired but still active
      const expiresAt = new Date(cert.expires_at);
      if (expiresAt < new Date()) {
        issues.push({
          type: 'expired_still_active',
          description: `Certificate ${cert.username} expired but still marked active`,
          certificate_id: cert.id,
        });
      }
    }

    // Check for timers without certificates
    for (const timer of timers) {
      const username = timer.replace('sidedoor-', '');
      const cert = activeCerts.find((c) => c.username === username);
      if (!cert) {
        issues.push({
          type: 'orphaned_timer',
          description: `Timer ${timer} exists but has no active certificate`,
        });
      }
    }

    return {
      valid: issues.length === 0,
      issues,
    };
  }

  /**
   * Get recovery statistics
   */
  async getStats(): Promise<{
    active_certificates: number;
    active_timers: number;
    users_with_chroot: number;
    expired_not_revoked: number;
  }> {
    const activeCerts = getCertificateModel().findAll({ status: 'active' });
    const timers = await getSystemdService().listTimers();
    const now = new Date();

    const usersWithChroot = await Promise.all(
      activeCerts.map(async (cert) => {
        const userExists = await getSSHService().userExists(cert.username);
        return userExists ? 1 : 0;
      })
    ).then((counts) => counts.reduce<number>((a, b) => a + b, 0));

    const expiredNotRevoked = activeCerts.filter((cert) => {
      const expiresAt = new Date(cert.expires_at);
      return expiresAt < now;
    }).length;

    return {
      active_certificates: activeCerts.length,
      active_timers: timers.length,
      users_with_chroot: usersWithChroot,
      expired_not_revoked: expiredNotRevoked,
    };
  }
}

// Lazy singleton instance
let _recoveryServiceInstance: RecoveryService | null = null;
/**
 * Get the shared RecoveryService singleton, creating and caching it on first use.
 *
 * @returns The cached `RecoveryService` instance
 */
export function getRecoveryService(): RecoveryService {
  if (!_recoveryServiceInstance) {
    _recoveryServiceInstance = new RecoveryService();
  }
  return _recoveryServiceInstance;
}

// Convenience export
export const recoveryService = new Proxy({} as RecoveryService, {
  get(target, prop) {
    return getRecoveryService()[prop as keyof RecoveryService];
  },
});
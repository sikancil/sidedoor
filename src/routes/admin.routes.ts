import { Elysia, t } from 'elysia';
import { getCertificateModel } from '../models/Certificate.model';
import { getSSHService } from '../services/ssh.service';
import { getSystemdService } from '../services/systemd.service';
import { requireAdminAuth } from '../middleware/admin-auth.middleware';

export const adminRoutes = new Elysia({ prefix: '/admin' })
  .use(requireAdminAuth)

  /**
   * Cleanup certificate (triggered by systemd timer or manual)
   * POST /admin/cleanup/:username
   */
  .post(
    '/cleanup/:username',
    async ({ params, request, set }) => {
      const startTime = Date.now();
      const username = params.username;
      const triggeredBy = request.headers.get('x-trigger') ?? 'manual';

      // Find certificate by username
      const cert = getCertificateModel().findByUsername(username);
      if (!cert) {
        set.status = 404;
        return {
          success: false,
          error: `Certificate not found: ${username}`,
          username,
        };
      }

      const actions: string[] = [];
      const errors: string[] = [];

      // 1. Delete systemd timer if exists
      try {
        await getSystemdService().deleteCleanupTimer(username);
        actions.push('Deleted systemd timer');
      } catch (error) {
        errors.push(`Failed to delete timer: ${(error as Error).message}`);
      }

      // 2. Unmount bind mounts
      const mountPoints = JSON.parse(cert.mount_points || '[]');
      for (const mount of mountPoints) {
        try {
          const result = await getSSHService().unmountBindMount(mount);
          if (result.success) {
            actions.push(`Unmounted: ${mount}`);
          } else {
            errors.push(`Failed to unmount ${mount}: ${result.stderr}`);
          }
        } catch (error) {
          errors.push(`Failed to unmount ${mount}: ${(error as Error).message}`);
        }
      }

      // 3. Remove SSH key from authorized_keys
      try {
        const sshResult = await getSSHService().removePublicKey(cert.username, cert.public_key);
        if (sshResult.success) {
          actions.push('Removed SSH key from authorized_keys');
        } else {
          errors.push(`Failed to remove SSH key: ${sshResult.stderr}`);
        }
      } catch (error) {
        errors.push(`Failed to remove SSH key: ${(error as Error).message}`);
      }

      // 4. Delete user and chroot
      try {
        const userResult = await getSSHService().deleteUserWithChroot(cert.username);
        if (userResult.success) {
          actions.push(`Deleted user: ${cert.username}`);
          actions.push(`Removed chroot: /home/sftp/${cert.username}`);
        } else {
          errors.push(`Failed to delete user: ${userResult.stderr}`);
        }
      } catch (error) {
        errors.push(`Failed to delete user: ${(error as Error).message}`);
      }

      // 5. Update database
      const now = new Date().toISOString();
      getCertificateModel().update(cert.id, {
        status: 'revoked',
        revoked_at: now,
        revoked_by: triggeredBy,
        user_deleted: actions.some((a) => a.includes('Deleted user')) ? 1 : 0,
        chroot_removed: actions.some((a) => a.includes('Removed chroot')) ? 1 : 0,
        cleanup_log: JSON.stringify({ actions, errors }),
      });

      // 6. Log forensic data
      const duration = Date.now() - startTime;
      const cleanupRunId = `cleanup-${username}-${Date.now()}`;
      const forensic = {
        username,
        certificate_id: cert.id,
        timestamp: now,
        triggered_by: triggeredBy,
        actions,
        errors,
        duration_ms: duration,
        systemd_triggered: triggeredBy === 'systemd',
      };

      getCertificateModel().createCleanupLog({
        cleanup_run_id: cleanupRunId,
        certificate_id: cert.id,
        username,
        triggered_by: triggeredBy,
        actions: JSON.stringify(actions),
        errors: JSON.stringify(errors),
        duration_ms: duration,
        forensic_data: JSON.stringify(forensic),
      });

      return {
        success: true,
        username,
        actions,
        errors,
        forensic,
        duration_ms: duration,
      };
    },
    {
      params: t.Object({
        username: t.String(),
      }),
    }
  )

  /**
   * List active certificates with timers
   * GET /admin/certificates/active
   */
  .get('/certificates/active', async () => {
    const certificates = getCertificateModel().findAll({ status: 'active' });
    const timers = await getSystemdService().listTimers();

    return {
      success: true,
      count: certificates.length,
      data: certificates.map((cert) => ({
        id: cert.id,
        username: cert.username,
        expires_at: cert.expires_at,
        ttl: cert.ttl,
        directory_path: cert.directory_path,
        has_timer: timers.includes(`sidedoor-${cert.username}`),
        mount_points: cert.mount_points ? JSON.parse(cert.mount_points) : [],
      })),
    };
  })

  /**
   * Get certificate cleanup logs
   * GET /admin/certificates/:username/logs
   */
  .get('/certificates/:username/logs', async ({ params }) => {
    const cert = getCertificateModel().findByUsername(params.username);
    if (!cert) {
      return {
        success: false,
        error: `Certificate not found: ${params.username}`,
      };
    }

    const logs = getCertificateModel().findCleanupLogsByCertificateId(cert.id);

    return {
      success: true,
      username: params.username,
      count: logs.length,
      logs: logs.map((log) => ({
        id: log.id,
        cleanup_run_id: log.cleanup_run_id,
        timestamp: log.timestamp,
        triggered_by: log.triggered_by,
        actions: log.actions ? JSON.parse(log.actions) : [],
        errors: log.errors ? JSON.parse(log.errors) : [],
        duration_ms: log.duration_ms,
      })),
    };
  })

  /**
   * List all systemd timers
   * GET /admin/timers
   */
  .get('/timers', async () => {
    const timers = await getSystemdService().listTimers();
    const certificates = getCertificateModel().findAll({ status: 'active' });

    const timerDetails = await Promise.all(
      timers.map(async (timer) => {
        const username = timer.replace('sidedoor-', '');
        const cert = certificates.find((c) => c.username === username);
        const status = await getSystemdService().getTimerStatus(username);

        return {
          timer,
          username,
          exists: !!cert,
          expires_at: cert?.expires_at,
          next_run: status?.nextRun,
        };
      })
    );

    return {
      success: true,
      count: timers.length,
      timers: timerDetails,
    };
  })

  /**
   * Health check for admin endpoints
   * GET /admin/health
   */
  .get('/health', async () => {
    const activeCerts = getCertificateModel().findAll({ status: 'active' });
    const timers = await getSystemdService().listTimers();

    // Check for orphaned resources (certs without timers or timers without certs)
    const orphanedCerts = activeCerts.filter(
      (cert) => !timers.includes(`sidedoor-${cert.username}`)
    );
    const orphanedTimers = timers.filter(
      (timer) => !activeCerts.find((cert) => cert.username === timer.replace('sidedoor-', ''))
    );

    return {
      success: true,
      timestamp: new Date().toISOString(),
      active_certificates: activeCerts.length,
      active_timers: timers.length,
      orphaned_certificates: orphanedCerts.length,
      orphaned_timers: orphanedTimers.length,
      warnings: [
        ...(orphanedCerts.length > 0
          ? [`${orphanedCerts.length} certificates without timers`]
          : []),
        ...(orphanedTimers.length > 0
          ? [`${orphanedTimers.length} timers without certificates`]
          : []),
      ],
    };
  });

import { Elysia } from 'elysia';
import { getDatabase } from '../config/database';
import { getSSHService } from '../services/ssh.service';

export const healthRoutes = new Elysia()

  // Health check
  .get('/health', async () => {
    const checks = {
      database: false,
      ssh: false,
      workers: false,
    };

    // Check database
    try {
      const db = getDatabase();
      db.query('SELECT 1').get();
      checks.database = true;
    } catch {
      checks.database = false;
    }

    // Check SSH service
    try {
      const sshStatus = await getSSHService().checkSSHStatus();
      checks.ssh = sshStatus.success && sshStatus.stdout === 'active';
    } catch {
      checks.ssh = false;
    }

    // Workers check (basic)
    checks.workers = true; // Workers are created on-demand

    const healthy = Object.values(checks).every((v) => v === true);

    return {
      status: healthy ? 'healthy' : 'unhealthy',
      checks,
      timestamp: new Date().toISOString(),
    };
  })

  // Readiness check
  .get('/health/ready', async () => {
    try {
      const db = getDatabase();
      db.query('SELECT 1').get();
      return { status: 'ready' };
    } catch {
      return { status: 'not ready' };
    }
  })

  // Liveness check
  .get('/health/live', () => {
    return { status: 'alive' };
  });

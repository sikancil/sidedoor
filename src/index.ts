import { Elysia } from 'elysia';
import { loadConfig, DEFAULT_CONFIG } from './config';
import { errorHandler } from './middleware/error.middleware';
import { certificateRoutes } from './routes/certificates.routes';
import { downloadRoutes } from './routes/download.routes';
import { healthRoutes } from './routes/health.routes';
import { adminRoutes } from './routes/admin.routes';
import { getRecoveryService } from './services/recovery.service';
import { getSystemdService } from './services/systemd.service';
import { getSSHService } from './services/ssh.service';

// Create Elysia app
const app = new Elysia()
  .use(errorHandler)

  // Health routes (no auth required)
  .use(healthRoutes)

  // Certificate routes (auth required)
  .use(certificateRoutes)

  // Download routes (auth required)
  .use(downloadRoutes)

  // Admin routes (admin auth required)
  .use(adminRoutes)

  // Root endpoint
  .get('/', () => ({
    name: 'Sidedoor API',
    version: '2.0.0',
    description: 'SSH/SFTP Certificate Management Service - Dynamic User Model',
    architecture: 'Dynamic users with per-certificate systemd timers',
    endpoints: {
      health: 'GET /health',
      certificates: {
        list: 'GET /api/certificates',
        create: 'POST /api/certificates',
        get: 'GET /api/certificates/:id',
        update: 'PATCH /api/certificates/:id',
        delete: 'DELETE /api/certificates/:id',
      },
      downloads: {
        key: 'GET /api/download/:id/key',
        readme: 'GET /api/download/:id/readme',
        content: 'GET /api/download/:id/content',
      },
      admin: {
        cleanup: 'POST /admin/cleanup/:username',
        active: 'GET /admin/certificates/active',
        logs: 'GET /admin/certificates/:username/logs',
        timers: 'GET /admin/timers',
        health: 'GET /admin/health',
      },
    },
  }));

// Start server
async function start() {
  // Load configuration (uses CONFIG_PATH env var or default from constants)
  const configPath = process.env.CONFIG_PATH || DEFAULT_CONFIG.configPath;
  const config = await loadConfig(configPath);

  // Check if running in development mode without systemd
  const skipSystemd = process.env.SKIP_SYSTEMD === 'true';

  if (!skipSystemd) {
    // Ensure log directory exists
    await getSystemdService().ensureLogDirectory();

    // Configure SSH for dynamic users
    console.log('Configuring SSH for dynamic users...');
    await getSSHService().configureSSHChroot();

    // Recover timers for active certificates
    console.log('Recovering active certificate timers...');
    await getRecoveryService().recoverTimers();

    // Cleanup orphaned resources
    console.log('Checking for orphaned resources...');
    const orphanResult = await getRecoveryService().cleanupOrphans();
    if (orphanResult.cleaned > 0) {
      console.log(`Cleaned up ${orphanResult.cleaned} orphaned certificates`);
    }
    if (orphanResult.errors.length > 0) {
      console.warn(`Errors during orphan cleanup: ${orphanResult.errors.join(', ')}`);
    }

    // Validate system state
    const stateValidation = await getRecoveryService().validateState();
    if (!stateValidation.valid) {
      console.warn(`System state issues detected: ${stateValidation.issues.length} issues found`);
      stateValidation.issues.forEach(issue => {
        console.warn(`  - ${issue.type}: ${issue.description}`);
      });
    }
  } else {
    console.log('⚠️  Running in DEVELOPMENT MODE without systemd');
    console.log('⚠️  Certificate expiration timers will NOT be created');
    console.log('⚠️  Manual cleanup via admin endpoints will be required');
  }

  await app.listen(config.port);

  console.log(`🚪 Sidedoor API v2.0.0 is running at http://localhost:${app.server?.port}`);
  console.log(`📂 Chroot base path: ${config.chrootBasePath}`);
  console.log(`👷 User model: Dynamic (n0x###### format, 9 chars)`);
  console.log(`⏱️  Cleanup: Per-certificate systemd timers`);
  console.log(`🔒 Authentication: Bearer token required for API endpoints`);
  console.log(`🔐 Admin authentication: CRON_SECRET environment variable`);
  console.log(``);
  console.log(`API endpoints:`);
  console.log(`  GET    /health`);
  console.log(`  GET    /api/certificates`);
  console.log(`  POST   /api/certificates`);
  console.log(`  GET    /api/certificates/:id`);
  console.log(`  PATCH  /api/certificates/:id`);
  console.log(`  DELETE /api/certificates/:id`);
  console.log(``);
  console.log(`Admin endpoints (require CRON_SECRET):`);
  console.log(`  POST   /admin/cleanup/:username`);
  console.log(`  GET    /admin/certificates/active`);
  console.log(`  GET    /admin/certificates/:username/logs`);
  console.log(`  GET    /admin/timers`);
  console.log(`  GET    /admin/health`);
}

start();

export default app;

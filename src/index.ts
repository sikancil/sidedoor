import { Elysia } from 'elysia';
import { ensureConfig, DEFAULT_CONFIG, type Config } from './config';
import { errorHandler } from './middleware/error.middleware';
import { certificateRoutes } from './routes/certificates.routes';
import { downloadRoutes } from './routes/download.routes';
import { healthRoutes } from './routes/health.routes';
import { adminRoutes } from './routes/admin.routes';
import { configRoutes } from './routes/config.routes';
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

  // Config management routes (admin auth required)
  .use(configRoutes)

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
      config: {
        get: 'GET /admin/config',
        update: 'PATCH /admin/config',
        reload: 'POST /admin/config/reload',
        validateUfw: 'GET /admin/config/validate-ufw',
        syncUfw: 'POST /admin/config/sync-ufw',
      },
    },
  }));

/**
 * Bootstraps and starts the Sidedoor API server and performs necessary startup orchestration.
 *
 * Performs configuration loading (auto-recreating missing config), optional firewall synchronization,
 * systemd log directory preparation, SSH chroot configuration for dynamic users, recovery of certificate timers,
 * cleanup of orphaned resources, and system state validation before listening on the configured port.
 * After startup, prints runtime metadata and a summary of public and admin endpoints.
 */
async function start() {
  // Load configuration (auto-recreates if missing)
  const configPath = process.env.CONFIG_PATH || DEFAULT_CONFIG.configPath;
  const config = await ensureConfig(configPath);

  // AUTOMATED: Sync UFW with config at startup
  console.log('Checking UFW configuration...');
  await syncUfwIfNeeded(config);

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
    stateValidation.issues.forEach((issue) => {
      console.warn(`  - ${issue.type}: ${issue.description}`);
    });
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
  console.log(`  GET    /admin/config`);
  console.log(`  PATCH  /admin/config`);
  console.log(`  POST   /admin/config/reload`);
  console.log(`  GET    /admin/config/validate-ufw`);
  console.log(`  POST   /admin/config/sync-ufw`);
}

/**
 * Ensure the system UFW allows the configured SSH and API ports at startup.
 *
 * Checks whether UFW is installed and active; if active, verifies that the SSH and API ports
 * from `config` are allowed and adds missing rules using `sudo ufw allow <port>/tcp`.
 * Logs actions taken and summaries. If UFW is not installed or not active, the function logs a warning and returns.
 * Any errors during detection or modification are caught and logged; the function does not throw.
 *
 * @param config - Application configuration containing `sshPort` and `port` to ensure in UFW
 * @returns void
 */
async function syncUfwIfNeeded(config: Config): Promise<void> {
  const { execSync } = require('node:child_process');

  try {
    // Check if UFW is installed
    execSync('command -v ufw', { stdio: 'ignore' });
  } catch {
    console.warn('⚠️  UFW not installed. Skipping firewall synchronization.');
    return;
  }

  try {
    // Get current UFW status (requires sudo)
    const ufwStatus = execSync('sudo ufw status', { encoding: 'utf-8' });
    const isActive = ufwStatus.includes('Status: active');

    if (!isActive) {
      console.warn('⚠️  UFW is not active. Firewall synchronization skipped.');
      console.warn('   To enable: sudo ufw enable');
      return;
    }

    const actions: string[] = [];

    // Check SSH port
    const sshRule = ufwStatus.includes(`${config.sshPort}/tcp`);
    if (!sshRule) {
      console.warn(`⚠️  SSH port ${config.sshPort} not in UFW. Adding rule...`);
      execSync(`sudo ufw allow ${config.sshPort}/tcp`, { stdio: 'pipe' });
      actions.push(`Added UFW rule for SSH port ${config.sshPort}`);
      console.log(`✅ Added UFW allow ${config.sshPort}/tcp (SSH)`);
    }

    // Check API port
    const apiRule = ufwStatus.includes(`${config.port}/tcp`);
    if (!apiRule) {
      console.warn(`⚠️  API port ${config.port} not in UFW. Adding rule...`);
      execSync(`sudo ufw allow ${config.port}/tcp`, { stdio: 'pipe' });
      actions.push(`Added UFW rule for API port ${config.port}`);
      console.log(`✅ Added UFW allow ${config.port}/tcp (API)`);
    }

    if (actions.length > 0) {
      console.log(`🔥 UFW synchronized: ${actions.join(', ')}`);
    } else {
      console.log('✅ UFW configuration validated (all ports allowed)');
    }
  } catch (error) {
    console.error(`❌ UFW sync failed: ${(error as Error).message}`);
    console.warn('   Continuing startup anyway...');
  }
}

start();

export default app;
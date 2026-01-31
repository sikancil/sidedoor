import { Elysia, t } from 'elysia';
import { getConfig, reloadConfig } from '../config';
import { requireAdminAuth } from '../middleware/admin-auth.middleware';
import { promises as fs } from 'node:fs';

export const configRoutes = new Elysia({ prefix: '/admin/config' })
  .use(requireAdminAuth)

  /**
   * Get current configuration
   * GET /admin/config
   */
  .get('/', async () => {
    const config = getConfig();

    // Return config with secrets masked
    return {
      success: true,
      config: {
        port: config.port,
        sshPort: config.sshPort,
        chrootBasePath: config.chrootBasePath,
        dbPath: config.dbPath,
        configPath: config.configPath,
        defaultDirectories: config.defaultDirectories,
        defaultPermissions: config.defaultPermissions,
        defaultTtl: config.defaultTtl,
        user: config.user,
        authenticatorToken: config.authenticatorToken ? '***SET***' : 'NOT_SET',
        cronSecret: config.cronSecret ? '***SET***' : 'NOT_SET',
      },
    };
  })

  /**
   * Update configuration (partial update)
   * PATCH /admin/config
   */
  .patch(
    '/',
    async ({ body, set }) => {
      const config = getConfig();
      const configPath = config.configPath;

      // Read current config
      const content = await fs.readFile(configPath, 'utf-8');
      const currentConfig = JSON.parse(content);

      // Merge updates
      const updatedConfig = {
        ...currentConfig,
        ...body,
        _updated: new Date().toISOString(),
      };

      // Validate ports
      if (updatedConfig.port !== undefined) {
        if (updatedConfig.port < 1 || updatedConfig.port > 65535) {
          set.status = 400;
          return { success: false, error: 'Invalid API port. Must be between 1-65535.' };
        }
      }
      if (updatedConfig.sshPort !== undefined) {
        if (updatedConfig.sshPort < 1 || updatedConfig.sshPort > 65535) {
          set.status = 400;
          return { success: false, error: 'Invalid SSH port. Must be between 1-65535.' };
        }
      }

      // Write updated config atomically
      const tmpPath = `${configPath}.tmp`;
      await fs.writeFile(tmpPath, JSON.stringify(updatedConfig, null, 2));
      await fs.rename(tmpPath, configPath);

      // Check if restart is needed (port changes)
      const needsRestart =
        (updatedConfig.port !== undefined && updatedConfig.port !== currentConfig.port) ||
        (updatedConfig.sshPort !== undefined && updatedConfig.sshPort !== currentConfig.sshPort);

      if (needsRestart) {
        // AUTOMATED: Trigger service restart via systemd
        try {
          // Reload config in memory first
          await reloadConfig(configPath);

          // Trigger systemd restart (background, non-blocking)
          const { execSync } = require('node:child_process');
          execSync('systemctl reload-or-restart sidedoor.service &', { stdio: 'pipe' });

          return {
            success: true,
            message: 'Configuration updated. Service restart initiated.',
            restartScheduled: true,
            config: {
              port: updatedConfig.port,
              sshPort: updatedConfig.sshPort,
            },
            warning: 'Service will restart momentarily. Existing connections may be interrupted.',
          };
        } catch (error) {
          return {
            success: true,
            message: 'Configuration updated. Manual restart required.',
            restartFailed: true,
            error: (error as Error).message,
            hint: 'Run: sudo systemctl restart sidedoor.service',
          };
        }
      }

      // Reload config (no restart needed)
      await reloadConfig(configPath);

      return {
        success: true,
        message: 'Configuration updated and reloaded.',
        restartRequired: false,
        config: {
          port: updatedConfig.port,
          sshPort: updatedConfig.sshPort,
        },
      };
    },
    {
      body: t.Object({
        port: t.Optional(t.Number()),
        sshPort: t.Optional(t.Number()),
        defaultDirectories: t.Optional(t.Array(t.String())),
        defaultPermissions: t.Optional(t.Array(t.String())),
        defaultTtl: t.Optional(t.Number()),
      }),
    }
  )

  /**
   * Reload configuration
   * POST /admin/config/reload
   */
  .post('/reload', async () => {
    const config = getConfig();
    await reloadConfig(config.configPath);

    return {
      success: true,
      message: 'Configuration reloaded successfully',
      timestamp: new Date().toISOString(),
    };
  })

  /**
   * Validate UFW matches config
   * GET /admin/config/validate-ufw
   */
  .get('/validate-ufw', async () => {
    const config = getConfig();
    const { execSync } = require('node:child_process');

    const issues: string[] = [];

    try {
      // Check if UFW is active (requires sudo)
      const ufwStatus = execSync('sudo ufw status', { encoding: 'utf-8' });
      const isActive = ufwStatus.includes('Status: active');

      if (!isActive) {
        issues.push('UFW is not active');
      }

      // Check SSH port
      const sshRule =
        ufwStatus.includes(`${config.sshPort}/tcp`) || ufwStatus.includes(`${config.sshPort} `);
      if (!sshRule && isActive) {
        issues.push(`SSH port ${config.sshPort} not allowed in UFW`);
      }

      // Check API port
      const apiRule =
        ufwStatus.includes(`${config.port}/tcp`) || ufwStatus.includes(`${config.port} `);
      if (!apiRule && isActive) {
        issues.push(`API port ${config.port} not allowed in UFW`);
      }

      return {
        success: issues.length === 0,
        ufwActive: isActive,
        config: {
          sshPort: config.sshPort,
          apiPort: config.port,
        },
        issues,
      };
    } catch (error) {
      return {
        success: false,
        error: (error as Error).message,
      };
    }
  })

  /**
   * Sync UFW with config (WARNING: modifies firewall)
   * POST /admin/config/sync-ufw
   */
  .post('/sync-ufw', async ({ set }) => {
    const config = getConfig();
    const { execSync } = require('node:child_process');

    try {
      // Get current UFW status (requires sudo)
      const ufwStatus = execSync('sudo ufw status', { encoding: 'utf-8' });
      const isActive = ufwStatus.includes('Status: active');

      if (!isActive) {
        return {
          success: false,
          error: 'UFW is not active. Enable UFW first.',
          hint: 'Run: sudo ufw enable',
        };
      }

      const actions: string[] = [];

      // Ensure SSH port is allowed
      if (!ufwStatus.includes(`${config.sshPort}/tcp`)) {
        execSync(`sudo ufw allow ${config.sshPort}/tcp`, { encoding: 'utf-8' });
        actions.push(`Added UFW rule for SSH port ${config.sshPort}`);
      }

      // Ensure API port is allowed
      if (!ufwStatus.includes(`${config.port}/tcp`)) {
        execSync(`sudo ufw allow ${config.port}/tcp`, { encoding: 'utf-8' });
        actions.push(`Added UFW rule for API port ${config.port}`);
      }

      return {
        success: true,
        message: 'UFW synchronized with config',
        actions,
        config: {
          sshPort: config.sshPort,
          apiPort: config.port,
        },
      };
    } catch (error) {
      set.status = 500;
      return {
        success: false,
        error: (error as Error).message,
      };
    }
  });

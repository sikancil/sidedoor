import { randomBytes } from 'node:crypto';
import { promises as fs } from 'node:fs';
import { DEFAULT_CONFIG } from './constants';

// Re-export constants for convenience
export { DEFAULT_CONFIG, generateUsername } from './constants';

export interface Config {
  port: number;
  sshPort: number;
  authenticatorToken: string;
  cronSecret?: string;
  chrootBasePath: string;
  dbPath: string;
  configPath: string;

  // Defaults for certificate creation
  defaultDirectories: readonly string[];
  defaultPermissions: readonly string[];
  defaultTtl: number;

  // Legacy field (deprecated, kept for backward compatibility)
  allowedDirectories: string[];

  // Service user (for running the service, NOT for certificates)
  user?: {
    name: string;
    group: string;
  };
}

let config: Config | null = null;

export async function loadConfig(configPath: string = DEFAULT_CONFIG.configPath): Promise<Config> {
  if (config) {
    return config;
  }

  try {
    let content = '{}';
    try {
      content = await fs.readFile(configPath, 'utf-8');
    } catch {
      // File doesn't exist, use empty config
      console.warn(`Config file not found at ${configPath}. Using defaults.`);
    }

    const userConfig = JSON.parse(content);

    config = {
      port: userConfig.port ?? DEFAULT_CONFIG.port,
      sshPort: userConfig.sshPort ?? DEFAULT_CONFIG.sshPort,
      authenticatorToken: userConfig.authenticatorToken ?? DEFAULT_CONFIG.authenticatorToken,
      cronSecret: userConfig.cronSecret ?? process.env.CRON_SECRET,
      chrootBasePath: userConfig.chrootBasePath ?? DEFAULT_CONFIG.chrootBasePath,
      dbPath: userConfig.dbPath ?? DEFAULT_CONFIG.dbPath,
      configPath,

      // Certificate creation defaults
      defaultDirectories: userConfig.defaultDirectories ?? DEFAULT_CONFIG.defaultDirectories,
      defaultPermissions: userConfig.defaultPermissions ?? DEFAULT_CONFIG.defaultPermissions,
      defaultTtl: userConfig.defaultTtl ?? DEFAULT_CONFIG.defaultTtl,

      // Legacy field (deprecated, kept for backward compatibility)
      allowedDirectories: userConfig.allowedDirectories ?? DEFAULT_CONFIG.allowedDirectories,

      // Service user (optional, for running the sidedoor service)
      user: userConfig.user ?? DEFAULT_CONFIG.user,
    };

    // Validate ports
    if (config.port < 1 || config.port > 65535) {
      throw new Error(`Invalid API port: ${config.port}. Must be between 1-65535.`);
    }
    if (config.sshPort < 1 || config.sshPort > 65535) {
      throw new Error(`Invalid SSH port: ${config.sshPort}. Must be between 1-65535.`);
    }

    // Warning if using defaults
    if (userConfig.port === undefined) {
      console.warn('⚠️  Using default API port (3000). Set "port" in config.json to customize.');
    }
    if (userConfig.sshPort === undefined) {
      console.warn('⚠️  Using default SSH port (22). Set "sshPort" in config.json to customize.');
    }

    // Validate authenticator token (only if explicitly set)
    if (userConfig.authenticatorToken && userConfig.authenticatorToken.length < 32) {
      throw new Error('authenticatorToken must be at least 32 characters long');
    }

    // Generate token if not set (development mode)
    if (!config.authenticatorToken) {
      config.authenticatorToken = generateDefaultToken();
      console.warn(
        '⚠️  WARNING: Using auto-generated authenticator token. Set a secure token in production!'
      );
    }

    return config;
  } catch (error) {
    if ((error as { code?: string }).code === 'ENOENT') {
      console.warn(`Config file not found at ${configPath}. Using defaults.`);
      config = { ...DEFAULT_CONFIG, authenticatorToken: generateDefaultToken() };
      return config;
    }
    throw error;
  }
}

function generateDefaultToken(): string {
  return randomBytes(32).toString('base64').slice(0, 32);
}

export function getConfig(): Config {
  if (!config) {
    throw new Error('Config not loaded. Call loadConfig() first.');
  }
  return config;
}

export async function reloadConfig(configPath?: string): Promise<Config> {
  config = null;
  return loadConfig(configPath ?? DEFAULT_CONFIG.configPath);
}

/**
 * Auto-recreate config if missing with fallback to defaults
 * This is useful for production deployments where config may not exist yet
 */
export async function ensureConfig(
  configPath: string = DEFAULT_CONFIG.configPath
): Promise<Config> {
  try {
    return await loadConfig(configPath);
  } catch (error) {
    if ((error as { code?: string }).code === 'ENOENT') {
      console.warn(`⚠️  Config file not found at ${configPath}. Creating with defaults...`);
      await createDefaultConfig(configPath);
      return await loadConfig(configPath);
    }
    throw error;
  }
}

/**
 * Create default config file with secure tokens
 * In production, generates secure random tokens
 * In development, uses predictable defaults
 */
async function createDefaultConfig(configPath: string): Promise<void> {
  const isProduction = configPath.includes('/etc/sidedoor/');

  const defaultConfig = {
    port: 3000,
    sshPort: 22,
    authenticatorToken: isProduction
      ? randomBytes(48).toString('base64').slice(0, 64)
      : 'dev-token-change-in-production-min-32-chars',
    cronSecret: isProduction
      ? randomBytes(48).toString('base64').slice(0, 64)
      : 'dev-secret-change-in-production-min-32-chars',
    chrootBasePath: '/home/sftp',
    dbPath: isProduction ? '/var/lib/sidedoor/certificates.db' : './data/certificates.db',
    configPath,
    defaultDirectories: ['/srv', '/var/www', '/data/uploads'],
    defaultPermissions: ['read-write-modify'],
    defaultTtl: 600,
    user: {
      name: 'sidedoor',
      group: 'www-data',
    },
    _generated: new Date().toISOString(),
    _autoCreated: true,
  };

  // Ensure directory exists
  const dir = configPath.substring(0, configPath.lastIndexOf('/'));
  await fs.mkdir(dir, { recursive: true });

  // Write config
  await fs.writeFile(configPath, JSON.stringify(defaultConfig, null, 2));
  console.log(`✅ Created config file at ${configPath}`);

  if (isProduction && defaultConfig._autoCreated) {
    console.warn(`⚠️  IMPORTANT: Save these tokens securely:`);
    console.warn(`   Authenticator Token: ${defaultConfig.authenticatorToken}`);
    console.warn(`   Cron Secret: ${defaultConfig.cronSecret}`);
  }
}

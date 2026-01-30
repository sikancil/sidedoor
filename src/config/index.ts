import { randomBytes } from 'node:crypto';
import { promises as fs } from 'node:fs';
import { DEFAULT_CONFIG } from './constants';

// Re-export constants for convenience
export { DEFAULT_CONFIG, generateUsername } from './constants';

export interface Config {
  port: number;
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

    // Validate authenticator token (only if explicitly set)
    if (userConfig.authenticatorToken && userConfig.authenticatorToken.length < 32) {
      throw new Error('authenticatorToken must be at least 32 characters long');
    }

    // Generate token if not set (development mode)
    if (!config.authenticatorToken) {
      config.authenticatorToken = generateDefaultToken();
      console.warn('⚠️  WARNING: Using auto-generated authenticator token. Set a secure token in production!');
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

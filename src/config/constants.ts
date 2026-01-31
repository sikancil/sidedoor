// Constants for the Sidedoor API - SSH/SFTP Certificate Management Service
import { customAlphabet } from 'nanoid';

// Username generation for dynamic users
// Format: n0x + 6 hex chars = 9 total characters (e.g., n0x1a2b3c)
// - 'n' letter prefix (valid Linux username start char)
// - '0x' literal hex identifier for visual clarity
// - 6 hex characters (16^6 = 16,777,216 possible combinations)
export const USERNAME_PREFIX = 'n0x';
export const USERNAME_ALPHABET = '0123456789abcdef';
export const USERNAME_HEX_LENGTH = 6; // Number of hex chars after prefix
export const USERNAME_TOTAL_LENGTH = 9; // n0x + 6 hex = 9 total

// Create a custom nanoid generator for hex-like usernames
const generateHexId = customAlphabet(USERNAME_ALPHABET, USERNAME_HEX_LENGTH);

/**
 * Generate a unique username in format n0x###### (9 characters total)
 * Uses nanoid with custom alphabet for hex characters only
 *
 * Format breakdown:
 * - n: Letter prefix (required by Linux - usernames cannot start with digits)
 * - 0x: Literal hex identifier for visual clarity
 * - ######: 6 hex characters (a-f, 0-9)
 *
 * Examples: n0x1a2b3c, n0x9f8e7d, n0xdead00
 *
 * @returns Username string (e.g., "n0x1a2b3c")
 */
export function generateUsername(): string {
  return USERNAME_PREFIX + generateHexId();
}

// Default configuration values
export const DEFAULT_CONFIG = {
  port: 3000,
  sshPort: 22, // SSH/SFTP port for UFW configuration
  authenticatorToken: '',
  chrootBasePath: '/home/sftp', // Base path for dynamic user chroots
  dbPath: '/var/lib/sidedoor/certificates.db',
  configPath: '/etc/sidedoor/config.json',
  cronSecret: process.env.CRON_SECRET || 'change-me-in-production',

  // NEW: Default values for certificate creation
  defaultDirectories: ['/srv', '/var/www', '/data/uploads'] as const,
  defaultPermissions: ['read-write-modify'] as const,
  defaultTtl: 600, // 10 minutes (in seconds)

  // Legacy field (deprecated, kept for migration)
  allowedDirectories: [] as string[],

  // Service user (optional, for running the sidedoor service)
  user: {
    name: 'sidedoor',
    group: 'www-data',
  },
} as const;

// SSH Configuration paths
export const SSH_CONFIG_PATH = '/etc/ssh/sshd_config.d/sidedoor.conf';
export const AUTH_LOG_PATH = '/var/log/auth.log';
export const AUTH_LOG_PATH_ALT = '/var/log/secure';

// ip-api.com integration
export const IP_API_BATCH_URL = 'http://ip-api.com/batch';
export const IP_API_SINGLE_URL = 'http://ip-api.com/json';
export const IP_API_RATE_LIMIT_DELAY = 4000; // 4 seconds between batch requests
export const IP_API_MAX_BATCH_SIZE = 100;

// Certificate generation
export const CERTIFICATE_ID_LENGTH = 12;

// File permissions (octal)
export const PRIVATE_KEY_PERMISSIONS = 0o600;
export const DIRECTORY_PERMISSIONS = 0o755;
export const UPLOADS_PERMISSIONS = 0o775;

// TTL limits
export const MIN_TTL = 60; // 1 minute
export const MAX_TTL = 86400; // 24 hours
export const DEFAULT_TTL = 600; // 10 minutes

// Permission types
export const PERMISSION_TYPES = [
  'sftp',
  'ssh',
  'read-only',
  'read-write',
  'read-write-modify',
] as const;
export type PermissionType = (typeof PERMISSION_TYPES)[number];

// Certificate status
export const CERTIFICATE_STATUS = ['active', 'expired', 'revoked'] as const;
export type CertificateStatus = (typeof CERTIFICATE_STATUS)[number];

// Access log status
export const ACCESS_LOG_STATUS = ['success', 'failed'] as const;
export type AccessLogStatus = (typeof ACCESS_LOG_STATUS)[number];

// Response types
export const RESPONSE_TYPES = ['md', 'cert'] as const;
export type ResponseType = (typeof RESPONSE_TYPES)[number];

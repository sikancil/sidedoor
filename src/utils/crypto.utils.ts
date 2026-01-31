import { mkdirSync, existsSync, chmodSync } from 'node:fs';
import { promises as fs } from 'node:fs';
import { PRIVATE_KEY_PERMISSIONS } from '../config/constants';

export interface KeyPairResult {
  publicKey: string;
  privateKey: string;
  privateKeyPath: string;
}

export interface SSHKeyGenResult {
  success: boolean;
  publicKey?: string;
  privateKeyPath?: string;
  error?: string;
}

/**
 * Generates an Ed25519 SSH key pair for a certificate and writes the keys to disk.
 *
 * @param certificateId - Identifier used as the key filename and comment (also treated as the username)
 * @param outputDir - Directory under which a per-certificate subdirectory will be created to store the keys
 * @returns An object containing the public key (trimmed), the private key contents, and the private key file path
 * @throws Error if ssh-keygen fails to generate the key pair
 */
export async function generateSSHKeyPair(
  certificateId: string,
  outputDir: string
): Promise<KeyPairResult> {
  const keyDir = `${outputDir}/${certificateId}`;

  // Create directory
  ensureDirectory(keyDir);

  // Use certificate ID (which is the username) for the key filename
  const privateKeyPath = `${keyDir}/${certificateId}_ed25519`;
  const publicKeyPath = `${privateKeyPath}.pub`;

  // Generate Ed25519 key pair using ssh-keygen
  const proc = Bun.spawn(
    [
      'ssh-keygen',
      '-t',
      'ed25519',
      '-f',
      privateKeyPath,
      '-N',
      '', // No passphrase
      '-C',
      `certificate-${certificateId}`,
    ],
    {
      stdout: 'pipe',
      stderr: 'pipe',
    }
  );

  const exitCode = await proc.exited;
  const stderr = await new Response(proc.stderr).text();

  if (exitCode !== 0) {
    throw new Error(`Failed to generate SSH key pair: ${stderr}`);
  }

  // Set private key permissions to 600
  chmodSync(privateKeyPath, PRIVATE_KEY_PERMISSIONS);

  // Read public key and private key
  const [publicKeyContent, privateKeyContent] = await Promise.all([
    fs.readFile(publicKeyPath, 'utf-8'),
    fs.readFile(privateKeyPath, 'utf-8'),
  ]);

  return {
    publicKey: publicKeyContent.trim(),
    privateKey: privateKeyContent,
    privateKeyPath,
  };
}

/**
 * Creates the directory at the given path if it does not already exist.
 *
 * @param path - Filesystem path to create; parent directories will be created recursively as needed
 */
export function ensureDirectory(path: string): void {
  if (!existsSync(path)) {
    mkdirSync(path, { recursive: true });
  }
}

/**
 * Ensures a private key string is wrapped with OpenSSH PEM headers if they are missing.
 *
 * @param privateKey - The private key material, which may already include PEM/OpenSSH headers
 * @returns The private key string guaranteed to include `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----` headers
 */
export function formatPrivateKey(privateKey: string): string {
  // Ensure proper PEM formatting
  const lines = privateKey.split('\n').filter((line) => line.trim());
  if (lines.length === 0 || !lines[0]!.startsWith('-----BEGIN')) {
    return `-----BEGIN OPENSSH PRIVATE KEY-----\n${privateKey}\n-----END OPENSSH PRIVATE KEY-----`;
  }
  return privateKey;
}

/**
 * Extracts the SSH public key type from a public key string.
 *
 * @param publicKey - Public key in OpenSSH format (e.g., "ssh-ed25519 AAAA... [comment]")
 * @returns The key type (e.g., `ssh-ed25519`); returns `ssh-ed25519` if the type cannot be determined.
 */
export function extractPublicKeyType(publicKey: string): string {
  const parts = publicKey.trim().split(' ');
  return parts[0] || 'ssh-ed25519';
}

/**
 * Compute a future Date by adding a time-to-live interval to the current time.
 *
 * @param ttl - Time-to-live in seconds to add to the current time
 * @returns A Date representing now plus `ttl` seconds
 */
export function calculateExpiresAt(ttl: number): Date {
  // Calculate expiration time using milliseconds (TTL is in seconds)
  return new Date(Date.now() + ttl * 1000);
}

/**
 * Checks whether a timestamp is in the past.
 *
 * @param expiresAt - A date-time string parseable by the JavaScript Date constructor (commonly an ISO 8601 timestamp).
 * @returns `true` if `expiresAt` is earlier than the current time, `false` otherwise.
 */
export function isExpired(expiresAt: string): boolean {
  return new Date(expiresAt) < new Date();
}

/**
 * Format an array of permission strings into a comma-separated list.
 *
 * @param permissions - Array of permission identifiers or names
 * @returns A single string with permissions joined by a comma and a space (`, `)
 */
export function formatPermissions(permissions: string[]): string {
  return permissions.join(', ');
}

/**
 * Parses a JSON-encoded array of permission strings.
 *
 * @param permissionsJson - JSON string representing an array of permission identifiers (for example, '["read","write"]')
 * @returns The parsed array of permission strings, or an empty array if parsing fails or the input is not valid JSON
 */
export function parsePermissions(permissionsJson: string): string[] {
  try {
    return JSON.parse(permissionsJson);
  } catch {
    return [];
  }
}
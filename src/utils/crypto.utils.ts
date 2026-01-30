import { mkdirSync, existsSync, chmodSync } from 'node:fs';
import { promises as fs } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { PRIVATE_KEY_PERMISSIONS, CERTIFICATE_ID_LENGTH } from '../config/constants';

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
  const proc = Bun.spawn([
    'ssh-keygen',
    '-t', 'ed25519',
    '-f', privateKeyPath,
    '-N', '', // No passphrase
    '-C', `certificate-${certificateId}`,
  ], {
    stdout: 'pipe',
    stderr: 'pipe',
  });

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

export function ensureDirectory(path: string): void {
  if (!existsSync(path)) {
    mkdirSync(path, { recursive: true });
  }
}

export function formatPrivateKey(privateKey: string): string {
  // Ensure proper PEM formatting
  const lines = privateKey.split('\n').filter(line => line.trim());
  if (!lines[0].startsWith('-----BEGIN')) {
    return `-----BEGIN OPENSSH PRIVATE KEY-----\n${privateKey}\n-----END OPENSSH PRIVATE KEY-----`;
  }
  return privateKey;
}

export function extractPublicKeyType(publicKey: string): string {
  const parts = publicKey.trim().split(' ');
  return parts[0] || 'ssh-ed25519';
}

export function calculateExpiresAt(ttl: number): string {
  const now = new Date();
  now.setSeconds(now.getSeconds() + ttl);
  return now.toISOString();
}

export function isExpired(expiresAt: string): boolean {
  return new Date(expiresAt) < new Date();
}

export function formatPermissions(permissions: string[]): string {
  return permissions.join(', ');
}

export function parsePermissions(permissionsJson: string): string[] {
  try {
    return JSON.parse(permissionsJson);
  } catch {
    return [];
  }
}

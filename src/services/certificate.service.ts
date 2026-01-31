import { promises as fs } from 'node:fs';
import { getCertificateModel, type Certificate, type AccessLog } from '../models/Certificate.model';
import { generateSSHKeyPair, ensureDirectory, calculateExpiresAt } from '../utils/crypto.utils';
import { generateReadmeMarkdown } from '../utils/markdown.utils';
import { getSSHService } from './ssh.service';
import { getGeolocationService } from './geolocation.service';
import { getSystemdService } from './systemd.service';
import { getConfig } from '../config';
import { generateUsername, DEFAULT_CONFIG } from '../config/constants';

// Types for certificate creation request
export interface CertificateCreateRequest {
  directoryPath?: string;
  permissions?: string[];
  ttl?: number;
  responseType?: 'md' | 'cert';
  authenticatorToken?: string;
}

export interface CertificateResponse {
  id: string;
  username: string; // Dynamic: n0x###### format (9 chars, e.g., n0x1a2b3c)
  directoryPath: string;
  permissions: string[];
  ttl: number;
  status: string;
  createdAt: string;
  expiresAt: string;
  publicKey: string;
  privateKeyPath: string;
  readmePath: string;
  // Only included for responseType: "cert"
  privateKey?: string;
  readme?: string;
}

export interface CertificateResponseWithLocation extends CertificateResponse {
  lastAccessLocation?: string;
}

export interface CertificateResponseWithHistory extends CertificateResponse {
  accessLogs: AccessLog[];
}

export interface CertificateResponseWithMarkdown extends CertificateResponse {
  readme: string; // Full markdown content
}

export class CertificateService {
  private config = getConfig();

  /**
   * Create a new certificate
   * Each certificate gets a unique dynamic user (n0x###### format, 9 characters) with per-certificate systemd timer
   * Format: n0x + 6 hex chars (e.g., n0x1a2b3c, n0x9f8e7d)
   */
  async createCertificate(request: CertificateCreateRequest): Promise<CertificateResponse | CertificateResponseWithMarkdown> {
    // Apply defaults from config for optional fields
    const directoryPath = request.directoryPath ?? this.config.defaultDirectories[0];
    const permissions = request.permissions ?? Array.from(this.config.defaultPermissions);
    const ttl = request.ttl ?? this.config.defaultTtl;
    const responseType = request.responseType ?? 'md';

    // Generate dynamic username (n0x + 6 hex chars = 9 total)
    const username = generateUsername(); // e.g., n0x1a2b3c
    const id = username; // Use username as certificate ID
    const expiresAt = calculateExpiresAt(ttl); // Returns Date object
    const expiresAtString = expiresAt.toISOString(); // For database storage
    const keysDir = './data/certificates';

    await ensureDirectory(keysDir);

    // Generate SSH key pair
    const { publicKey, privateKey, privateKeyPath } = await generateSSHKeyPair(id, keysDir);

    // Create user with chroot
    await getSSHService().createUserWithChroot(username);

    // Create bind mount for target directory
    const mountPoint = directoryPath; // /srv → /home/sftp/n0x1a2b3c/srv
    await getSSHService().createBindMount(username, directoryPath, mountPoint);

    // Add public key to user's authorized_keys
    await getSSHService().addPublicKey(username, publicKey);

    // Configure SSH chroot for dynamic users (one-time)
    await getSSHService().configureSSHChroot();

    // Create systemd timer for cleanup (skip in dev mode)
    const skipSystemd = process.env.SKIP_SYSTEMD === 'true';
    if (!skipSystemd) {
      await getSystemdService().createCleanupTimer({
        username,
        expiresAt,
        cleanupEndpoint: `/admin/cleanup/${username}`,
      });
    } else {
      console.log(`⚠️  DEV MODE: Skipping systemd timer creation for ${username}`);
    }

    // Create README
    const readmePath = `${keysDir}/${id}/README.md`;
    const readmeContent = generateReadmeMarkdown({
      certificate: {
        id,
        username,
        directory_path: directoryPath,
        permissions: JSON.stringify(permissions),
        ttl,
        status: 'active',
        created_at: new Date().toISOString(),
        expires_at: expiresAtString,
        authenticator_token: request.authenticatorToken || '',
        public_key: publicKey,
        private_key_path: privateKeyPath,
      },
      username,
      privateKeyPath: `${username}_ed25519`,
      instructions: this.generateInstructions(directoryPath, permissions, username),
    });
    await fs.writeFile(readmePath, readmeContent);

    // Create certificate record
    const certificate = getCertificateModel().create({
      id,
      username,
      directory_path: directoryPath,
      mount_points: JSON.stringify([`/home/sftp/${username}${mountPoint}`]),
      permissions: JSON.stringify(permissions),
      ttl,
      status: 'active',
      created_at: new Date().toISOString(),
      expires_at: expiresAtString,
      authenticator_token: request.authenticatorToken || '',
      public_key: publicKey,
      private_key_path: privateKeyPath,
      readme_path: readmePath,
      systemd_timer_name: skipSystemd ? null : `sidedoor-${username}`,
      systemd_timer_created_at: skipSystemd ? null : new Date().toISOString(),
    });

    // Return based on responseType
    if (responseType === 'cert') {
      return {
        ...this.toResponse(certificate),
        privateKey,
        readme: readmeContent,
      };
    }

    // Default: "md" - return with markdown
    return {
      ...this.toResponse(certificate),
      readme: readmeContent,
    };
  }

  /**
   * Get all certificates with geolocation
   */
  async getAllCertificates(): Promise<CertificateResponseWithLocation[]> {
    // Mark expired certificates
    getCertificateModel().markExpired();

    const certificates = getCertificateModel().findAll();

    // Get unique IPs for batch lookup
    const ips = certificates
      .map(cert => cert.last_access_ip)
      .filter((ip): ip is string => ip != null && !getGeolocationService().isPrivateIP(ip));

    const geolocations = ips.length > 0
      ? await getGeolocationService().getBatchGeolocation(ips)
      : [];

    const ipToLocation = new Map<string, string>();
    geolocations.forEach((geo, index) => {
      if (geo && ips[index]) {
        ipToLocation.set(ips[index], getGeolocationService().formatLocation(geo).full);
      }
    });

    return certificates.map(cert => ({
      ...this.toResponse(cert),
      lastAccessLocation: cert.last_access_ip
        ? ipToLocation.get(cert.last_access_ip)
        : undefined,
    }));
  }

  /**
   * Get single certificate with full access log history
   */
  async getCertificate(id: string): Promise<CertificateResponseWithHistory> {
    const certificate = getCertificateModel().findById(id);
    if (!certificate) {
      throw new Error(`Certificate not found: ${id}`);
    }

    const accessLogs = getCertificateModel().findAccessLogsByCertificateId(id);

    // Enrich access logs with geolocation if missing
    const ipsWithoutGeo = accessLogs
      .filter(log => !log.country && log.ip_address)
      .map(log => log.ip_address)
      .filter((ip): ip is string => !getGeolocationService().isPrivateIP(ip));

    if (ipsWithoutGeo.length > 0) {
      const geolocations = await getGeolocationService().getBatchGeolocation(ipsWithoutGeo);

      const updates = geolocations
        .map((geo, index) => {
          if (!geo || geo.status !== 'success') {
            return null;
          }
          const log = accessLogs.find(l => l.ip_address === ipsWithoutGeo[index]);
          if (!log) {
            return null;
          }
          return {
            id: log.id,
            country: geo.country,
            region: geo.region,
            city: geo.city,
            lat: geo.lat,
            lon: geo.lon,
            isp: geo.isp,
          };
        })
        .filter((u): u is NonNullable<typeof u> => u != null);

      if (updates.length > 0) {
        getCertificateModel().batchUpdateGeolocation(updates);
      }
    }

    return {
      ...this.toResponse(certificate),
      accessLogs,
    };
  }

  /**
   * Update certificate
   */
  async updateCertificate(id: string, updates: {
    ttl?: number;
    permissions?: string[];
    status?: string;
  }): Promise<CertificateResponse> {
    const certificate = getCertificateModel().findById(id);
    if (!certificate) {
      throw new Error(`Certificate not found: ${id}`);
    }

    const updateData: Partial<Record<string, unknown>> = {};

    if (updates.ttl !== undefined) {
      const newExpiresAt = calculateExpiresAt(updates.ttl);
      updateData.expires_at = newExpiresAt.toISOString();
      updateData.ttl = updates.ttl;
    }

    if (updates.permissions !== undefined) {
      updateData.permissions = JSON.stringify(updates.permissions);
    }

    if (updates.status !== undefined) {
      updateData.status = updates.status;

      // Handle revocation - remove SSH key from authorized_keys
      if (updates.status === 'revoked') {
        await this.revokeCertificate(certificate);
        return this.toResponse(certificate);
      }
    }

    const updated = getCertificateModel().update(id, updateData);
    if (!updated) {
      throw new Error(`Failed to update certificate: ${id}`);
    }

    return this.toResponse(updated);
  }

  /**
   * Delete certificate and revoke access
   * Cleans up user, chroot, bind mounts, and systemd timer
   */
  async deleteCertificate(id: string): Promise<void> {
    const certificate = getCertificateModel().findById(id);
    if (!certificate) {
      throw new Error(`Certificate not found: ${id}`);
    }

    // Delete systemd timer if exists
    await getSystemdService().deleteCleanupTimer(certificate.username);

    // Unmount bind mounts
    const mountPoints = JSON.parse(certificate.mount_points || '[]');
    for (const mount of mountPoints) {
      await getSSHService().unmountBindMount(mount);
    }

    // Delete user and chroot
    await getSSHService().deleteUserWithChroot(certificate.username);

    // Delete certificate record
    getCertificateModel().delete(id);
  }

  /**
   * Get private key content
   */
  async getPrivateKey(id: string): Promise<string> {
    const certificate = getCertificateModel().findById(id);
    if (!certificate) {
      throw new Error(`Certificate not found: ${id}`);
    }

    const keyContent = await fs.readFile(certificate.private_key_path || '', 'utf-8');
    return keyContent;
  }

  /**
   * Get README content
   */
  async getReadme(id: string): Promise<string> {
    const certificate = getCertificateModel().findById(id);
    if (!certificate) {
      throw new Error(`Certificate not found: ${id}`);
    }

    const readmeContent = await fs.readFile(certificate.readme_path || '', 'utf-8');
    return readmeContent;
  }

  /**
   * Get README as both markdown and HTML
   */
  async getReadmeContent(id: string): Promise<{ markdown: string; html: string }> {
    const markdown = await this.getReadme(id);
    const html = this.markdownToHtml(markdown);
    return { markdown, html };
  }

  /**
   * Revoke certificate - remove SSH key from authorized_keys
   */
  private async revokeCertificate(certificate: Certificate): Promise<void> {
    const sshService = getSSHService();
    const publicKey = certificate.public_key;

    // Remove the public key from authorized_keys
    await sshService.removePublicKey(certificate.username, publicKey);
  }

  /**
   * Generate instructions for README
   */
  private generateInstructions(directoryPath: string, permissions: string[], username?: string): string {
    const dirInfo = this.getDirectoryInfo(directoryPath);
    const permInfo = this.getPermissionInfo(permissions);

    return `
## Directory Access

You have access to: **${directoryPath}**

**Directory Type:** ${dirInfo.type}
**Permissions:** ${permInfo.description}

${this.generatePermissionTable(permissions)}

## Security Notes

- You are accessing as user: **${username || 'n0x######'}** (dynamic user)
- Session is limited to the chroot environment
- Certificate will expire automatically
- Systemd timer will clean up resources on expiration

${this.getTroubleshootingInfo()}
`;
  }

  private getDirectoryInfo(path: string): { type: string; description: string } {
    if (path.startsWith('/srv/')) {
      return { type: 'Service Directory', description: 'Standard Linux service directory' };
    }
    if (path.startsWith('/var/www/')) {
      return { type: 'Web Root', description: 'Web server root directory' };
    }
    if (path.startsWith('/home/')) {
      return { type: 'Home Directory', description: 'User home directory' };
    }
    if (path.startsWith('/tmp/') || path.startsWith('/var/tmp/')) {
      return { type: 'Temporary Directory', description: 'Temporary storage' };
    }
    return { type: 'Custom Directory', description: 'Custom directory path' };
  }

  private getPermissionInfo(permissions: string[]): { description: string } {
    if (permissions.includes('read-write-modify') || permissions.includes('read-write')) {
      return { description: 'Full access: read, write, modify, delete' };
    }
    if (permissions.includes('read-only')) {
      return { description: 'Read-only: view and download only' };
    }
    return { description: 'Access as per permissions' };
  }

  private generatePermissionTable(permissions: string[]): string {
    const rows: string[] = [];

    if (permissions.includes('sftp')) {
      rows.push('| **SFTP** | ✅ Enabled | File transfer protocol |');
    }
    if (permissions.includes('ssh')) {
      rows.push('| **SSH** | ✅ Enabled | Shell access |');
    }
    if (permissions.includes('read-only')) {
      rows.push('| **Read-Only** | ✅ Enabled | View/download only |');
    }
    if (permissions.includes('read-write')) {
      rows.push('| **Read-Write** | ✅ Enabled | Create/modify/delete |');
    }
    if (permissions.includes('read-write-modify')) {
      rows.push('| **Read-Write-Modify** | ✅ Enabled | Full file access |');
    }

    if (rows.length === 0) {
      rows.push('| - | - | No special permissions |');
    }

    return `
### Permissions Overview

${rows.join('\n')}
`;
  }

  private getTroubleshootingInfo(): string {
    return `
## Troubleshooting

### Connection Issues
\`\`\`bash
# Fix private key permissions
chmod 600 your_key_file

# Verbose connection for debugging
sftp -v -i your_key_file <username>@<server-ip>
\`\`\`

### Permission Denied
- Verify certificate has not expired
- Check that the directory exists on the server
- Ensure your IP is whitelisted if applicable

### Still Having Issues?
Contact your system administrator with your Certificate ID.
`;
  }

  /**
   * Convert database model to response
   */
  private toResponse(certificate: Certificate): CertificateResponse {
    return {
      id: certificate.id,
      username: certificate.username,
      directoryPath: certificate.directory_path,
      permissions: JSON.parse(certificate.permissions),
      ttl: certificate.ttl,
      status: certificate.status,
      createdAt: certificate.created_at,
      expiresAt: certificate.expires_at,
      publicKey: certificate.public_key,
      privateKeyPath: certificate.private_key_path || '',
      readmePath: certificate.readme_path || '',
    };
  }

  /**
   * Simple markdown to HTML converter
   */
  private markdownToHtml(markdown: string): string {
    return markdown
      .replace(/^### (.*$)/gim, '<h3>$1</h3>')
      .replace(/^## (.*$)/gim, '<h2>$1</h2>')
      .replace(/^# (.*$)/gim, '<h1>$1</h1>')
      .replace(/\*\*(.*?)\*\*/gim, '<strong>$1</strong>')
      .replace(/\*(.*?)\*/gim, '<em>$1</em>')
      .replace(/`(.*?)`/gim, '<code>$1</code>')
      .replace(/```bash\n([\s\S]*?)```/gim, '<pre><code class="bash">$1</code></pre>')
      .replace(/```([\s\S]*?)```/gim, '<pre><code>$1</code></pre>')
      .replace(/^- (.*$)/gim, '<li>$1</li>')
      .replace(/\n\n/g, '</p><p>')
      .replace(/\n/g, '<br>')
      .replace(/^/, '<p>')
      .replace(/$/, '</p>');
  }
}

// Lazy singleton instance
let _certificateServiceInstance: CertificateService | null = null;
export function getCertificateService(): CertificateService {
  if (!_certificateServiceInstance) {
    _certificateServiceInstance = new CertificateService();
  }
  return _certificateServiceInstance;
}

// Convenience export for backward compatibility
export const certificateService = new Proxy({} as CertificateService, {
  get(target, prop) {
    return getCertificateService()[prop as keyof CertificateService];
  }
});

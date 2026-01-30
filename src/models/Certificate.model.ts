import { randomBytes } from 'node:crypto';
import { getDatabase } from '../config/database';
import { CertificateStatus } from '../config/constants';

export interface Certificate {
  id: string;
  username: string; // Dynamic: n0x###### format (9 chars, e.g., n0x1a2b3c), unique per certificate
  directory_path: string;
  mount_points?: string; // JSON: ["/home/sftp/n0x1a2b3c/srv"]
  permissions: string; // JSON stringified array
  ttl: number;
  status: CertificateStatus;
  created_at: string;
  expires_at: string;
  authenticator_token: string;
  public_key: string;
  private_key_path?: string;
  readme_path?: string;
  last_access_at?: string;
  last_access_ip?: string;
  // Systemd timer tracking
  systemd_timer_name?: string;
  systemd_timer_created_at?: string;
  systemd_timer_fired_at?: string;
  // Forensic tracking
  revoked_at?: string;
  revoked_by?: string;
  revoke_reason?: string;
  cleanup_log?: string;
  user_deleted?: number; // 0 or 1
  chroot_removed?: number; // 0 or 1
}

export interface AccessLog {
  id: string;
  certificate_id: string;
  username: string; // Dynamic: n0x###### format (9 chars)
  ip_address: string;
  timestamp: string;
  status: 'success' | 'failed';
  country?: string;
  region?: string;
  city?: string;
  lat?: number;
  lon?: number;
  isp?: string;
}

export interface CleanupLog {
  id: string;
  cleanup_run_id: string;
  certificate_id: string;
  username: string;
  timestamp: string;
  triggered_by: string; // 'systemd', 'manual', 'api'
  actions?: string; // JSON: list of actions
  errors?: string; // JSON: list of errors
  duration_ms?: number;
  forensic_data?: string; // JSON: full details
}

export interface CertificateWithGeolocation extends Certificate {
  last_access_location?: string;
}

export interface CertificateWithFullHistory extends Certificate {
  access_logs: AccessLog[];
}

export class CertificateModel {
  private db = getDatabase();

  constructor() {
    // Force database initialization on instance creation
    this.db = getDatabase();
  }

  generateId(): string {
    return randomBytes(6).toString('hex');
  }

  create(data: Omit<Certificate, 'id' | 'created_at'>): Certificate {
    const id = data.id || this.generateId();
    const created_at = new Date().toISOString();
    const permissions = typeof data.permissions === 'string'
      ? data.permissions
      : JSON.stringify(data.permissions);
    const mountPoints = typeof data.mount_points === 'string'
      ? data.mount_points
      : (data.mount_points ? JSON.stringify(data.mount_points) : null);

    const stmt = this.db.prepare(`
      INSERT INTO certificates (
        id, username, directory_path, mount_points, permissions, ttl, status,
        created_at, expires_at, authenticator_token, public_key,
        private_key_path, readme_path, last_access_at, last_access_ip,
        systemd_timer_name, systemd_timer_created_at, systemd_timer_fired_at,
        revoked_at, revoked_by, revoke_reason, cleanup_log,
        user_deleted, chroot_removed
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    stmt.run(
      id,
      data.username,
      data.directory_path,
      mountPoints,
      permissions,
      data.ttl,
      data.status,
      created_at,
      data.expires_at,
      data.authenticator_token,
      data.public_key,
      data.private_key_path ?? null,
      data.readme_path ?? null,
      data.last_access_at ?? null,
      data.last_access_ip ?? null,
      data.systemd_timer_name ?? null,
      data.systemd_timer_created_at ?? null,
      data.systemd_timer_fired_at ?? null,
      data.revoked_at ?? null,
      data.revoked_by ?? null,
      data.revoke_reason ?? null,
      data.cleanup_log ?? null,
      data.user_deleted ?? 0,
      data.chroot_removed ?? 0
    );

    return this.findById(id)!;
  }

  findById(id: string): Certificate | null {
    const stmt = this.db.prepare('SELECT * FROM certificates WHERE id = ?');
    return stmt.get(id) as Certificate | null;
  }

  findByUsername(username: string): Certificate | null {
    const stmt = this.db.prepare('SELECT * FROM certificates WHERE username = ?');
    return stmt.get(username) as Certificate | null;
  }

  /**
   * Find certificate by systemd timer name
   */
  findByTimerName(timerName: string): Certificate | null {
    const stmt = this.db.prepare('SELECT * FROM certificates WHERE systemd_timer_name = ?');
    return stmt.get(timerName) as Certificate | null;
  }

  findAll(options?: { limit?: number; offset?: number; status?: CertificateStatus }): Certificate[] {
    let query = 'SELECT * FROM certificates';
    const params: unknown[] = [];

    if (options?.status) {
      query += ' WHERE status = ?';
      params.push(options.status);
    }

    query += ' ORDER BY created_at DESC';

    if (options?.limit) {
      query += ' LIMIT ?';
      params.push(options.limit);
      if (options.offset) {
        query += ' OFFSET ?';
        params.push(options.offset);
      }
    }

    const stmt = this.db.prepare(query);
    return stmt.all(...params) as Certificate[];
  }

  update(id: string, data: Partial<Omit<Certificate, 'id' | 'username' | 'created_at'>>): Certificate | null {
    const updates: string[] = [];
    const params: unknown[] = [];

    Object.entries(data).forEach(([key, value]) => {
      if (value !== undefined) {
        updates.push(`${key} = ?`);
        params.push(value);
      }
    });

    if (updates.length === 0) {
      return this.findById(id);
    }

    params.push(id);
    const stmt = this.db.prepare(`
      UPDATE certificates
      SET ${updates.join(', ')}
      WHERE id = ?
    `);

    stmt.run(...params);
    return this.findById(id);
  }

  delete(id: string): boolean {
    const stmt = this.db.prepare('DELETE FROM certificates WHERE id = ?');
    const result = stmt.run(id);
    return result.changes > 0;
  }

  markExpired(): number {
    const stmt = this.db.prepare(`
      UPDATE certificates
      SET status = 'expired'
      WHERE status = 'active' AND datetime(expires_at) <= datetime('now')
    `);
    const result = stmt.run();
    return result.changes;
  }

  findExpired(): Certificate[] {
    const stmt = this.db.prepare(`
      SELECT * FROM certificates
      WHERE status = 'active' AND datetime(expires_at) <= datetime('now')
    `);
    return stmt.all() as Certificate[];
  }

  // Access Log methods
  createAccessLog(data: Omit<AccessLog, 'id' | 'timestamp' | 'username'> & { timestamp?: string; username?: string }): AccessLog {
    const id = randomBytes(8).toString('hex');
    const timestamp = data.timestamp || new Date().toISOString();
    const username = data.username || 'unknown';

    const stmt = this.db.prepare(`
      INSERT INTO access_logs (
        id, certificate_id, username, ip_address, timestamp, status,
        country, region, city, lat, lon, isp
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    stmt.run(
      id,
      data.certificate_id,
      username,
      data.ip_address,
      timestamp,
      data.status,
      data.country ?? null,
      data.region ?? null,
      data.city ?? null,
      data.lat ?? null,
      data.lon ?? null,
      data.isp ?? null
    );

    return { ...data, id, timestamp, username } as AccessLog;
  }

  // Cleanup Log methods
  createCleanupLog(data: Omit<CleanupLog, 'id' | 'timestamp'> & { timestamp?: string }): CleanupLog {
    const id = randomBytes(8).toString('hex');
    const timestamp = data.timestamp || new Date().toISOString();
    const actions = typeof data.actions === 'string' ? data.actions : JSON.stringify(data.actions || []);
    const errors = typeof data.errors === 'string' ? data.errors : JSON.stringify(data.errors || []);
    const forensicData = typeof data.forensic_data === 'string'
      ? data.forensic_data
      : JSON.stringify(data.forensic_data || {});

    const stmt = this.db.prepare(`
      INSERT INTO cleanup_logs (
        id, cleanup_run_id, certificate_id, username, timestamp, triggered_by,
        actions, errors, duration_ms, forensic_data
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    stmt.run(
      id,
      data.cleanup_run_id,
      data.certificate_id,
      data.username,
      timestamp,
      data.triggered_by,
      actions,
      errors,
      data.duration_ms ?? null,
      forensicData
    );

    return { ...data, id, timestamp } as CleanupLog;
  }

  findCleanupLogsByCertificateId(certificateId: string): CleanupLog[] {
    const stmt = this.db.prepare(`
      SELECT * FROM cleanup_logs
      WHERE certificate_id = ?
      ORDER BY timestamp DESC
    `);
    return stmt.all(certificateId) as CleanupLog[];
  }

  findAccessLogsByCertificateId(certificateId: string): AccessLog[] {
    const stmt = this.db.prepare(`
      SELECT * FROM access_logs
      WHERE certificate_id = ?
      ORDER BY timestamp DESC
    `);
    return stmt.all(certificateId) as AccessLog[];
  }

  findLatestAccessLogByCertificateId(certificateId: string): AccessLog | null {
    const stmt = this.db.prepare(`
      SELECT * FROM access_logs
      WHERE certificate_id = ? AND status = 'success'
      ORDER BY timestamp DESC
      LIMIT 1
    `);
    return stmt.get(certificateId) as AccessLog | null;
  }

  updateLastAccess(certificateId: string, ipAddress: string): void {
    const stmt = this.db.prepare(`
      UPDATE certificates
      SET last_access_at = datetime('now'),
          last_access_ip = ?
      WHERE id = ?
    `);
    stmt.run(ipAddress, certificateId);
  }

  findAccessLogsWithoutGeolocation(limit: number = 100): AccessLog[] {
    const stmt = this.db.prepare(`
      SELECT * FROM access_logs
      WHERE country IS NULL
      ORDER BY timestamp DESC
      LIMIT ?
    `);
    return stmt.all(limit) as AccessLog[];
  }

  batchUpdateGeolocation(updates: Array<{ id: string; country?: string; region?: string; city?: string; lat?: number; lon?: number; isp?: string }>): void {
    const stmt = this.db.prepare(`
      UPDATE access_logs
      SET country = ?, region = ?, city = ?, lat = ?, lon = ?, isp = ?
      WHERE id = ?
    `);

    const updateMany = this.db.transaction((logs) => {
      for (const log of logs) {
        stmt.run(
          log.country ?? null,
          log.region ?? null,
          log.city ?? null,
          log.lat ?? null,
          log.lon ?? null,
          log.isp ?? null,
          log.id
        );
      }
    });

    updateMany(updates);
  }

  /**
   * Find all certificates that have expired and need to be revoked
   * Returns certificates that should have their SSH keys removed
   */
  findCertificatesForRevocation(): Certificate[] {
    const stmt = this.db.prepare(`
      SELECT * FROM certificates
      WHERE status = 'active' AND datetime(expires_at) <= datetime('now')
    `);
    return stmt.all() as Certificate[];
  }
}

// Lazy singleton instance
let _certificateModelInstance: CertificateModel | null = null;
export function getCertificateModel(): CertificateModel {
  if (!_certificateModelInstance) {
    _certificateModelInstance = new CertificateModel();
  }
  return _certificateModelInstance;
}

// Convenience export for backward compatibility
export const certificateModel = new Proxy({} as CertificateModel, {
  get(target, prop) {
    return getCertificateModel()[prop as keyof CertificateModel];
  }
});

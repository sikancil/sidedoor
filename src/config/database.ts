import { Database } from 'bun:sqlite';
import { existsSync } from 'node:fs';
import { mkdirSync } from 'node:fs';
import { getConfig } from './index';
import { CERTIFICATE_STATUS, ACCESS_LOG_STATUS } from './constants';

let db: Database | null = null;

/**
 * Provide the application's singleton SQLite Database instance, initializing it if necessary.
 *
 * This function lazily creates and caches a Database connected to the configured path, ensures the database directory exists, applies required SQLite pragmas, and prepares or migrates the schema before returning the instance.
 *
 * @returns The cached or newly created Database instance
 */
export function getDatabase(): Database {
  if (db) {
    return db;
  }

  const config = getConfig();
  // Ensure data directory exists
  const dbPath = config.dbPath;
  const dbDir = dbPath.substring(0, dbPath.lastIndexOf('/'));
  if (!existsSync(dbDir)) {
    mkdirSync(dbDir, { recursive: true });
  }

  db = new Database(dbPath);
  db.exec('PRAGMA foreign_keys = ON');
  db.exec('PRAGMA journal_mode = WAL');

  initializeSchema(db);

  return db;
}

/**
 * Ensure the application's database schema exists and is migrated to the current version.
 *
 * Creates or updates the certificates, access_logs, and cleanup_logs tables (including required
 * columns, foreign key constraints, and CHECK constraints), creates performance indexes, and
 * conditionally runs the dynamic-user migration to add newer certificate columns when they are missing.
 *
 * @param database - The SQLite Database instance to initialize or migrate
 */
function initializeSchema(database: Database): void {
  // Check if we need to run migration
  const hasNewColumns = database
    .prepare(
      `
    PRAGMA table_info(certificates)
  `
    )
    .all()
    .some((row: any) => row.name === 'mount_points');

  if (!hasNewColumns) {
    // Run migration for dynamic users
    migrateToDynamicUsers(database);
  }

  // Certificates table (will be created/migrated)
  database.exec(`
    CREATE TABLE IF NOT EXISTS certificates (
      id TEXT PRIMARY KEY,
      username TEXT UNIQUE NOT NULL,
      directory_path TEXT NOT NULL,
      mount_points TEXT,
      permissions TEXT NOT NULL,
      ttl INTEGER NOT NULL,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      authenticator_token TEXT NOT NULL,
      public_key TEXT NOT NULL,
      private_key_path TEXT,
      readme_path TEXT,
      last_access_at TEXT,
      last_access_ip TEXT,
      systemd_timer_name TEXT,
      systemd_timer_created_at TEXT,
      systemd_timer_fired_at TEXT,
      revoked_at TEXT,
      revoked_by TEXT,
      revoke_reason TEXT,
      cleanup_log TEXT,
      user_deleted BOOLEAN DEFAULT 0,
      chroot_removed BOOLEAN DEFAULT 0,
      CHECK(status IN ('${CERTIFICATE_STATUS.join("','")}'))
    )
  `);

  // Access logs table
  database.exec(`
    CREATE TABLE IF NOT EXISTS access_logs (
      id TEXT PRIMARY KEY,
      certificate_id TEXT NOT NULL,
      username TEXT NOT NULL,
      ip_address TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      status TEXT NOT NULL,
      country TEXT,
      region TEXT,
      city TEXT,
      lat REAL,
      lon REAL,
      isp TEXT,
      FOREIGN KEY (certificate_id) REFERENCES certificates(id) ON DELETE CASCADE,
      CHECK(status IN ('${ACCESS_LOG_STATUS.join("','")}'))
    )
  `);

  // Cleanup logs table for forensic tracking
  database.exec(`
    CREATE TABLE IF NOT EXISTS cleanup_logs (
      id TEXT PRIMARY KEY,
      cleanup_run_id TEXT NOT NULL,
      certificate_id TEXT NOT NULL,
      username TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      triggered_by TEXT NOT NULL,
      actions TEXT,
      errors TEXT,
      duration_ms INTEGER,
      forensic_data TEXT,
      FOREIGN KEY (certificate_id) REFERENCES certificates(id)
    )
  `);

  // Indexes for better query performance
  database.exec(`
    CREATE INDEX IF NOT EXISTS idx_certificates_status ON certificates(status);
    CREATE INDEX IF NOT EXISTS idx_certificates_expires_at ON certificates(expires_at);
    CREATE INDEX IF NOT EXISTS idx_certificates_username ON certificates(username);
    CREATE INDEX IF NOT EXISTS idx_access_logs_certificate_id ON access_logs(certificate_id);
    CREATE INDEX IF NOT EXISTS idx_access_logs_timestamp ON access_logs(timestamp);
    CREATE INDEX IF NOT EXISTS idx_access_logs_ip_address ON access_logs(ip_address);
    CREATE INDEX IF NOT EXISTS idx_cleanup_logs_certificate_id ON cleanup_logs(certificate_id);
    CREATE INDEX IF NOT EXISTS idx_cleanup_logs_timestamp ON cleanup_logs(timestamp);
  `);
}

/**
 * Apply schema migrations to convert the database from a static-user model to a dynamic-user model.
 *
 * Attempts to add columns used for bind mounts, systemd timer tracking, revocation/forensics, and cleanup flags to the `certificates` table,
 * and ensures a unique index exists on `certificates(username)`. Existing columns or indexes are ignored to make the migration idempotent.
 *
 * @param database - The SQLite Database instance to migrate
 */
function migrateToDynamicUsers(database: Database): void {
  console.log('Running database migration for dynamic users...');

  // Add new columns to certificates table
  const newColumns = [
    'mount_points TEXT',
    'systemd_timer_name TEXT',
    'systemd_timer_created_at TEXT',
    'systemd_timer_fired_at TEXT',
    'revoked_at TEXT',
    'revoked_by TEXT',
    'revoke_reason TEXT',
    'cleanup_log TEXT',
    'user_deleted BOOLEAN DEFAULT 0',
    'chroot_removed BOOLEAN DEFAULT 0',
  ];

  for (const column of newColumns) {
    try {
      database.exec(`ALTER TABLE certificates ADD COLUMN ${column}`);
    } catch (error: unknown) {
      // Column may already exist, ignore error
      const err = error as { message?: string };
      if (!err.message?.includes('duplicate column name')) {
        console.warn(`Migration warning for column ${column}:`, err.message);
      }
    }
  }

  // Make username unique (if not already)
  try {
    database.exec(`
      CREATE UNIQUE INDEX IF NOT EXISTS idx_certificates_username_unique
      ON certificates(username)
    `);
  } catch {
    // Ignore if index already exists
  }

  console.log('Database migration complete');
}

/**
 * Closes the cached database connection and clears the in-memory instance.
 *
 * After calling this, subsequent calls to getDatabase() will create a new Database.
 */
export function closeDatabase(): void {
  if (db) {
    db.close();
    db = null;
  }
}

/**
 * Drops the access_logs and certificates tables from the currently cached database and reinitializes the schema.
 *
 * If no database is initialized, this function does nothing.
 */
export function resetDatabase(): void {
  if (db) {
    db.exec('DROP TABLE IF EXISTS access_logs');
    db.exec('DROP TABLE IF EXISTS certificates');
    initializeSchema(db);
  }
}
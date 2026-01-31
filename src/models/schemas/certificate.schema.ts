import { z } from 'zod';

export const createCertificateSchema = z.object({
  directoryPath: z
    .string()
    .min(1, 'Directory path is required')
    .refine((path) => path.startsWith('/'), 'Path must be absolute (start with /)')
    .refine((path) => {
      // Check for path traversal attempts
      const parts = path.split('/');
      return !parts.some((part) => part === '..' || part.includes('..'));
    }, 'Path cannot contain .. (path traversal not allowed)')
    .refine(
      (path) => !path.includes('~'),
      'Path cannot contain ~ (home directory expansion not allowed)'
    )
    .refine((path) => !path.includes('\0'), 'Path cannot contain null bytes')
    .optional(), // Optional - will use default from config

  permissions: z
    .array(z.enum(['sftp', 'ssh', 'read-only', 'read-write', 'read-write-modify']))
    .min(1, 'At least one permission is required')
    .refine((perms) => perms.includes('sftp') || perms.includes('ssh'), {
      message: 'At least sftp or ssh permission must be specified',
    })
    .optional(), // Optional - will use default from config

  ttl: z
    .number()
    .int('TTL must be an integer')
    .min(60, 'TTL must be at least 60 seconds (1 minute)')
    .max(86400, 'TTL must be at most 86400 seconds (24 hours)')
    .optional(), // Optional - will use default from config (600 seconds = 10 minutes)

  responseType: z.enum(['md', 'cert']).optional(), // Optional - default is "md"

  authenticatorToken: z
    .string()
    .min(32, 'Authenticator token must be at least 32 characters')
    .optional(), // Optional for now as per requirements
});

export const updateCertificateSchema = z
  .object({
    ttl: z
      .number()
      .int('TTL must be an integer')
      .min(60, 'TTL must be at least 60 seconds (1 minute)')
      .max(86400, 'TTL must be at most 86400 seconds (24 hours)')
      .optional(),

    permissions: z
      .array(z.enum(['sftp', 'ssh', 'read-only', 'read-write', 'read-write-modify']))
      .min(1, 'At least one permission is required')
      .optional(),

    status: z.enum(['active', 'expired', 'revoked']).optional(),
  })
  .refine(
    (data) => data.ttl !== undefined || data.permissions !== undefined || data.status !== undefined,
    {
      message: 'At least one field (ttl, permissions, or status) must be provided',
    }
  );

export const certificateParamsSchema = z.object({
  id: z.string().min(1, 'Certificate ID is required'),
});

export const downloadParamsSchema = z.object({
  id: z.string().min(1, 'Certificate ID is required'),
  type: z.enum(['key', 'readme', 'content']),
});

export type CreateCertificateInput = z.infer<typeof createCertificateSchema>;
export type UpdateCertificateInput = z.infer<typeof updateCertificateSchema>;
export type CertificateParams = z.infer<typeof certificateParamsSchema>;
export type DownloadParams = z.infer<typeof downloadParamsSchema>;

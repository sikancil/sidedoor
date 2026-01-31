import { Elysia } from 'elysia';
import { DEFAULT_CONFIG } from '../config/constants';

/**
 * Admin authentication middleware for protected admin endpoints
 * Uses CRON_SECRET environment variable for authentication
 */
export const requireAdminAuth = new Elysia({ name: 'admin-auth' }).derive(
  async ({ request, set }) => {
    const authHeader = request.headers.get('authorization');
    const cronSecret = process.env.CRON_SECRET || DEFAULT_CONFIG.cronSecret;

    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      set.status = 401;
      throw new Error('Unauthorized: Missing or invalid authorization header');
    }

    const token = authHeader.substring(7); // Remove 'Bearer ' prefix

    if (token !== cronSecret) {
      set.status = 403;
      throw new Error('Forbidden: Invalid admin token');
    }

    return {
      isAdmin: true,
      adminToken: token,
    };
  }
);

/**
 * Optional admin auth - sets admin flag but doesn't require it
 * Used for endpoints that work for both authenticated and unauthenticated requests
 */
export const optionalAdminAuth = new Elysia({ name: 'optional-admin-auth' }).derive(
  ({ request }) => {
    const authHeader = request.headers.get('authorization');
    const cronSecret = process.env.CRON_SECRET || DEFAULT_CONFIG.cronSecret;

    let isAdmin = false;
    let adminToken = null;

    if (authHeader && authHeader.startsWith('Bearer ')) {
      const token = authHeader.substring(7);
      if (token === cronSecret) {
        isAdmin = true;
        adminToken = token;
      }
    }

    return {
      isAdmin,
      adminToken,
    };
  }
);

/**
 * Detects whether the request was triggered by systemd.
 *
 * @param headers - The request headers to inspect
 * @returns `true` if the `X-Trigger` header equals `"systemd"`, `false` otherwise
 */
export function isSystemdTrigger(headers: Headers): boolean {
  return headers.get('x-trigger') === 'systemd';
}

/**
 * Determines whether the incoming request is authenticated as an admin.
 *
 * Compares the Bearer token in the Authorization header to the CRON_SECRET environment variable or DEFAULT_CONFIG.cronSecret.
 *
 * @param request - The incoming HTTP request whose Authorization header will be checked for a Bearer token.
 * @returns `true` if the Authorization header contains a Bearer token that exactly matches the cron secret, `false` otherwise.
 */
export function hasAdminAuth(request: Request): boolean {
  const authHeader = request.headers.get('authorization');
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return false;
  }

  const token = authHeader.substring(7);
  const cronSecret = process.env.CRON_SECRET || DEFAULT_CONFIG.cronSecret;

  return token === cronSecret;
}
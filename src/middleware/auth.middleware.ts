import { Elysia } from 'elysia';
import { extractBearerToken, validateAuthenticatorToken } from '../utils/auth.utils';

export const authMiddleware = new Elysia({ name: 'auth-middleware' })
  .derive(({ request }) => {
    const authorization = request.headers.get('Authorization');
    const token = extractBearerToken(authorization ?? undefined);

    if (!token || !validateAuthenticatorToken(token)) {
      throw new Error('Unauthorized: Invalid or missing authentication token');
    }

    return {
      auth: {
        valid: true,
        token,
      },
    };
  });

export function requireAuth() {
  return authMiddleware;
}

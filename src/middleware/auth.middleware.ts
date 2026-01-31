import { Elysia } from 'elysia';
import { extractBearerToken, validateAuthenticatorToken } from '../utils/auth.utils';

export const authMiddleware = new Elysia({ name: 'auth-middleware' }).derive(({ request }) => {
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

/**
 * Provides the authentication middleware that enforces presence of a valid bearer token.
 *
 * @returns The Elysia middleware instance which adds an `auth` object to the request context and throws an error when the authentication token is missing or invalid.
 */
export function requireAuth() {
  return authMiddleware;
}
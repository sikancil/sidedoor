import { getConfig } from '../config';
import type { Context } from 'elysia';

export interface AuthenticatedContext extends Context {
  auth?: {
    valid: boolean;
    token?: string;
  };
}

/**
 * Checks whether a provided authenticator token matches the configured authenticator token.
 *
 * @param token - The token to validate (typically from an Authorization header or request payload)
 * @returns `true` if `token` equals the configured authenticator token, `false` otherwise
 */
export function validateAuthenticatorToken(token: string): boolean {
  const config = getConfig();
  return token === config.authenticatorToken;
}

/**
 * Extracts the bearer token from an HTTP Authorization header.
 *
 * @param authorizationHeader - The raw Authorization header value (e.g., "Bearer <token>")
 * @returns The token string if the header is in the form `Bearer <token>`, `null` otherwise.
 */
export function extractBearerToken(authorizationHeader: string | undefined | null): string | null {
  if (!authorizationHeader) {
    return null;
  }

  const parts = authorizationHeader.split(' ');
  if (parts.length !== 2 || parts[0] !== 'Bearer') {
    return null;
  }

  return parts[1] ?? null;
}

/**
 * Creates an authentication middleware that validates incoming requests using a Bearer token.
 *
 * @returns A middleware function that returns `true` if the request contains a valid Bearer token matching the configured authenticator token, `false` otherwise.
 */
export function createAuthMiddleware() {
  return (context: Context): boolean => {
    const authorization = context.request.headers.get('Authorization');
    const token = extractBearerToken(authorization ?? undefined);

    if (!token || !validateAuthenticatorToken(token)) {
      return false;
    }

    return true;
  };
}

/**
 * Removes the `authenticator_token` property from a certificate-like object.
 *
 * @param cert - Certificate object that may include an `authenticator_token` property.
 * @returns The certificate object with `authenticator_token` removed.
 */
export function sanitizeCertificate(cert: {
  id: string;
  authenticator_token: string;
  [key: string]: unknown;
}): Omit<typeof cert, 'authenticator_token'> {
  const { authenticator_token, ...sanitized } = cert;
  return sanitized;
}
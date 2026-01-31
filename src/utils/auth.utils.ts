import { getConfig } from '../config';
import type { Context } from 'elysia';

export interface AuthenticatedContext extends Context {
  auth?: {
    valid: boolean;
    token?: string;
  };
}

export function validateAuthenticatorToken(token: string): boolean {
  const config = getConfig();
  return token === config.authenticatorToken;
}

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

export function sanitizeCertificate(cert: {
  id: string;
  authenticator_token: string;
  [key: string]: unknown;
}): Omit<typeof cert, 'authenticator_token'> {
  const { authenticator_token, ...sanitized } = cert;
  return sanitized;
}

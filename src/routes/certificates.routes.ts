import { Elysia, t } from 'elysia';
import { getCertificateService } from '../services/certificate.service';
import { requireAuth } from '../middleware/auth.middleware';

export const certificateRoutes = new Elysia({ prefix: '/api/certificates' })
  .use(requireAuth())

  // Create certificate
  .post(
    '/',
    async ({ body, set }) => {
      try {
        const input = body as {
          directoryPath?: string;
          permissions?: string[];
          ttl?: number;
          responseType?: 'md' | 'cert';
          authenticatorToken?: string;
        };

        const certificate = await getCertificateService().createCertificate(input);

        set.status = 201;
        return {
          success: true,
          data: certificate,
        };
      } catch (error) {
        set.status = 400;
        return {
          success: false,
          error: (error as Error).message,
        };
      }
    },
    {
      body: t.Object({
        directoryPath: t.Optional(
          t.String({
            minLength: 1,
            error: 'Directory path must be a non-empty string',
          })
        ),
        permissions: t.Optional(t.Array(t.String())),
        ttl: t.Optional(
          t.Number({
            minimum: 60,
            maximum: 86400,
            error: 'TTL must be between 60 and 86400 seconds',
          })
        ),
        responseType: t.Optional(t.Union([t.Literal('md'), t.Literal('cert')])),
        authenticatorToken: t.Optional(
          t.String({
            minLength: 32,
            error: 'Authenticator token must be at least 32 characters',
          })
        ),
      }),
    }
  )

  // Get all certificates
  .get('/', async () => {
    try {
      const certificates = await getCertificateService().getAllCertificates();

      return {
        success: true,
        data: certificates,
        count: certificates.length,
      };
    } catch (error) {
      return {
        success: false,
        error: (error as Error).message,
      };
    }
  })

  // Get single certificate
  .get(
    '/:id',
    async ({ params, set }) => {
      try {
        const certificate = await getCertificateService().getCertificate(params.id);

        return {
          success: true,
          data: certificate,
        };
      } catch (error) {
        set.status = 404;
        return {
          success: false,
          error: (error as Error).message,
        };
      }
    },
    {
      params: t.Object({
        id: t.String({ minLength: 1 }),
      }),
    }
  )

  // Update certificate
  .patch(
    '/:id',
    async ({ params, body, set }) => {
      try {
        const updates = body as {
          ttl?: number;
          permissions?: string[];
          status?: string;
        };

        const certificate = await getCertificateService().updateCertificate(params.id, updates);

        return {
          success: true,
          data: certificate,
        };
      } catch (error) {
        set.status = 400;
        return {
          success: false,
          error: (error as Error).message,
        };
      }
    },
    {
      params: t.Object({
        id: t.String({ minLength: 1 }),
      }),
      body: t.Object({
        ttl: t.Optional(
          t.Number({
            minimum: 60,
            maximum: 86400,
          })
        ),
        permissions: t.Optional(
          t.Array(
            t.Union([
              t.Literal('sftp'),
              t.Literal('ssh'),
              t.Literal('read-only'),
              t.Literal('read-write'),
              t.Literal('read-write-modify'),
            ])
          )
        ),
        status: t.Optional(
          t.Union([t.Literal('active'), t.Literal('expired'), t.Literal('revoked')])
        ),
      }),
    }
  )

  // Delete certificate
  .delete(
    '/:id',
    async ({ params, set }) => {
      try {
        await getCertificateService().deleteCertificate(params.id);

        set.status = 204;
        return;
      } catch (error) {
        set.status = 404;
        return {
          success: false,
          error: (error as Error).message,
        };
      }
    },
    {
      params: t.Object({
        id: t.String({ minLength: 1 }),
      }),
    }
  );

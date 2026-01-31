import { Elysia, t } from 'elysia';
import { getCertificateService } from '../services/certificate.service';
import { requireAuth } from '../middleware/auth.middleware';

export const downloadRoutes = new Elysia({ prefix: '/api/download' })
  .use(requireAuth())

  // Download private key
  .get(
    '/:id/key',
    async ({ params, set }) => {
      try {
        const keyContent = await getCertificateService().getPrivateKey(params.id);

        set.headers['Content-Type'] = 'text/plain';
        set.headers['Content-Disposition'] = `attachment; filename="cert_${params.id}_key"`;

        return keyContent;
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
        id: t.String(),
      }),
    }
  )

  // Download README
  .get(
    '/:id/readme',
    async ({ params, set }) => {
      try {
        const readmeContent = await getCertificateService().getReadme(params.id);

        set.headers['Content-Type'] = 'text/markdown';
        set.headers['Content-Disposition'] = `attachment; filename="README_${params.id}.md"`;

        return readmeContent;
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
        id: t.String(),
      }),
    }
  )

  // Get README content as JSON (markdown + HTML)
  .get(
    '/:id/content',
    async ({ params, set }) => {
      try {
        const content = await getCertificateService().getReadmeContent(params.id);

        return {
          success: true,
          data: content,
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
        id: t.String(),
      }),
    }
  );

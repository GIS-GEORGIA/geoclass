import path from 'node:path';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

export default defineConfig(async () => ({
  plugins: [
    cloudflareTest({
      // Same bindings as wrangler.jsonc, without the web build that tests don't need.
      wrangler: { configPath: './wrangler.test.jsonc' },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, 'migrations')),
          // sha256 of "test-teacher-key"
          TEACHER_KEY_HASH: '08767e0e1db0c180a43436652d3cf29ebac8d2412b3f309f01d22dfe3fd04377',
        },
        // Stands in for the web build: answers with the path it was asked for.
        serviceBindings: {
          ASSETS: (request: Request) => new Response(`picture of ${new URL(request.url).pathname}`, { headers: { 'Content-Type': 'image/webp' } }),
        },
      },
    }),
  ],
  test: { setupFiles: ['./test/setup.ts'] },
}));

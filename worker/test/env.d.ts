declare namespace Cloudflare {
  interface Env {
    TEST_MIGRATIONS: import('cloudflare:test').D1Migration[];
  }
}

// A binary fixture inlined by Vite (vitest.config.ts): a data: URL with the bytes in base64.
declare module '*?inline' {
  const url: string;
  export default url;
}

// Keeps the app itself available offline. Same-origin files only: the API must
// always be live, and map tiles stay under normal browser caching.
const CACHE = 'geoclass-v2';
// On a slow connection, stop waiting for the server and use the saved copy.
const NETWORK_TIMEOUT_MS = 4000;

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      let upgraded = false;
      for (const key of await caches.keys()) {
        if (key !== CACHE) {
          await caches.delete(key);
          upgraded = true;
        }
      }
      await self.clients.claim();
      // Pages opened through an older worker may hold old files, so load them again once.
      if (upgraded) {
        for (const client of await self.clients.matchAll({ type: 'window' })) {
          client.navigate(client.url).catch(() => {});
        }
      }
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin || url.pathname.startsWith('/api/')) {
    return;
  }
  // Photos added by the teacher must show up at once.
  if (url.pathname === '/aerial/index.json') return;
  // Ask the server first, so every file comes from the same version of the app.
  // The saved copy is only for when the server can't be reached in time.
  event.respondWith(
    (async () => {
      const cache = await caches.open(CACHE);
      const cached = await cache.match(event.request, { ignoreSearch: true });
      const fresh = fetch(event.request).then((response) => {
        if (response.ok) event.waitUntil(cache.put(event.request, response.clone()).catch(() => {}));
        return response;
      });
      event.waitUntil(fresh.catch(() => {}));
      if (!cached) return fresh;
      return Promise.race([
        fresh.then((response) => (response.ok ? response : cached), () => cached),
        new Promise((resolve) => setTimeout(() => resolve(cached), NETWORK_TIMEOUT_MS)),
      ]);
    })(),
  );
});

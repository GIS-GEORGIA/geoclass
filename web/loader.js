// The loading screen. A file of its own, not inline, so the CSP can allow only this site's scripts.
window.addEventListener('flutter-first-frame', () => document.getElementById('loading')?.remove());
setTimeout(() => {
  const stuck = document.getElementById('stuck');
  if (stuck) stuck.style.display = 'block';
}, 20000);
// Answers waiting to be sent are in the app's own storage, which this doesn't touch.
document.getElementById('retry').addEventListener('click', async () => {
  try {
    for (const r of await navigator.serviceWorker.getRegistrations()) await r.unregister();
    for (const key of await caches.keys()) await caches.delete(key);
  } catch (_) {}
  location.reload();
});

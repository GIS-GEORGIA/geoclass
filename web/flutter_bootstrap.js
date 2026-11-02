{{flutter_js}}
{{flutter_build_config}}

// Flutter no longer ships a service worker, so sw.js below handles offline caching.
_flutter.loader.load();

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => navigator.serviceWorker.register('sw.js'));
}

// Caches the app shell so the tablets start without a network.
// API calls (Supabase) are never cached. Bump VERSION on every release.
const VERSION = 'prr-v10';
const SHELL = [
  './', 'index.html', 'styles.css', 'config.js', 'app.js', 'core.js',
  'forecourt.js', 'kiosk.js', 'manager.js', 'journal.js', 'journal-check.js', 'manifest.webmanifest',
  'fonts/VSConstruct-Light.woff2', 'fonts/VSConstruct-Regular.woff2', 'fonts/VSConstruct-Bold.woff2',
  'fonts/VSConstructText-Regular.woff2', 'fonts/VSConstructText-Bold.woff2', 'icons/favicon.svg',
  'icons/icon-192.png', 'icons/icon-512.png', 'icons/icon-maskable-512.png', 'icons/apple-touch-icon.png',
];

self.addEventListener('install', (e) => {
  // cache: 'reload' skips the browser's HTTP cache (GitHub Pages allows 10 minutes),
  // so a new version is installed with the new files, not stale copies.
  e.waitUntil(caches.open(VERSION)
    .then((c) => c.addAll(SHELL.map((u) => new Request(u, { cache: 'reload' }))))
    .then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

// Network first for the shell (so updates arrive at once), cache as fallback.
// cache: 'no-cache' makes the browser check with the server every time (an
// unchanged file costs only a "304 Not Modified"), instead of reusing a copy
// up to 10 minutes old.
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== self.location.origin) return;
  e.respondWith(
    fetch(e.request, { cache: 'no-cache' })
      .then((res) => {
        if (res.ok) { const copy = res.clone(); caches.open(VERSION).then((c) => c.put(e.request, copy)); }
        return res;
      })
      .catch(() => caches.match(e.request, { ignoreSearch: true }).then((r) => r || caches.match('index.html'))),
  );
});

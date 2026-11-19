// Service worker: kerangka aplikasi tersedia saat offline. Panggilan API Supabase tidak pernah disimpan di cache.
const V = 'hauling-v6-1';
const ASET = ['./', 'index.html', 'manifest.webmanifest', 'icon.svg'];
self.addEventListener('install', e => { e.waitUntil(caches.open(V).then(c => c.addAll(ASET)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET') return;
  if (u.origin === location.origin) {
    e.respondWith(fetch(r).then(x => { const kp = x.clone(); caches.open(V).then(c => c.put(r, kp)); return x; }).catch(() => caches.match(r).then(x => x || caches.match('index.html'))));
  } else if (/cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com|fonts\.(googleapis|gstatic)\.com/.test(u.host)) {
    e.respondWith(caches.match(r).then(x => x || fetch(r).then(y => { const kp = y.clone(); caches.open(V).then(c => c.put(r, kp)); return y; })));
  }
});

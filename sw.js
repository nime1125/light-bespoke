// LIGHT-BESPOKE — Service Worker v1
const CACHE_NAME = "light-bespoke-v1";
const ASSETS = [
  "./index.html",
  "./landing.html",
  "./app.html",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png",
  "./apple-touch-icon.png",
  "./favicon.png",
  "./icon.svg",
  // CDN 라이브러리 캐시 (오프라인 지원)
  "https://cdn.tailwindcss.com",
  "https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.0/css/all.min.css",
];

self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      const local  = ASSETS.filter(a => a.startsWith("./"));
      const remote = ASSETS.filter(a => a.startsWith("http"));
      return cache.addAll(local).then(() =>
        Promise.allSettled(remote.map(url =>
          fetch(url).then(r => { if(r.ok) cache.put(url, r); }).catch(()=>{})
        ))
      );
    })
  );
  self.skipWaiting();
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (e) => {
  // BLE / Web Bluetooth 요청은 캐시 우회
  if (e.request.url.includes('bluetooth')) return;
  e.respondWith(
    caches.match(e.request).then(cached => {
      return cached || fetch(e.request).then(response => {
        // 성공적인 응답은 캐시에 추가
        if (response && response.status === 200 && response.type === 'basic') {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(e.request, clone));
        }
        return response;
      }).catch(() => cached);
    })
  );
});

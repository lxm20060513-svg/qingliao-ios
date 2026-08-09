/* 轻聊 PWA Service Worker — V1.3 (performance)
 * 策略：
 *  - /api/、/v1/ 请求绝不缓存（聊天/任务/HA 等动态数据）
 *  - HTML 导航 network-first（发版立即生效；离线回退缓存）
 *  - 静态资源（icons/manifest/libs/app.js）cache-first
 *  - FORCE_RELOAD 消息：清空缓存后让页面刷新（配合 SWR 拿到最新版）
 * 更新发版时：改 CACHE_NAME 版本号 + skipWaiting 立即接管
 */
const CACHE_NAME = 'qingliao-v45';
const PRECACHE_URLS = [
  '/',
  '/manifest.json',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/icons/icon-maskable-512.png',
  '/apple-touch-icon.png',
  '/libs/marked.min.js',
  '/libs/purify.min.js',
  '/libs/github.min.css',
  '/libs/github-dark.min.css',
  '/app.js'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(PRECACHE_URLS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// V1.3：页面点"刷新生效"时先清空缓存（HTML 是 SWR 缓存优先，不清会一直拿到旧版）
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'FORCE_RELOAD') {
    caches.keys()
      .then((keys) => Promise.all(keys.map((k) => caches.delete(k))))
      .then(() => {
        if (event.source) event.source.postMessage({ type: 'RELOAD_NOW' });
      });
  }
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // 动态 API 一律直连网络，不缓存、不拦截
  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/v1/')) {
    return;
  }

  // HTML 导航：network-first —— 内网应用保证发版立即生效（网络失败才回退缓存）
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request).then((res) => {
        const copy = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        return res;
      }).catch(() => caches.match(event.request))
    );
    return;
  }

  // 静态资源：cache-first
  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) return cached;
      return fetch(event.request).then((res) => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        }
        return res;
      });
    })
  );
});

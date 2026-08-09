/* 轻聊 PWA Service Worker — V1.3 (performance)
 * 策略：
 *  - /api/、/v1/ 请求绝不缓存（聊天/任务/HA 等动态数据）
 *  - HTML 导航 stale-while-revalidate（缓存秒开 + 后台更新；发版靠"新版提示→强制刷新"生效）
 *  - 静态资源（icons/manifest/libs/app.js）cache-first
 *  - FORCE_RELOAD 消息：清空缓存后让页面刷新（配合 SWR 拿到最新版）
 * 更新发版时：改 CACHE_NAME 版本号 + skipWaiting 立即接管
 */
const CACHE_NAME = 'qingliao-v43';
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

  // HTML 导航：stale-while-revalidate —— 有缓存立即返回（秒开），后台拉新更新缓存；无缓存走网络
  if (event.request.mode === 'navigate') {
    event.respondWith(
      caches.match(event.request).then((cached) => {
        const networkFetch = fetch(event.request).then((res) => {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
          return res;
        }).catch(() => cached);
        return cached || networkFetch;
      })
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

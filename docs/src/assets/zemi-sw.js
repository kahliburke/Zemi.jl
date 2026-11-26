// The service serves this file with an empty reading list. Only the public demo's build injects
// a list of files, after VitePress and the paper templates have finished writing them.
const scope = new URL(self.registration.scope)
const entries = self.__WB_MANIFEST || []
const files = new Set(entries.map(entry => new URL(entry.url, scope).href))
const prefix = `zemi-reading:${scope.href}:`
const cacheName = prefix + '__ZEMI_BUILD__'

self.addEventListener('install', event => {
  if (!files.size) return event.waitUntil(self.skipWaiting())
  event.waitUntil((async () => {
    const cache = await caches.open(cacheName)
    await cache.addAll([...files].map(url => new Request(url, {
      credentials: 'omit', redirect: 'error',
      cache: url.startsWith(scope.href + 'assets/') ? 'force-cache' : 'reload',
    })))
  })())
})

// Let tabs using the previous VitePress build finish before retiring their chunks.
self.addEventListener('activate', event => event.waitUntil((async () => {
  for (const name of await caches.keys()) {
    if (name.startsWith(prefix) && (!files.size || name !== cacheName)) await caches.delete(name)
  }
  await self.clients.claim()
})()))

function offlinePage() {
  return new Response('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Zemi · Offline</title><h1>You’re offline</h1><p>Reconnect to open this page.</p></html>', {
    status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' },
  })
}

self.addEventListener('fetch', event => {
  const request = event.request
  if (request.method !== 'GET' || !request.url.startsWith(scope.href) || request.headers.has('Authorization')) return
  const url = new URL(request.url)
  const path = url.pathname.slice(scope.pathname.length)
  if (/^(api|auth|oauth|mcp|\.well-known)(\/|$)/.test(path)) return

  if (request.mode === 'navigate') {
    // Only the public reading pages have an offline copy. Keep every HTTP response, including
    // permission failures, redirects and missing pages, exactly as the server answered it.
    if (url.search && [...url.searchParams.keys()].some(key => key !== 'q')) return
    url.search = ''
    if (url.pathname.endsWith('/')) url.pathname += 'index.html'
    event.respondWith(fetch(request).catch(async () => {
      if (files.has(url.href)) {
        const response = await caches.match(url.href, { cacheName })
        if (response) return response
      }
      return offlinePage()
    }))
    return
  }

  if (!files.has(url.href)) return
  const cached = caches.match(url.href, { cacheName })
  if (path === 'papers.json' || path === 'daily.json') {
    const refresh = fetch(request, { credentials: 'omit' }).then(async response => {
      if (response.status === 200 && !response.redirected && !/no-store/i.test(response.headers.get('Cache-Control') || '') &&
          response.headers.get('Content-Type')?.includes('application/json')) {
        const cache = await caches.open(cacheName)
        await cache.put(url.href, response.clone())
      }
      return response
    })
    event.waitUntil(refresh.catch(() => {}))
    event.respondWith(cached.then(response => response || refresh))
  } else {
    event.respondWith(cached.then(response => response || fetch(request)))
  }
})

self.addEventListener('push', e => {
  let m = {}
  try { m = e.data ? e.data.json() : {} } catch { m = { body: e.data ? e.data.text() : '' } }
  e.waitUntil(self.registration.showNotification(m.title || 'Zemi', {
    body: m.body || '', icon: new URL('zemi-icon-192.png', scope).href, data: { url: m.url || scope.href },
    ...(m.tag ? { tag: m.tag, renotify: true } : {}),
  }))
})

self.addEventListener('notificationclick', e => {
  e.notification.close()
  const target = new URL(e.notification.data?.url || './', scope)
  const url = target.href.startsWith(scope.href) ? target.href : scope.href
  e.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    const open = windows.filter(w => w.url.startsWith(scope.href))
    const path = u => new URL(u).pathname.replace(/\.html$/, '')
    const win = open.find(w => path(w.url) === path(url)) ?? open[0]
    if (!win) return self.clients.openWindow(url)
    // The page opens what the notification is about itself (see kbPush.ts): moving a window from
    // here works only for one this worker controls, and not to the address it is already at.
    try { await win.focus() } catch {}
    win.postMessage({ zemi: 'open', url })
  })())
})

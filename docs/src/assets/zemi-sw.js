// The site's service worker: it shows the notifications the service pushes of what waits on its
// person (see src/notify.jl), and a click on one opens what it is about, in a window of the site
// already open where there is one. The service serves it at /zemi-sw.js, so it covers the whole site.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()))

self.addEventListener('push', e => {
  let m = {}
  try { m = e.data ? e.data.json() : {} } catch { m = { body: e.data ? e.data.text() : '' } }
  e.waitUntil(self.registration.showNotification(m.title || 'Zemi', {
    body: m.body || '', icon: '/android-chrome-192x192.png', data: { url: m.url || '/' },
    ...(m.tag ? { tag: m.tag, renotify: true } : {}),
  }))
})

self.addEventListener('notificationclick', e => {
  e.notification.close()
  const url = new URL(e.notification.data?.url || '/', self.location.origin).href
  e.waitUntil((async () => {
    const open = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    const path = u => new URL(u).pathname.replace(/\.html$/, '')
    const win = open.find(w => path(w.url) === path(url)) ?? open[0]
    if (!win) return self.clients.openWindow(url)
    // The page opens what the notification is about itself (see kbPush.ts): moving a window from
    // here works only for one this worker controls, and not to the address it is already at.
    try { await win.focus() } catch {}
    win.postMessage({ zemi: 'open', url })
  })())
})

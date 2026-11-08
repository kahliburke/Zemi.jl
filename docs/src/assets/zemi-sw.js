// The site's service worker: it shows the notifications the service pushes of what waits on its
// person (see src/notify.jl), and a click on one opens what it is about, in a window of the site
// already open where there is one. The service serves it at /zemi-sw.js, so it covers the whole site.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()))

self.addEventListener('push', e => {
  let m = {}
  try { m = e.data ? e.data.json() : {} } catch { m = { body: e.data ? e.data.text() : '' } }
  e.waitUntil(self.registration.showNotification(m.title || 'Zemi', {
    body: m.body || '', tag: m.tag || 'zemi', renotify: true, icon: '/android-chrome-192x192.png',
    data: { url: m.url || '/' },
  }))
})

self.addEventListener('notificationclick', e => {
  e.notification.close()
  const url = new URL(e.notification.data?.url || '/', self.location.origin).href
  e.waitUntil((async () => {
    const open = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    const win = open.find(w => w.url === url) ?? open.find(w => new URL(w.url).origin === self.location.origin)
    if (win) {
      await win.focus()
      if (win.url !== url && 'navigate' in win) await win.navigate(url)
      return
    }
    await self.clients.openWindow(url)
  })())
})

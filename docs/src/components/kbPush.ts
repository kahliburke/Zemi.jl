// Notifications pushed to this browser of what waits on its person (see src/notify.jl): turning them
// on (the service worker, the browser's permission and its subscription, handed to the service) and
// off. They need the service at the page's own address, which serves the service worker and the
// manifest an iPhone installs the site with.
import { api, getJSON, post } from './kbApi'

export type PushSettings = { key: string; sections: string[]; all_sections: { id: string; label: string }[];
                             devices: { id: number; label: string; created_at: string; last_sent: string; endpoint: string }[] }

const sameOrigin = () => typeof location !== 'undefined' && new URL(api.value || location.origin, location.href).origin === location.origin

// Whether this browser can be sent notifications here.
export const pushSupported = () => sameOrigin() && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window

// An iPhone or iPad shows notifications only from the site added to its Home Screen and opened from there.
export const needsHomeScreen = () => typeof navigator !== 'undefined' && /iPhone|iPad|iPod/.test(navigator.userAgent) &&
  !(window.matchMedia?.('(display-mode: standalone)').matches || (navigator as any).standalone)

// Name the manifest in the page, so the site can be installed (added to a phone's Home Screen).
export function offerInstall() {
  if (!sameOrigin() || document.querySelector('link[rel="manifest"]')) return
  const l = document.createElement('link')
  l.rel = 'manifest'; l.href = '/manifest.webmanifest'
  document.head.appendChild(l)
}

const keyBytes = (b64url: string) => {
  const s = atob(b64url.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - b64url.length % 4) % 4))
  return Uint8Array.from(s, c => c.charCodeAt(0))
}

// A short name for this browser among its person's devices.
function deviceLabel() {
  const ua = navigator.userAgent
  const os = /iPhone|iPad/.test(ua) ? 'iPhone/iPad' : /Android/.test(ua) ? 'Android' : /Mac/.test(ua) ? 'Mac' : /Windows/.test(ua) ? 'Windows' : /Linux/.test(ua) ? 'Linux' : 'device'
  const browser = /Edg\//.test(ua) ? 'Edge' : /Firefox\//.test(ua) ? 'Firefox' : /Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'browser'
  return `${browser} on ${os}`
}

const registration = () => navigator.serviceWorker.register('/zemi-sw.js', { scope: '/' })

// This browser's subscription, if it has one.
export async function currentSubscription(): Promise<PushSubscription | null> {
  if (!pushSupported()) return null
  const r = await navigator.serviceWorker.getRegistration('/')
  return r ? r.pushManager.getSubscription() : null
}

// Turn notifications on in this browser: asks its permission (so call it from a click).
export async function turnOn(settings: PushSettings) {
  if ((await Notification.requestPermission()) !== 'granted') throw new Error('Notifications are blocked in this browser’s settings for this site.')
  const reg = await registration()
  await navigator.serviceWorker.ready
  let sub = await reg.pushManager.getSubscription()
  // A subscription made for another key (the service's was replaced) is made again.
  const key = keyBytes(settings.key)
  const same = sub?.options.applicationServerKey &&
    new Uint8Array(sub.options.applicationServerKey).every((b, i) => b === key[i])
  if (sub && !same) { await sub.unsubscribe(); sub = null }
  sub ??= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key })
  await post('/api/push/devices', JSON.stringify({ ...sub.toJSON(), label: deviceLabel() }))
}

// Turn them off in this browser.
export async function turnOff() {
  const sub = await currentSubscription()
  if (!sub) return
  await post('/api/push/devices/remove', JSON.stringify({ endpoint: sub.endpoint }))
  await sub.unsubscribe()
}

export const loadPush = (): Promise<PushSettings> => getJSON('/api/push')
export const saveSections = (sections: string[]) => post('/api/push/sections', JSON.stringify({ sections }))
export const sendTest = (): Promise<{ sent: number }> => post('/api/push/test')
export const forget = (endpoint: string) => post('/api/push/devices/remove', JSON.stringify({ endpoint }))

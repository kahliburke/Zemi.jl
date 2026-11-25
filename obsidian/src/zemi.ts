// Talking to a Zemi knowledge base: signing in with OAuth (a client of one's own, with PKCE, sent back
// to a loopback address this plugin listens on), and asking its API with the token, renewed when it
// runs out. Requests go through Obsidian's `requestUrl`, which no browser rule about origins limits.
import { requestUrl } from 'obsidian'
import * as http from 'http'
import * as crypto from 'crypto'
import type { AddressInfo } from 'net'

export type Tokens = { access: string; refresh: string; expires: number; client: string; tokenEndpoint: string; site: string; scope?: string }

/** What the plugin keeps: the knowledge base's address, the vault's folder in one's library, where
 *  notes for added papers go, the sign-in, and the file asking `zemi connect` for a pass now
 *  (`syncNow`, given by `zemi obsidian`), touched after a save unless `syncOnSave` is off. */
export type Settings = { site: string; folder: string; papersFolder: string; tokens: Tokens | null; syncNow?: string; syncOnSave?: boolean }

export class SignedOut extends Error {}

/** A request the knowledge base refused, with its status. */
export class Refused extends Error { constructor(message: string, public status: number) { super(message) } }

// Reading the knowledge base, one's library, and the tasks and findings of one's projects.
export const SCOPE = 'read library tasks.view'
const SIGN_IN_MINUTES = 10

const base64url = (b: Buffer) => b.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
const trimmed = (site: string) => site.trim().replace(/\/+$/, '')

async function postForm(url: string, form: Record<string, string>): Promise<any> {
  const r = await requestUrl({ url, method: 'POST', contentType: 'application/x-www-form-urlencoded',
                               body: new URLSearchParams(form).toString(), throw: false })
  if (r.status >= 300) throw new Error(r.json?.error_description ?? r.json?.error ?? `${url} answered ${r.status}`)
  return r.json
}

function tokensFrom(t: any, client: string, tokenEndpoint: string, site: string): Tokens {
  return { access: t.access_token, refresh: t.refresh_token, expires: Date.now() + 1000 * (t.expires_in ?? 3600),
           client, tokenEndpoint, site, scope: t.scope }
}

/** Obsidian's theme, light or dark (dark unless it says light), for the pages signing in opens. */
const obsidianTheme = () => document.body.classList.contains('theme-light') ? 'light' : 'dark'

const DONE_PAGE = (text: string, theme: string) => `<!doctype html><meta charset="utf-8"><title>Zemi</title>
<style>body{font:16px system-ui,sans-serif;display:grid;place-items:center;height:90vh;
${theme === 'light' ? 'background:#f6f7fb;color:#1d2233' : 'background:#0d1120;color:#d4d8e8'}}</style><p>${text}</p>`

/**
 * Sign in to the knowledge base at `site` in the browser: register a client sent back to a port of
 * this machine, open the knowledge base's consent page, and exchange the code it returns for tokens.
 */
export async function signIn(site: string): Promise<Tokens> {
  site = trimmed(site)
  const meta = (await requestUrl({ url: `${site}/.well-known/oauth-authorization-server` })).json
  const server = http.createServer()
  await new Promise<void>((ok, fail) => { server.once('error', fail); server.listen(0, '127.0.0.1', ok) })
  try {
    const redirect = `http://127.0.0.1:${(server.address() as AddressInfo).port}/callback`
    const reg = await requestUrl({ url: meta.registration_endpoint, method: 'POST', contentType: 'application/json',
      body: JSON.stringify({ client_name: 'Obsidian', redirect_uris: [redirect], token_endpoint_auth_method: 'none',
                             grant_types: ['authorization_code', 'refresh_token'] }) })
    const client: string = reg.json.client_id
    const verifier = base64url(crypto.randomBytes(32))
    const state = base64url(crypto.randomBytes(16))
    const challenge = base64url(crypto.createHash('sha256').update(verifier).digest())
    const theme = obsidianTheme()
    const asked = new Promise<string>((ok, fail) => {
      const timer = setTimeout(() => fail(new Error('No sign-in within ten minutes')), SIGN_IN_MINUTES * 60_000)
      server.on('request', (req, res) => {
        const u = new URL(req.url ?? '/', redirect)
        if (u.pathname !== '/callback') { res.writeHead(404).end(); return }
        const code = u.searchParams.get('code'), error = u.searchParams.get('error')
        const ours = u.searchParams.get('state') === state
        const why = !ours ? 'this approval was for another sign-in' : error === 'access_denied' ? 'it was declined' : error ?? ''
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
          .end(DONE_PAGE(ours && code ? 'Signed in to Zemi. You can close this tab.'
                         : `Not signed in${why ? ` (${why.replace(/[<>&"]/g, '')})` : ''}. Try again from Obsidian.`, theme))
        if (!ours) return
        clearTimeout(timer)
        code ? ok(code) : fail(new Error(error === 'access_denied' ? 'Signing in was declined' : `Not signed in: ${error}`))
      })
    })
    const url = new URL(meta.authorization_endpoint)
    for (const [k, v] of Object.entries({ response_type: 'code', client_id: client, redirect_uri: redirect, scope: SCOPE,
                                          code_challenge: challenge, code_challenge_method: 'S256', state, theme }))
      url.searchParams.set(k, v)
    window.open(url.toString())
    const code = await asked
    const t = await postForm(meta.token_endpoint, { grant_type: 'authorization_code', code, redirect_uri: redirect,
                                                    client_id: client, code_verifier: verifier })
    return tokensFrom(t, client, meta.token_endpoint, site)
  } finally {
    server.close()
  }
}

/** The knowledge base, asked as whoever signed in. */
export class Zemi {
  constructor(private settings: () => Settings, private keep: (t: Tokens | null) => Promise<void>) {}

  get site() { return trimmed(this.settings().site) }
  get signedIn() { const t = this.settings().tokens; return t !== null && t.site === this.site }

  private async token(renew = false): Promise<string> {
    const t = this.settings().tokens
    if (!t || t.site !== this.site) throw new SignedOut('Not signed in to Zemi: sign in from the plugin settings')
    if (!renew && t.expires - Date.now() > 60_000) return t.access
    try {
      const n = await postForm(t.tokenEndpoint, { grant_type: 'refresh_token', refresh_token: t.refresh, client_id: t.client })
      const next = tokensFrom(n, t.client, t.tokenEndpoint, t.site)
      await this.keep(next)
      return next.access
    } catch {
      await this.keep(null)
      throw new SignedOut('Signed out of Zemi: sign in again from the plugin settings')
    }
  }

  private async request(path: string, binary: boolean): Promise<any> {
    for (const renew of [false, true]) {
      const r = await requestUrl({ url: this.site + path, headers: { Authorization: `Bearer ${await this.token(renew)}` }, throw: false })
      if (r.status === 401 && !renew) continue
      if (r.status === 404) return null
      if (r.status >= 300) throw new Refused(r.json?.error ?? `Zemi answered ${r.status}`, r.status)
      return binary ? r.arrayBuffer : r.json
    }
  }

  /** `path` of the API, as JSON; `null` for one the knowledge base has nothing at. */
  get(path: string): Promise<any> { return this.request(path, false) }
  /** `path` as bytes (a figure). */
  bytes(path: string): Promise<ArrayBuffer | null> { return this.request(path, true) }
}

/** An arXiv id or a DOI in `text`, as a note naming a paper gives it. */
export function paperReference(text: string): { kind: 'arxiv' | 'doi'; id: string } | null {
  const doi = text.match(/\b(10\.\d{4,9}\/[^\s"<>]+[^\s"<>.,;)])/)
  if (doi) return { kind: 'doi', id: doi[1] }
  const arxiv = text.match(/\b(?:arxiv:\s*)?(\d{4}\.\d{4,5})(?:v\d+)?\b/i) ?? text.match(/\b([a-z-]+(?:\.[A-Z]{2})?\/\d{7})\b/)
  return arxiv ? { kind: 'arxiv', id: arxiv[1] } : null
}

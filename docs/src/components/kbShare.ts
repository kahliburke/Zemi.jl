// A share is prepared when the reader opens it, including views that change only the URL fragment.
export type ShareMode = 'link' | 'content'

export function shareUrl(address: string) {
  const url = new URL(address)
  url.username = url.password = ''
  if (url.searchParams.has('key')) url.searchParams.delete('to')
  for (const key of [...url.searchParams.keys()]) {
    if (/^(key|token|access_token|refresh_token|id_token)$/i.test(key)) url.searchParams.delete(key)
  }
  return url.href
}

export function shareData(mode: ShareMode, url: string, title: string, text: string): ShareData {
  return mode === 'link' ? { url } : { title, text: text.trim(), url }
}

export function shareText(data: ShareData) {
  return [...new Set([data.title, data.text, data.url].filter(Boolean))].join('\n\n')
}

export function currentShare() {
  const url = new URL(location.href)
  const page = document.querySelector<HTMLElement>('.VPContent') ?? document.querySelector<HTMLElement>('main')
  const task = document.querySelector<HTMLElement>('.kbp-panel')
  const scope = task ?? page
  const heading = scope?.querySelector<HTMLElement>('.kbf-claim, .kbp-panel-title, .kbx-card h3')
    ?? scope?.querySelector<HTMLElement>('h1')
  const title = heading?.innerText.trim() || document.title.split(' | ')[0]
  const center = scope?.querySelector<HTMLElement>('[data-share-center]')?.dataset.shareCenter
  if (center) url.searchParams.set('center', center)

  const note = task && /^#[^/]+\/(\d+)$/.exec(url.hash)
  const noteText = note && task.querySelector<HTMLElement>(`[data-event="${note[1]}"] .kbp-note`)
  const selection = window.getSelection()
  const selected = selection?.anchorNode && selection.focusNode &&
    scope?.contains(selection.anchorNode) && scope.contains(selection.focusNode) ? selection.toString().trim() : ''
  const parts = scope?.querySelectorAll<HTMLElement>('[data-share-text]') ?? []
  const prose = Array.from(parts).filter(el => el.getClientRects().length).map(el => el.innerText.trim()).filter(Boolean)
  // Ordinary Markdown pages have paragraphs immediately inside their content wrapper. On an
  // operational dashboard, leave the reader a title and an editable message instead of copying controls.
  const pageText = prose.length ? prose.join('\n\n') : Array.from(scope?.querySelectorAll<HTMLElement>('.vp-doc > div > p') ?? [])
    .filter(el => el.getClientRects().length).map(el => el.innerText.trim()).filter(Boolean).join('\n\n')
  return { title, url: shareUrl(url.href), text: selected || noteText?.innerText.trim() || pageText || title }
}

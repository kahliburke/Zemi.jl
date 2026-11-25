// The pane beside the open note: for a paper note (one Zemi gave `zemi`, the paper's id), the paper's
// summary, topics and figures; for any note, the papers and notes nearest it in the knowledge base;
// each with its citation to insert and its page in Zemi to open.
import { ItemView, MarkdownRenderer, Notice, TFile, WorkspaceLeaf } from 'obsidian'
import type ZemiPlugin from './main'
import { SignedOut } from './zemi'

export const VIEW_TYPE = 'zemi-view'

type Near = { doc_id: string; title: string; page: string }

export class ZemiView extends ItemView {
  private shown = ''                 // the note shown, and so not drawn again for the same one
  private urls: string[] = []         // figures' object URLs, let go of when the pane is drawn again

  constructor(leaf: WorkspaceLeaf, private plugin: ZemiPlugin) { super(leaf) }

  getViewType() { return VIEW_TYPE }
  getDisplayText() { return 'Zemi' }
  getIcon() { return 'library' }

  async onOpen() {
    this.registerEvent(this.app.workspace.on('file-open', () => this.refresh()))
    this.registerEvent(this.app.metadataCache.on('changed', f => { if (f.path === this.shown) this.refresh(true) }))
    await this.refresh()
  }

  async onClose() { this.release() }

  private release() { this.urls.forEach(u => URL.revokeObjectURL(u)); this.urls = [] }

  async refresh(again = false) {
    const file = this.app.workspace.getActiveFile()
    if (!file || file.extension !== 'md') return
    if (file.path === this.shown && !again) return
    this.shown = file.path
    this.release()
    const root = this.contentEl
    root.empty()
    root.addClass('zemi-pane')
    try {
      await this.draw(root, file)
    } catch (e: any) {
      root.empty()
      root.createEl('p', { text: e instanceof SignedOut ? e.message : `Zemi: ${e?.message ?? e}`, cls: 'zemi-dim' })
    }
  }

  private async draw(root: HTMLElement, file: TFile) {
    const zemi = this.plugin.zemi
    const props = this.app.metadataCache.getFileCache(file)?.frontmatter ?? {}
    const paper: string | undefined = props['zemi'] ? String(props['zemi']) : undefined
    if (paper) await this.drawPaper(root, paper, props)
    // The nearest documents: the paper's, else those of the record the note is read as.
    let near: Near[] = []
    if (paper) near = (await zemi.get(`/api/similar/${encodeURIComponent(paper)}?limit=8`)) ?? []
    else {
      const path = `${this.plugin.settings.folder}/${file.path}`
      const note = await zemi.get(`/api/library/note?path=${encodeURIComponent(path)}`)
      if (!note) {
        root.createEl('p', { cls: 'zemi-dim', text: 'Not read by Zemi yet: zemi connect syncs the vault, and it is read soon after.' })
        return
      }
      this.citeRow(root, note.cite.cite, note.page)
      near = (await zemi.get(`/api/similar/${encodeURIComponent(note.id)}?limit=8`)) ?? []
      if (!near.length) near = await this.searchNear(file)
    }
    root.createEl('h4', { text: 'Nearest in Zemi' })
    if (!near.length) { root.createEl('p', { cls: 'zemi-dim', text: 'Nothing near it yet.' }); return }
    const list = root.createEl('ul', { cls: 'zemi-near' })
    for (const n of near) {
      const li = list.createEl('li')
      li.createEl('a', { text: n.title, href: n.page })
      const cite = li.createEl('button', { text: 'cite', cls: 'zemi-small', attr: { title: 'Insert its citation in the note' } })
      cite.onclick = () => this.plugin.insertCitation(n.doc_id)
    }
  }

  // A note with no vector of its own yet: the documents its title and opening find.
  private async searchNear(file: TFile): Promise<Near[]> {
    const text = (await this.app.vault.cachedRead(file)).replace(/^---[\s\S]*?\n---\n/, '').slice(0, 400)
    const got = await this.plugin.zemi.get(`/api/search?q=${encodeURIComponent(file.basename + ' ' + text)}&limit=6`)
    return (got?.hits ?? []).map((h: any) => ({ doc_id: h.id, title: h.title, page: h.link }))
  }

  private async drawPaper(root: HTMLElement, id: string, props: Record<string, any>) {
    const zemi = this.plugin.zemi
    const p = await zemi.get(`/api/paper/${encodeURIComponent(id)}`)
    if (!p) { root.createEl('p', { cls: 'zemi-dim', text: `Zemi has no paper ${id} yet: it is brought in once the vault is read.` }); return }
    root.createEl('h3', { text: p.title })
    const by = (p.authors ?? []).slice(0, 4).join(', ') + ((p.authors ?? []).length > 4 ? ' et al.' : '')
    root.createEl('p', { cls: 'zemi-dim', text: [by, p.published].filter(Boolean).join(' · ') })
    this.citeRow(root, props['zemi-cite'] ? String(props['zemi-cite']) : (await zemi.get(`/api/cite/${encodeURIComponent(id)}`))?.cite,
                 props['zemi-page'] ? String(props['zemi-page']) : '')
    if (p.summary) {
      const s = root.createDiv({ cls: 'zemi-summary' })
      await MarkdownRenderer.render(this.app, p.summary, s, '', this)
    }
    if (p.topics?.length) root.createEl('p', { cls: 'zemi-dim', text: p.topics.join(' · ') })
    const figs = ((await zemi.get(`/api/figures?id=${encodeURIComponent(id)}`)) ?? []).slice(0, 8)
    if (!figs.length) return
    root.createEl('h4', { text: 'Figures' })
    const box = root.createDiv({ cls: 'zemi-figures' })
    for (const f of figs) {
      const bytes = await zemi.bytes(f.src)
      if (!bytes) continue
      const url = URL.createObjectURL(new Blob([bytes]))
      this.urls.push(url)
      const fig = box.createEl('figure')
      fig.createEl('img', { attr: { src: url, alt: f.label } })
      fig.createEl('figcaption', { text: f.caption ? `${f.label}. ${f.caption}` : f.label })
    }
  }

  private citeRow(root: HTMLElement, cite: string | undefined, page: string) {
    const row = root.createDiv({ cls: 'zemi-row' })
    if (cite) {
      row.createEl('code', { text: cite })
      const b = row.createEl('button', { text: 'Copy', cls: 'zemi-small' })
      b.onclick = async () => { await navigator.clipboard.writeText(cite); new Notice('Citation copied') }
    }
    if (page) row.createEl('a', { text: 'Open in Zemi', href: page })
  }
}

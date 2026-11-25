// Zemi in Obsidian: a pane beside the open note (see view.ts), searching the knowledge base to insert
// a citation, a note's citations linked to what they cite (see citations.ts), `zemi` blocks showing
// what the knowledge base has (see blocks.ts), and adding the paper an arXiv id or DOI names as a note
// of its own, which Zemi brings in and fills once `zemi connect` has synced the vault. It writes
// nothing into the vault but what it is asked to: Zemi gives paper notes their references itself.
import { App, Editor, MarkdownView, Notice, Plugin, PluginSettingTab, Setting, SuggestModal, normalizePath } from 'obsidian'
import { Settings, SignedOut, Zemi, paperReference, signIn } from './zemi'
import { VIEW_TYPE, ZemiView } from './view'
import { CitedKeys, citationExtension, linkCitations } from './citations'
import { STARTER_BLOCK, drawBlock } from './blocks'
import { promises as fs } from 'fs'

// How long after the last change to a note the vault is synced: Obsidian saves every few seconds
// while one types, and a pass for each would be wasted.
const SYNC_AFTER_MS = 2000

const DEFAULTS = (app: App): Settings => ({ site: 'http://localhost:8000', folder: app.vault.getName(), papersFolder: 'Papers', tokens: null })

export default class ZemiPlugin extends Plugin {
  settings!: Settings
  zemi!: Zemi
  cited!: CitedKeys

  async onload() {
    this.settings = { ...DEFAULTS(this.app), ...(await this.loadData()) }
    this.zemi = new Zemi(() => this.settings, async t => { this.settings.tokens = t; await this.saveData(this.settings) })
    this.cited = new CitedKeys(this.zemi)
    this.registerView(VIEW_TYPE, leaf => new ZemiView(leaf, this))
    this.registerMarkdownPostProcessor((el, ctx) => { if (this.zemi.signedIn) return linkCitations(el, ctx, this.cited) })
    this.registerEditorExtension(citationExtension(this.cited))
    this.registerMarkdownCodeBlockProcessor('zemi', (source, el, ctx) => drawBlock(this, source, el, ctx))
    for (const event of ['modify', 'create', 'delete', 'rename'] as const) {
      this.registerEvent(this.app.vault.on(event as 'modify', () => this.syncSoon()))
    }
    this.addRibbonIcon('library', 'Zemi', () => this.openPane())
    this.addCommand({ id: 'open-pane', name: 'Open the Zemi pane', callback: () => this.openPane() })
    this.addCommand({ id: 'cite', name: 'Search Zemi and insert a citation',
                      editorCallback: (editor: Editor) => new CiteModal(this.app, this, editor).open() })
    this.addCommand({ id: 'add-paper', name: 'Add the paper named here (arXiv id or DOI)',
                      editorCallback: (editor: Editor) => this.addPaper(editor) })
    this.addCommand({ id: 'insert-block', name: 'Insert a Zemi block',
                      editorCallback: (editor: Editor) => {
                        const c = editor.getCursor()
                        editor.replaceRange((c.ch ? '\n' : '') + STARTER_BLOCK, c)
                        editor.setCursor({ line: c.line + (c.ch ? 2 : 1), ch: 'search: '.length })
                      } })
    this.addSettingTab(new ZemiSettings(this.app, this))
  }

  async openPane() {
    const open = this.app.workspace.getLeavesOfType(VIEW_TYPE)[0]
    const leaf = open ?? this.app.workspace.getRightLeaf(false)
    if (!leaf) return
    open || await leaf.setViewState({ type: VIEW_TYPE, active: true })
    this.app.workspace.revealLeaf(leaf)
  }

  async save() { await this.saveData(this.settings) }

  private syncTimer: number | undefined

  /** Once the vault is still for a moment, ask whoever syncs it (`zemi connect`, or the knowledge base
   *  run here) for a pass now rather than at its next, by touching the file it waits on. */
  syncSoon() {
    const file = this.settings.syncNow
    if (!file || this.settings.syncOnSave === false) return
    window.clearTimeout(this.syncTimer)
    this.syncTimer = window.setTimeout(() => { fs.writeFile(file, '').catch(() => {}) }, SYNC_AFTER_MS)
  }

  /** Whether the sign-in lets the plugin see tasks and findings: one made before it asked for them does not. */
  get seesTasks() { return (this.settings.tokens?.scope ?? '').split(' ').includes('tasks.view') }

  /** Insert document `id`'s citation where the cursor is in the note last edited. */
  async insertCitation(id: string) {
    const md = this.app.workspace.getMostRecentLeaf()?.view
    if (!(md instanceof MarkdownView)) { new Notice('Open a note to cite into'); return }
    const c = await this.zemi.get(`/api/cite/${encodeURIComponent(id)}`)
    c ? md.editor.replaceSelection(c.cite) : new Notice(`Zemi has no ${id}`)
  }

  // The selection, else the line the cursor is on, naming a paper: a note for it in the papers folder,
  // linked from here. Zemi fills its title and authors once it has read it.
  async addPaper(editor: Editor) {
    const ref = paperReference(editor.getSelection() || editor.getLine(editor.getCursor().line))
    if (!ref) { new Notice('No arXiv id or DOI here'); return }
    const name = ref.id.replace(/[\\/:*?"<>|]/g, '-')
    const path = normalizePath(`${this.settings.papersFolder}/${name}.md`)
    if (!this.app.vault.getAbstractFileByPath(path)) {
      const folder = normalizePath(this.settings.papersFolder)
      if (!this.app.vault.getAbstractFileByPath(folder)) await this.app.vault.createFolder(folder)
      await this.app.vault.create(path, `---\n${ref.kind}: "${ref.id}"\ntitle:\nauthors:\n---\n`)
      new Notice(`Added ${ref.id}: Zemi fills its title and authors once the vault is synced`)
    }
    editor.getSelection() ? editor.replaceSelection(`[[${name}]]`) : editor.replaceRange(` [[${name}]]`, { line: editor.getCursor().line, ch: editor.getLine(editor.getCursor().line).length })
  }
}

type Hit = { id: string; title: string; authors: string[]; published: string; kind: string }

/** Search as one types, and insert the chosen document's citation where the cursor is. */
class CiteModal extends SuggestModal<Hit> {
  private timer: number | undefined

  constructor(app: App, private plugin: ZemiPlugin, private editor: Editor) {
    super(app)
    this.setPlaceholder('Search Zemi for a paper or note to cite')
  }

  getSuggestions(query: string): Promise<Hit[]> {
    window.clearTimeout(this.timer)
    if (query.trim().length < 2) return Promise.resolve([])
    // Asked once typing pauses, not at every key.
    return new Promise(ok => {
      this.timer = window.setTimeout(async () => {
        try {
          const got = await this.plugin.zemi.get(`/api/search?q=${encodeURIComponent(query)}&limit=10`)
          ok(got?.hits ?? [])
        } catch (e: any) {
          new Notice(e instanceof SignedOut ? e.message : `Zemi: ${e?.message ?? e}`)
          ok([])
        }
      }, 300)
    })
  }

  renderSuggestion(h: Hit, el: HTMLElement) {
    el.createDiv({ text: h.title })
    const by = (h.authors ?? []).slice(0, 3).join(', ')
    el.createEl('small', { cls: 'zemi-dim', text: [h.kind !== 'paper' ? h.kind : '', by, (h.published ?? '').slice(0, 4)].filter(Boolean).join(' · ') })
  }

  async onChooseSuggestion(h: Hit) {
    const c = await this.plugin.zemi.get(`/api/cite/${encodeURIComponent(h.id)}`)
    c ? this.editor.replaceSelection(c.cite) : new Notice(`Zemi has no ${h.id}`)
  }
}

class ZemiSettings extends PluginSettingTab {
  constructor(app: App, private plugin: ZemiPlugin) { super(app, plugin) }

  display() {
    const { containerEl: el } = this
    const s = this.plugin.settings
    el.empty()
    new Setting(el).setName('Knowledge base').setDesc('Its address: the one run on this machine, or a group\'s.')
      .addText(t => t.setPlaceholder('http://localhost:8000').setValue(s.site).onChange(async v => {
        s.site = v.trim(); this.plugin.cited.clear(); await this.plugin.save(); this.display() }))
    new Setting(el).setName('Folder in your library').setDesc('The name zemi connect keeps this vault under (its folder\'s name, unless given --name).')
      .addText(t => t.setValue(s.folder).onChange(async v => { s.folder = v.trim(); await this.plugin.save() }))
    new Setting(el).setName('Sync on save')
      .setDesc(s.syncNow ? 'Sync the vault with Zemi a moment after a note is saved, rather than at zemi connect\'s next pass.'
               : 'Set up by zemi obsidian: run it for this vault to sync on save.')
      .addToggle(t => t.setValue(!!s.syncNow && s.syncOnSave !== false).setDisabled(!s.syncNow)
        .onChange(async v => { s.syncOnSave = v; await this.plugin.save() }))
    new Setting(el).setName('Papers folder').setDesc('Where a paper added by its arXiv id or DOI gets its note.')
      .addText(t => t.setValue(s.papersFolder).onChange(async v => { s.papersFolder = v.trim() || 'Papers'; await this.plugin.save() }))
    const signed = this.plugin.zemi.signedIn
    new Setting(el).setName(signed ? 'Signed in' : 'Not signed in')
      .setDesc(!signed ? 'Sign in in your browser: Zemi asks you to approve this vault reading it.'
               : this.plugin.seesTasks ? `To ${s.site}, reading it, your library, and your projects' tasks and findings.`
               : `To ${s.site}, reading it and your library. Sign out and in again to show tasks and findings in notes.`)
      .addButton(b => b.setButtonText(signed ? 'Sign out' : 'Sign in').setCta().onClick(async () => {
        this.plugin.cited.clear()
        if (signed) { s.tokens = null; await this.plugin.save(); this.display(); return }
        try {
          s.tokens = await signIn(s.site)
          await this.plugin.save()
          new Notice('Signed in to Zemi')
        } catch (e: any) { new Notice(`Not signed in: ${e?.message ?? e}`) }
        this.display()
      }))
  }
}

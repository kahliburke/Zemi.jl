<!--
  The editor for everything written in Markdown (see KBRefText.vue, whose multi-line fields it is):
  CodeMirror 6 with Markdown highlighted, LaTeX inside `$…$` too, and `@` offering what to refer to
  (see kbRefs.ts). Three views, the choice remembered: write, split (the editor beside the text as it
  will show, scrolling with it) and preview; and expanded, over the page, for room. Files dropped or
  pasted are attached at the caret (see src/media.jl). ⌘/Ctrl-B, -I, -E and -K mark bold, italic,
  code and a link; ⌘/Ctrl-Enter does what `send` names ("send", "save") by emitting `submit`. With
  `draft`, what is written is kept in the browser across a reload, and comes back when the editor
  opens again; it goes once the text is sent and cleared, or the editor is closed (saved or cancelled).
-->
<script setup lang="ts">
import { ref, shallowRef, watch, onMounted, onBeforeUnmount, nextTick, computed } from 'vue'
import { uploadMedia } from './kbApi'
import { refText, findReferences, type RefMatch } from './kbRefs'
import { loadMarkdown, type Render } from './kbMarkdown'
import { mathSyntax, mathTags, referenceQuery, toggleMark } from './kbEditorSyntax'
import { bytes } from './kbFormat'
import { closeOnEscape } from './kbDialog'

const props = withDefaults(defineProps<{ modelValue: string; rows?: number; placeholder?: string; project?: string; draft?: string;
                                          send?: string }>(), { rows: 3, placeholder: '' })
const emit = defineEmits<{ 'update:modelValue': [string]; submit: [] }>()

type View = 'write' | 'split' | 'preview'
const VIEW_KEY = 'kb-editor-view'
const stored = typeof localStorage === 'undefined' ? null : localStorage.getItem(VIEW_KEY) ?? (localStorage.getItem('kb-preview') === '1' ? 'split' : null)
const view = ref<View>((['write', 'split', 'preview'] as View[]).includes(stored as View) ? stored as View : 'write')
watch(view, v => { localStorage.setItem(VIEW_KEY, v); renderPreview(); if (v !== 'preview') nextTick(() => editor?.focus()) })
const expanded = ref(false)

const host = ref<HTMLElement | null>(null)
const previewEl = ref<HTMLElement | null>(null)
let editor: any = null                      // the CodeMirror view, once loaded
let applying = false                        // a change coming from the model, not typed

// The preview: the text rendered as it will show, a moment after each change.
const markdown = shallowRef<Render | null>(null)
const preview = ref('')
let previewTimer: ReturnType<typeof setTimeout> | undefined
async function renderPreview() {
  if (view.value === 'write' && !expanded.value) return
  markdown.value ??= await loadMarkdown()
  preview.value = props.modelValue.trim() ? markdown.value(props.modelValue, { refs: true }) : ''
}
watch(() => props.modelValue, v => {
  clearTimeout(previewTimer); previewTimer = setTimeout(renderPreview, 150)
  if (editor && !applying && v !== editor.state.doc.toString())
    editor.dispatch({ changes: { from: 0, to: editor.state.doc.length, insert: v } })
  if (props.draft && touched) v.trim() ? localStorage.setItem(draftKey(), v) : localStorage.removeItem(draftKey())
})
// Expanded, it is a dialog over the page, which Escape puts back in place.
let stopEscape = () => {}
watch(expanded, e => {
  stopEscape()
  stopEscape = e ? closeOnEscape(() => { expanded.value = false }) : () => {}
  renderPreview(); nextTick(() => editor?.focus())
})
const draftKey = () => `kb-draft:${props.draft}`
let touched = false                         // written in since it opened: only then is there a draft to keep

// The preview follows the editor's scrolling, at the same share of the way down.
function followScroll() {
  const s = editor?.scrollDOM, p = previewEl.value
  if (!s || !p) return
  const share = s.scrollHeight > s.clientHeight ? s.scrollTop / (s.scrollHeight - s.clientHeight) : 0
  p.scrollTop = share * (p.scrollHeight - p.clientHeight)
}

// Attaching files: a short source file goes in as a code block; anything else is uploaded, held in
// the text as a placeholder that becomes its Markdown once kept, with how much is sent shown below.
const uploads = ref<{ id: number; name: string; share: number; error: string }[]>([])
let uploadCount = 0
const CODE: Record<string, string> = { jl: 'julia', py: 'python', sh: 'bash', toml: 'toml', yaml: 'yaml', yml: 'yaml', json: 'json',
  c: 'c', h: 'c', cpp: 'cpp', f90: 'fortran', m: 'matlab', tex: 'latex', js: 'javascript', ts: 'typescript', vue: 'vue',
  css: 'css', r: 'r', rs: 'rust', md: 'markdown', txt: '' }
const CODE_INLINE = 30_000         // bytes: a source file up to this goes into the text as a code block
function insertBlock(text: string) {
  if (!editor) return
  const { from, to } = editor.state.selection.main
  const before = editor.state.doc.sliceString(0, from)
  const pad = before && !before.endsWith('\n') ? '\n' : ''
  const insert = pad + text + '\n'
  editor.dispatch({ changes: { from, to, insert }, selection: { anchor: from + insert.length }, scrollIntoView: true })
}
function replaceText(find: string, by: string) {
  const i = editor?.state.doc.toString().indexOf(find) ?? -1
  if (i >= 0) editor.dispatch({ changes: { from: i, to: i + find.length, insert: by } })
}
async function attach(files: File[]) {
  for (let file of files) {
    // A pasted screenshot comes as image.png: named for when it was taken.
    if (/^image\.\w+$/.test(file.name)) file = new File([file], `screenshot-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}.${file.name.split('.').pop()}`, { type: file.type })
    const ext = file.name.split('.').pop()!.toLowerCase()
    if (ext in CODE && file.size <= CODE_INLINE) { insertBlock('```' + CODE[ext] + '\n' + (await file.text()).replace(/\n$/, '') + '\n```'); continue }
    const id = ++uploadCount
    const holder = `[uploading ${file.name}…](#upload-${id})`
    insertBlock(holder)
    const u = { id, name: file.name, share: 0, error: '' }
    uploads.value = [...uploads.value, u]
    const set = (patch: Partial<typeof u>) => { uploads.value = uploads.value.map(x => x.id === id ? { ...x, ...patch } : x) }
    try {
      const m = await uploadMedia(file, share => set({ share }), props.project ?? '')
      const shown = m.type.startsWith('image/') || m.type.startsWith('video/')
      replaceText(holder, shown ? `![${m.name}](${m.address})` : `[${m.name}](${m.address}) (${bytes(m.size)})`)
      uploads.value = uploads.value.filter(x => x.id !== id)
    } catch (e: any) {
      replaceText(holder + '\n', ''); replaceText(holder, '')
      set({ error: e.message })
    }
  }
}
const dropping = ref(false)

async function load() {
  const [{ EditorState, EditorSelection }, viewMod, cmds, lang, md, ac, { stex }, { languages }, { parseMixed }, { tags: t }] = await Promise.all([
    import('@codemirror/state'), import('@codemirror/view'), import('@codemirror/commands'), import('@codemirror/language'),
    import('@codemirror/lang-markdown'), import('@codemirror/autocomplete'), import('@codemirror/legacy-modes/mode/stex'),
    import('@codemirror/language-data'), import('@lezer/common'), import('@lezer/highlight')])
  const { EditorView, keymap, placeholder, drawSelection } = viewMod
  const { HighlightStyle, syntaxHighlighting, indentOnInput, bracketMatching, StreamLanguage } = lang
  if (!host.value) return

  // LaTeX inside the mathematics, highlighted as LaTeX.
  const latex = StreamLanguage.define(stex).parser
  const mathInside = { wrap: parseMixed((node: any) => node.name === 'Math' && node.node.firstChild && node.node.lastChild
    ? { parser: latex, overlay: [{ from: node.node.firstChild.to, to: node.node.lastChild.from }] } : null) }

  // `@` and what follows it: the references that match, as the picker on the board offers them.
  const references = async (cx: any) => {
    const line = cx.state.doc.lineAt(cx.pos)
    const typed = referenceQuery(line.text.slice(0, cx.pos - line.from))
    if (!typed) return null
    let found: RefMatch[] = []
    try {
      found = await findReferences(typed.q, props.project)
    } catch { return null }
    if (!found.length) return null
    return { from: line.from + typed.at, filter: false,
             options: found.map((r, i) => ({ label: r.label, detail: r.detail, boost: -i, apply: refText(r) + ' ',
                                             kindLabel: r.kind })) }
  }

  const mark = (m: string) => (v: any) => {
    v.dispatch(v.state.changeByRange((r: any) => {
      const doc = v.state.doc.toString()
      const out = toggleMark(doc, r.from, r.to, m)
      const removing = out.text.length < doc.length
      const changes = removing ? [{ from: r.from - m.length, to: r.from }, { from: r.to, to: r.to + m.length }]
                               : [{ from: r.from, insert: m }, { from: r.to, insert: m }]
      return { changes, range: EditorSelection.range(out.from, out.to) }
    }))
    return true
  }
  const link = (v: any) => {
    const r = v.state.selection.main, text = v.state.sliceDoc(r.from, r.to)
    v.dispatch({ changes: { from: r.from, to: r.to, insert: `[${text}](url)` },
                 selection: { anchor: r.from + text.length + 3, head: r.from + text.length + 6 } })
    return true
  }

  const style = HighlightStyle.define([
    { tag: t.heading, fontWeight: '600', color: 'var(--vp-c-text-1)' },
    { tag: [t.heading1, t.heading2], fontWeight: '700' },
    { tag: t.emphasis, fontStyle: 'italic' },
    { tag: t.strong, fontWeight: '700' },
    { tag: t.strikethrough, textDecoration: 'line-through' },
    { tag: [t.link, t.url], color: 'var(--vp-c-brand-1)' },
    { tag: t.monospace, fontFamily: 'var(--vp-font-family-mono)', color: 'var(--vp-c-text-code, var(--vp-c-brand-2))' },
    { tag: [t.processingInstruction, t.contentSeparator, t.meta], color: 'var(--vp-c-text-3)' },
    { tag: t.quote, color: 'var(--vp-c-text-2)', fontStyle: 'italic' },
    { tag: mathTags.math, color: 'var(--vp-c-yellow-1, #d4a72c)' },
    { tag: t.keyword, color: 'var(--vp-c-purple-1, #a879e6)' },
    { tag: [t.string, t.special(t.string)], color: 'var(--vp-c-green-1, #3dd68c)' },
    { tag: [t.number, t.bool, t.atom], color: 'var(--vp-c-orange-1, #e2a04a)' },
    { tag: t.comment, color: 'var(--vp-c-text-3)', fontStyle: 'italic' },
    { tag: [t.function(t.variableName), t.function(t.propertyName)], color: 'var(--vp-c-indigo-1, #6ea8fe)' },
    { tag: [t.typeName, t.className], color: 'var(--vp-c-yellow-1, #d4a72c)' },
    { tag: t.tagName, color: 'var(--vp-c-red-1, #f66f81)' },
  ])
  const theme = EditorView.theme({
    '&': { backgroundColor: 'var(--vp-c-bg-soft)', color: 'var(--vp-c-text-1)', borderRadius: '6px', border: '1px solid var(--vp-c-divider)',
           fontSize: '0.92rem' },
    '&.cm-focused': { outline: 'none', borderColor: 'var(--vp-c-brand-1)' },
    '.cm-scroller': { fontFamily: 'var(--vp-font-family-base)', lineHeight: '1.55', overflow: 'auto' },
    '.cm-content': { padding: '0.35rem 0', caretColor: 'var(--vp-c-text-1)', minHeight: `${props.rows * 1.55}em` },
    '.cm-line': { padding: '0 0.55rem' },
    '.cm-placeholder': { color: 'var(--vp-c-text-3)' },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection': { backgroundColor: 'var(--vp-c-brand-soft) !important' },
    '.cm-cursor': { borderLeftColor: 'var(--vp-c-text-1)' },
    '.cm-tooltip': { border: '1px solid var(--vp-c-divider)', borderRadius: '8px', backgroundColor: 'var(--vp-c-bg)', boxShadow: 'var(--vp-shadow-3)' },
    '.cm-tooltip.cm-tooltip-autocomplete > ul': { fontFamily: 'var(--vp-font-family-base)', fontSize: '0.88rem', maxHeight: '18rem', maxWidth: '34rem' },
    '.cm-tooltip-autocomplete > ul > li': { padding: '0.25rem 0.5rem !important', borderRadius: '6px' },
    '.cm-tooltip-autocomplete > ul > li[aria-selected]': { backgroundColor: 'var(--vp-c-default-soft)', color: 'var(--vp-c-text-1)' },
    '.cm-completionLabel': { color: 'var(--vp-c-text-1)' },
    '.cm-completionDetail': { marginLeft: '0.6rem', color: 'var(--vp-c-text-2)', fontStyle: 'normal', fontSize: '0.82em' },
    '.cm-completionIcon': { display: 'none' },
    '.cm-kind': { display: 'inline-block', width: '4.2rem', fontSize: '0.68rem', letterSpacing: '0.04em', textTransform: 'uppercase',
                  color: 'var(--vp-c-text-3)' },
  })

  editor = new EditorView({
    parent: host.value,
    state: EditorState.create({
      doc: props.modelValue,
      extensions: [
        md.markdown({ codeLanguages: languages, extensions: [mathSyntax, mathInside] }),
        syntaxHighlighting(style), theme, EditorView.lineWrapping, drawSelection(), indentOnInput(), bracketMatching(),
        cmds.history(), placeholder(props.placeholder),
        ac.autocompletion({ override: [references], icons: false,
          addToOptions: [{ position: 20, render: (c: any) => { const s = document.createElement('span'); s.className = 'cm-kind'; s.textContent = c.kindLabel ?? ''; return s } }] }),
        keymap.of([
          { key: 'Mod-Enter', run: () => { if (!props.send) return false; emit('submit'); return true } },
          { key: 'Mod-b', run: mark('**') }, { key: 'Mod-i', run: mark('*') }, { key: 'Mod-e', run: mark('`') }, { key: 'Mod-k', run: link },
          ...ac.completionKeymap, ...md.markdownKeymap, ...cmds.defaultKeymap, ...cmds.historyKeymap,
        ]),
        EditorView.updateListener.of((u: any) => {
          if (!u.docChanged) return
          touched = true
          applying = true
          emit('update:modelValue', u.state.doc.toString())
          nextTick(() => { applying = false })
        }),
        EditorView.domEventHandlers({
          paste: (e: ClipboardEvent) => { const f = [...(e.clipboardData?.files ?? [])]; if (!f.length) return false; e.preventDefault(); attach(f); return true },
          drop: (e: DragEvent) => { dropping.value = false; const f = [...(e.dataTransfer?.files ?? [])]; if (!f.length) return false; e.preventDefault(); attach(f); return true },
          dragover: () => { dropping.value = true; return false },
          dragleave: () => { dropping.value = false; return false },
        }),
      ],
    }),
  })
  editor.scrollDOM.addEventListener('scroll', followScroll)
}

onMounted(async () => {
  // A draft kept from before a reload comes back.
  const kept = props.draft ? localStorage.getItem(draftKey()) : null
  if (kept && kept !== props.modelValue) { touched = true; emit('update:modelValue', kept); await nextTick() }
  await load()
  renderPreview()
})
onBeforeUnmount(() => {
  stopEscape()
  editor?.destroy(); editor = null
  if (props.draft) localStorage.removeItem(draftKey())       // saved or cancelled: a reload does not unmount
})

const showEditor = computed(() => view.value !== 'preview' || expanded.value)
const showPreview = computed(() => view.value !== 'write' || expanded.value)
defineExpose({ focus: () => editor?.focus() })
</script>

<template>
  <Teleport to="body" :disabled="!expanded">
    <div v-if="expanded" class="kbe-backdrop" @click="expanded = false"></div>
    <div class="kbe" :class="{ expanded, dropping }" :role="expanded ? 'dialog' : undefined" :aria-modal="expanded || undefined"
         :aria-label="expanded ? 'Editor' : undefined">
      <div class="kbe-panes" :class="{ split: showEditor && showPreview }">
        <div v-show="showEditor" ref="host" class="kbe-editor"></div>
        <div v-if="showPreview" ref="previewEl" class="kbe-preview kb-md" aria-live="polite">
          <div v-if="preview" v-html="preview"></div><span v-else class="kbe-empty">Nothing to preview</span></div>
      </div>
      <div class="kbe-foot">
        <span class="kbe-hint">Markdown · $math$ · @ to refer · drop files<template v-if="send"> · ⌘↵ {{ send }}</template></span>
        <span class="kbe-views" role="group" aria-label="View">
          <button v-for="v in (['write', 'split', 'preview'] as const)" :key="v" type="button" :aria-pressed="view === v" @click="view = v">{{ v }}</button>
        </span>
        <button type="button" class="kbe-expand" :aria-pressed="expanded" :title="expanded ? 'Back in place (Esc)' : 'Expand'"
                :aria-label="expanded ? 'Back in place' : 'Expand'" @click="expanded = !expanded">{{ expanded ? '⤡' : '⤢' }}</button>
      </div>
      <ul v-if="uploads.length" class="kbe-uploads">
        <li v-for="u in uploads" :key="u.id" :class="{ failed: u.error }">
          <span class="kbe-upload-name">{{ u.name }}</span>
          <span v-if="u.error" class="kb-error">{{ u.error }}</span>
          <template v-else><span class="kbe-upload-bar"><span :style="{ width: Math.round(u.share * 100) + '%' }"></span></span>{{ Math.round(u.share * 100) }}%</template>
          <button v-if="u.error" type="button" class="kbe-upload-dismiss" aria-label="Dismiss" @click="uploads = uploads.filter(x => x.id !== u.id)">✕</button>
        </li>
      </ul>
    </div>
  </Teleport>
</template>

<style scoped>
.kbe { display: block; width: 100%; }
.kbe-panes { display: block; }
/* Side by side where there is room for both, the preview under the editor where there is not. */
.kbe-panes.split { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 17rem), 1fr)); gap: 0.5rem; }
.kbe-editor { min-width: 0; }
.kbe-editor :deep(.cm-editor) { max-height: 24rem; }
.kbe.dropping .kbe-editor :deep(.cm-editor) { border-color: var(--vp-c-brand-1); background: var(--vp-c-brand-soft); }
.kbe-preview { min-width: 0; min-height: 3rem; max-height: 24rem; overflow-y: auto; padding: 0.35rem 0.6rem; border-radius: 6px;
  border: 1px dashed var(--vp-c-divider); font-size: 0.9rem; }
.kbe-empty { color: var(--vp-c-text-3); font-size: 0.8rem; }
.kbe-foot { display: flex; align-items: center; gap: 0.5rem; margin-top: 0.2rem; }
.kbe-hint { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 0.72rem; color: var(--vp-c-text-3); }
.kbe-views { display: inline-flex; border: 1px solid var(--vp-c-divider); border-radius: 999px; overflow: hidden; }
.kbe-views button { padding: 0.05rem 0.55rem; border: none; background: none; color: var(--vp-c-text-2); font: inherit; font-size: 0.72rem; cursor: pointer; }
.kbe-views button[aria-pressed="true"] { background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kbe-expand { width: 1.6rem; height: 1.4rem; padding: 0; border: 1px solid var(--vp-c-divider); border-radius: 6px; background: none;
  color: var(--vp-c-text-2); font-size: 0.85rem; cursor: pointer; }
.kbe-expand:hover, .kbe-expand[aria-pressed="true"] { border-color: var(--vp-c-brand-1); color: var(--vp-c-brand-1); }
/* Expanded: over the page, the editor beside the preview at full height. */
.kbe-backdrop { position: fixed; inset: 0; z-index: 90; background: rgba(0, 0, 0, 0.45); }
.kbe.expanded { position: fixed; z-index: 91; inset: 5vh 4vw; display: flex; flex-direction: column; padding: 0.8rem; border-radius: 12px;
  background: var(--vp-c-bg); border: 1px solid var(--vp-c-divider); box-shadow: var(--vp-shadow-5); }
.kbe.expanded .kbe-panes { flex: 1; min-height: 0; display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 0.8rem; }
.kbe.expanded .kbe-editor, .kbe.expanded .kbe-preview { min-height: 0; max-height: none; height: 100%; }
.kbe.expanded .kbe-editor :deep(.cm-editor) { height: 100%; max-height: none; }
.kbe-uploads { list-style: none; margin: 0.25rem 0 0; padding: 0; font-size: 0.8rem; color: var(--vp-c-text-2); }
.kbe-uploads li { display: flex; gap: 0.5rem; align-items: center; padding: 0.1rem 0; }
.kbe-upload-name { max-width: 16rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.kbe-upload-bar { width: 8rem; height: 4px; border-radius: 2px; background: var(--vp-c-default-soft); overflow: hidden; }
.kbe-upload-bar span { display: block; height: 100%; background: var(--vp-c-brand-1); transition: width 0.2s; }
.kbe-upload-dismiss { border: none; background: none; color: var(--vp-c-text-3); cursor: pointer; }
</style>

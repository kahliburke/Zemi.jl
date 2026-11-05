<!--
  Discussing a paper with the tutor, from its page, while zemi serves the knowledge base API: a drawer
  beside the paper (which stays readable) holding the conversation, earlier conversations about the
  paper, and suggestions to start from. The tutor's replies are Markdown with LaTeX, rendered here as
  they are written; its [arXiv:id] citations link to the papers' pages.
-->
<script setup lang="ts">
import KBTitle from './KBTitle.vue'
import { ref, computed, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { api, mode, connect, post, getJSON, can } from './kbApi'
import { loadPapers } from './kbData'
import { pageSlug } from './kbLinks'
import { loadMarkdown } from './kbMarkdown'
import { todayUtc } from './kbFormat'
import { profile, optedOut, surveyOpen, loadProfile, profileText } from './kbProfile'
import KBProfileSurvey from './KBProfileSurvey.vue'

const props = defineProps<{ id: string; title?: string }>()

type Message = { role: string; text: string; status: string }
type Chat = { id: string; title: string; updated_at: string; messages: number }
const open = ref(false)
// The drawer at full width, for pages and long conversations; remembered in this browser.
const wide = ref(false)
function toggleWide() { wide.value = !wide.value; localStorage.setItem('kb-tutor-wide', wide.value ? '1' : '') }
const chats = ref<Chat[]>([])
const chat = ref<string | null>(null)
const messages = ref<Message[]>([])
const draft = ref('')
const error = ref('')
const doing = ref<string | null>(null)       // what the tutor is doing before it writes: reading, searching…
const notebook = ref<string | null>(null)    // the tutor's live Julia notebook, once it has one
const scroller = ref<HTMLElement | null>(null)
let render: ((s: string) => string) | null = null
let polling: ReturnType<typeof setTimeout> | undefined

const STARTERS = [
  'Explain this paper as if I had just joined the group.',
  'What terms, acronyms and notation should I know to read it?',
  'What problem does it address, and what did people do before it?',
  'What open questions does it leave, and what does it assume?',
  'How does it touch our group\'s work?',
  'What should I read before and after it?']

// A link to a conversation (`?chat=<id>` on the paper's page) opens it, to pick it up again.
onMounted(async () => {
  wide.value = localStorage.getItem('kb-tutor-wide') === '1'
  await connect()
  const linked = new URLSearchParams(location.search).get('chat')
  if (linked && mode.value === 'live') {
    await openDrawer()
    try { await load(linked) } catch { fresh(); error.value = 'No such conversation, or not one of yours.' }
  }
})
// Gone from the page: its polling stops, and leaves the next page's address alone.
let gone = false
onBeforeUnmount(() => { gone = true; clearTimeout(polling); stopTicking() })

// Markdown with LaTeX and highlighted code (see kbMarkdown.ts), loaded with the drawer: the page
// itself is rendered without it. Citations of papers become links to their pages, or to arXiv for
// those the knowledge base does not hold (all of them, should its list of papers not load).
async function renderer() {
  if (render) return render
  const [md, papers] = await Promise.all([loadMarkdown(), loadPapers().catch(() => [])])
  const titles = new Map(papers.map(p => [p.id, p.title]))
  render = (s: string) => md(s, { refs: true, titles })
  return render
}
const html = ref<string[]>([])

// What the tutor made in its conversation's files/, served by the API: figures in place, and each page
// it links in a sandboxed frame under the paragraph that links it. Code blocks get a copy button.
function filesUrl(id: string) { return `${api.value}/api/chat/${id}/files/` }
function dressed(rendered: string): string {
  const doc = new DOMParser().parseFromString(`<div>${rendered}</div>`, 'text/html')
  const root = doc.body.firstElementChild!
  if (chat.value) {
    const base = filesUrl(chat.value)
    root.querySelectorAll('img[src^="files/"]').forEach(img => img.setAttribute('src', base + img.getAttribute('src')!.slice(6)))
    root.querySelectorAll('a[href^="files/"]').forEach(a => {
      const url = base + a.getAttribute('href')!.slice(6)
      a.setAttribute('href', url); a.setAttribute('target', '_blank'); a.setAttribute('rel', 'noopener')
      if (!/\.html?$/i.test(url)) return
      const frame = doc.createElement('iframe')
      frame.className = 'kbc-page'
      frame.setAttribute('src', url); frame.setAttribute('sandbox', 'allow-scripts'); frame.setAttribute('title', a.textContent ?? 'page')
      ;(a.closest('p, li') ?? a).after(frame)
    })
  }
  root.querySelectorAll('pre').forEach(pre => {
    const b = doc.createElement('button')
    b.type = 'button'; b.className = 'kbc-copy'; b.textContent = 'copy'
    pre.classList.add('kbc-code'); pre.appendChild(b)
  })
  return root.innerHTML
}
// Copying a code block, from the button `dressed` gives it.
async function onClick(e: MouseEvent) {
  const b = (e.target as HTMLElement).closest('.kbc-copy') as HTMLElement | null
  if (!b) return
  await navigator.clipboard.writeText(b.parentElement?.querySelector('code')?.textContent ?? '')
  b.textContent = 'copied'
  setTimeout(() => (b.textContent = 'copy'), 1500)
}
// Scrolled only when asked: to the latest message on opening a conversation or sending one. A reply
// coming in leaves the reader where they are.
async function show(scroll = false) {
  const r = await renderer()
  html.value = messages.value.map(m => m.role === 'user' ? '' : dressed(r(m.text || '')))
  await nextTick()
  if (surveyOpen.value) scroller.value?.scrollTo({ top: 0 })
  else if (scroll) scroller.value?.scrollTo({ top: scroller.value.scrollHeight })
}

async function openDrawer() {
  open.value = true
  error.value = ''
  // The first time, the short survey that tailors the tutoring (unless declined); it can be retaken in settings.
  loadProfile()
  if (!profile.value && !optedOut.value) surveyOpen.value = true
  try {
    chats.value = await getJSON(`/api/chats/${encodeURIComponent(props.id)}`)
    if (chats.value.length && chat.value === null) await load(chats.value[0].id)
    else await show(true)
  } catch (e: any) { error.value = e.message ?? String(e) }
}

async function load(id: string, scroll = true) {
  if (gone) return
  const c = await getJSON(`/api/chat/${id}`)
  if (gone) return
  chat.value = id
  history.replaceState(null, '', `?chat=${id}`)
  messages.value = c.messages
  doing.value = c.doing ?? null
  notebook.value = c.notebook ?? null
  await show(scroll)
  clearTimeout(polling)
  const waiting = messages.value.some(m => m.status === 'thinking')
  waiting ? tick() : stopTicking()
  if (waiting) polling = setTimeout(() => load(id, false), 1500)
}

function close() { open.value = false; clearTimeout(polling); stopTicking() }

// The conversation's permalink, and the conversation as Markdown: the tutor's replies as written.
const copied = ref(false)
async function copyLink() {
  if (!chat.value) return
  const url = `${location.origin}${location.pathname}?chat=${chat.value}`
  await navigator.clipboard.writeText(url)
  history.replaceState(null, '', `?chat=${chat.value}`)
  copied.value = true
  setTimeout(() => (copied.value = false), 2000)
}
function saveMarkdown() {
  const page = `${location.origin}${location.pathname}`
  const lines = [`# Tutoring: ${props.title ?? props.id}`, '',
    `Paper: [${props.title ?? props.id}](${page}) · [arXiv:${props.id}](https://arxiv.org/abs/${props.id})`, '',
    `Saved ${new Date().toLocaleString()}${chat.value ? ` · continue at ${page}?chat=${chat.value}` : ''}`, '']
  for (const m of messages.value) {
    if (m.status === 'thinking') continue
    const text = chat.value ? m.text.trim().replace(/\]\(files\//g, `](${filesUrl(chat.value)}`) : m.text.trim()
    lines.push(m.role === 'user' ? '## You' : '## Tutor', '', text, '')
  }
  const blob = new Blob([lines.join('\n')], { type: 'text/markdown' })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = `tutoring-${pageSlug(props.id)}-${todayUtc()}.md`
  a.click()
  URL.revokeObjectURL(a.href)
}
function fresh() {
  chat.value = null; messages.value = []; html.value = []; doing.value = null; notebook.value = null; clearTimeout(polling); stopTicking()
  history.replaceState(null, '', location.pathname)
}
const thinking = computed(() => messages.value.some(m => m.status === 'thinking'))

// How long the tutor has been at it, counted from when this page saw it start.
const since = ref<number | null>(null)
const now = ref(Date.now())
let ticker: ReturnType<typeof setInterval> | undefined
function tick() {
  since.value ??= Date.now()
  ticker ??= setInterval(() => (now.value = Date.now()), 1000)
}
function stopTicking() { clearInterval(ticker); ticker = undefined; since.value = null }
const elapsed = computed(() => since.value === null ? 0 : Math.max(0, Math.round((now.value - since.value) / 1000)))

async function send(text = draft.value) {
  text = text.trim()
  if (!text || thinking.value) return
  error.value = ''
  draft.value = ''
  messages.value = [...messages.value, { role: 'user', text, status: 'done' }, { role: 'tutor', text: '', status: 'thinking' }]
  since.value = Date.now()
  tick()
  await show(true)
  try {
    const r = await post('/api/chat', JSON.stringify({ paper: props.id, message: text, chat: chat.value, profile: profileText() }))
    if (!chat.value) chats.value = [{ id: r.chat, title: text.slice(0, 80), updated_at: '', messages: 2 }, ...chats.value]
    await load(r.chat, false)
  } catch (e: any) { error.value = e.message ?? String(e) }
}
const key = (e: KeyboardEvent) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() } }
</script>

<template>
  <div v-if="mode === 'live' && can('tutor')" class="kbc">
    <button type="button" class="kb-primary kbc-open" @click="openDrawer">Ask the tutor</button>
    <div v-if="open" :class="['kbc-drawer', { wide }]">
      <div class="kbc-head">
        <div class="kbc-title">Tutor<span v-if="title"> · <KBTitle :text="title" /></span></div>
        <span class="kbc-head-actions">
          <button type="button" class="kbc-x kbc-size" :title="wide ? 'restore' : 'maximize'" @click="toggleWide">{{ wide ? '⤡' : '⤢' }}</button>
          <button type="button" class="kbc-x" title="close" @click="close">×</button>
        </span>
      </div>
      <div class="kbc-bar">
        <select v-if="chats.length" class="kbc-select" :value="chat ?? ''" @change="($event.target as HTMLSelectElement).value ? load(($event.target as HTMLSelectElement).value) : fresh()">
          <option value="">New</option>
          <option v-for="c in chats" :key="c.id" :value="c.id">{{ c.title }}</option>
        </select>
        <button v-if="chat" type="button" class="kb-link kbc-link" @click="fresh">new</button>
        <span class="kbc-spacer"></span>
        <a v-if="notebook" class="kb-link kbc-link" :href="notebook" target="_blank" rel="noopener"
           title="Live notebook">notebook</a>
        <button v-if="chat" type="button" class="kb-link kbc-link" title="Link to this conversation" @click="copyLink">
          {{ copied ? 'link copied' : 'copy link' }}</button>
        <button v-if="messages.length" type="button" class="kb-link kbc-link" @click="saveMarkdown">save .md</button>
      </div>
      <div ref="scroller" class="kbc-messages" @click="onClick">
        <KBProfileSurvey v-if="surveyOpen" @done="surveyOpen = false" />
        <div v-else-if="!messages.length" class="kbc-start">
          <button v-for="s in STARTERS" :key="s" type="button" class="kbc-starter" @click="send(s)">{{ s }}</button>
        </div>
        <div v-for="(m, i) in (surveyOpen ? [] : messages)" :key="i" :class="['kbc-msg', m.role, m.status]">
          <div v-if="m.role === 'user'" class="kbc-user">{{ m.text }}</div>
          <div v-else class="kbc-tutor">
            <div class="kb-md" v-html="html[i]"></div>
            <div v-if="m.status === 'thinking'" class="kbc-working" role="status">
              <span class="kbc-dots" aria-hidden="true"><i></i><i></i><i></i></span>
              <span>{{ m.text ? 'writing' : (doing ?? 'thinking') }}</span>
              <span class="kbc-elapsed">{{ elapsed }}s</span>
            </div>
          </div>
        </div>
      </div>
      <p v-if="error" class="kb-error kbc-error">{{ error }}</p>
      <div class="kbc-input">
        <textarea v-model="draft" rows="3" placeholder="Ask… (Enter to send)" @keydown="key"></textarea>
        <button type="button" class="kb-primary kbc-send" :disabled="thinking || !draft.trim()" @click="send()">Send</button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.kbc { margin: 0.4rem 0; }
.kbc-open { padding: 0.35rem 0.9rem; }
.kbc-drawer { position: fixed; top: var(--vp-nav-height, 64px); right: 0; bottom: 0; width: min(46rem, 48vw); z-index: calc(var(--vp-z-index-nav, 30) - 1);
  display: flex; flex-direction: column; background: var(--vp-c-bg); border-left: 1px solid var(--vp-c-divider);
  box-shadow: -8px 0 24px rgba(0, 0, 0, 0.25); }
@media (max-width: 900px) { .kbc-drawer { width: 100vw; } }
.kbc-drawer.wide { width: 100vw; }
.kbc-drawer.wide .kbc-messages, .kbc-drawer.wide .kbc-input { padding-left: max(1rem, calc((100vw - 72rem) / 2)); padding-right: max(1rem, calc((100vw - 72rem) / 2)); }
.kbc-drawer.wide .kbc-tutor :deep(iframe.kbc-page) { height: 75vh; }
.kbc-head-actions { display: flex; align-items: center; gap: 0.6rem; }
.kbc-size { font-size: 1.15rem; }
.kbc-head { display: flex; align-items: center; justify-content: space-between; padding: 0.6rem 1rem; border-bottom: 1px solid var(--vp-c-divider); }
.kbc-title { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.kbc-x { background: none; border: none; font-size: 1.5rem; color: var(--vp-c-text-2); cursor: pointer; }
.kbc-bar { display: flex; gap: 0.8rem; align-items: center; padding: 0.4rem 1rem; }
.kbc-select { flex: 0 1 auto; min-width: 0; max-width: 60%; padding: 0.2rem 0.4rem; border-radius: 6px; border: 1px solid var(--vp-c-divider);
  background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font: inherit; font-size: 0.85rem; }
.kbc-messages { flex: 1; overflow-y: auto; overflow-x: hidden; padding: 0.5rem 1rem 1rem; min-width: 0; }
.kbc-start p { color: var(--vp-c-text-2); font-size: 0.9rem; }
.kbc-starter { display: block; width: 100%; text-align: left; margin: 0.35rem 0; padding: 0.45rem 0.7rem; border-radius: 8px;
  border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font: inherit; font-size: 0.88rem;
  line-height: 1.4; white-space: normal; height: auto; cursor: pointer; }
.kbc-starter:hover { border-color: var(--vp-c-brand-1); }
.kbc-msg { margin: 0.8rem 0; }
.kbc-user { margin-left: 15%; padding: 0.5rem 0.8rem; border-radius: 10px; background: var(--vp-c-brand-soft); white-space: pre-wrap; }
.kbc-tutor { font-size: 0.95rem; line-height: 1.6; }
.kbc-tutor :deep(pre) { overflow-x: auto; }
.kbc-tutor :deep(pre.kbc-code) { position: relative; padding: 0.7rem 0.9rem; border-radius: 8px; background: var(--vp-code-block-bg); font-size: 0.85rem; }
.kbc-tutor :deep(.kbc-copy) { position: absolute; top: 0.35rem; right: 0.45rem; padding: 0.1rem 0.45rem; border-radius: 5px; font-size: 0.72rem;
  border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg); color: var(--vp-c-text-2); cursor: pointer; opacity: 0.7; }
.kbc-tutor :deep(.kbc-copy:hover) { opacity: 1; }
.kbc-tutor :deep(img) { max-width: 100%; border-radius: 6px; }
.kbc-tutor :deep(iframe.kbc-page) { display: block; width: 100%; height: 480px; margin: 0.5rem 0 0.8rem; resize: vertical;
  border: 1px solid var(--vp-c-divider); border-radius: 8px; background: var(--vp-c-bg-soft); }
.kbc-tutor :deep(mjx-container) { overflow-x: auto; overflow-y: hidden; }
.kbc-msg.failed .kbc-tutor { color: var(--vp-c-danger-1); }
.kbc-working { display: flex; align-items: center; gap: 0.55rem; margin-top: 0.3rem; padding: 0.45rem 0.7rem;
  border-radius: 8px; background: var(--vp-c-bg-soft); color: var(--vp-c-text-2); font-size: 0.85rem; }
.kbc-elapsed { margin-left: auto; font-variant-numeric: tabular-nums; color: var(--vp-c-text-3); }
.kbc-dots { display: inline-flex; gap: 4px; }
.kbc-dots i { width: 7px; height: 7px; border-radius: 50%; background: var(--vp-c-brand-1); animation: kbc-pulse 1.2s ease-in-out infinite; }
.kbc-dots i:nth-child(2) { animation-delay: 0.2s; }
.kbc-dots i:nth-child(3) { animation-delay: 0.4s; }
@keyframes kbc-pulse { 0%, 80%, 100% { opacity: 0.25; transform: scale(0.75); } 40% { opacity: 1; transform: scale(1); } }
@media (prefers-reduced-motion: reduce) { .kbc-dots i { animation: none; } }
.kbc-error { padding: 0 1rem; }
.kbc-input { display: flex; gap: 0.5rem; padding: 0.6rem 1rem 0.9rem; border-top: 1px solid var(--vp-c-divider); }
.kbc-input textarea { flex: 1; resize: vertical; padding: 0.5rem 0.7rem; font: inherit; border-radius: 8px;
  border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.kbc-send { align-self: flex-end; }
.kbc-send:disabled { opacity: 0.5; cursor: default; }
.kbc-link { flex: none; white-space: nowrap; font-size: 0.85rem; }
.kbc-spacer { flex: 1; }
</style>

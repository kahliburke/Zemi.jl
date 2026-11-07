<!--
  Findings (see src/findings.jl): a project's findings listed beside the one open, which reads as a
  short write-up with its sources alongside: what it was added as evidence and what its text cites
  with @-references, grouped by kind. Below the write-up, its activity: comments from people and
  agents among its changes (see src/finding_comments.jl). Started from a project or from a task on the board; agents
  draft them from their work. The address names a project (#KB), a finding (#KB-F3), or a new one
  in a project or from a task (#new/KB, #new/KB-12). Refreshed while open.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import KBTitle from './KBTitle.vue'
import { ref, shallowRef, computed, watch, onMounted, onBeforeUnmount } from 'vue'
import { getJSON, post, can, mediaUrl, me, latest, isStale, onLive } from './kbApi'
import { loadMarkdown, escapeText, type Render } from './kbMarkdown'
import { sourceHref as refSourceHref, refFor, onTaskRef, setCodebase } from './kbRefs'
import { splitCodeTarget } from './kbKinds'
import { projectHref, taskHref, findingHref } from './kbLinks'
import { day, when } from './kbFormat'
import KBRefText from './KBRefText.vue'
import KBIcon from './KBIcon.vue'
import KBCite from './KBCite.vue'

type Project = { key: string; name: string; codebase: string; access: string }
type Row = { ref: string; claim: string; status: string; created_by: string; by_agent: boolean; updated_at: string; recheck: string[] }
type Source = { kind: string; target: string; label: string; relation: string; excerpt: string; page: number; note: string;
                detail: Record<string, string>; evidence: number; cited: boolean }
type Finding = Row & { project: string; body: string; created_at: string; status_reason: string; status_by: string; archived_at: string;
                       archived_by: string; sources: Source[]; versions: number; activity: Activity[];
                       used_by: { ref: string; claim: string; status: string; relation: string }[] }
type Activity = { kind: string; id: number; who: string; by_agent: boolean; at: string; text: string; edited: boolean }
type Version = { claim: string; body: string; status: string; status_reason: string; changed_by: string; by_agent: boolean; changed_at: string }
const STATUSES = ['draft', 'accepted', 'contested', 'superseded']

const projects = ref<Project[]>([])
const key = ref('')
const rows = ref<Row[]>([])
const status = ref('')                                   // the list's filter, '' for all
const q = ref('')                                        // a search, which orders the list by how well each matches
const archived = ref(false)                              // listing the archived findings instead
const f = ref<Finding | null>(null)
const versions = ref<Version[] | null>(null)
const draft = ref<{ claim: string; body: string; task: string } | null>(null)   // a finding being written or edited
const error = ref('')
const markdown = shallowRef<Render>(escapeText)
const render = (s: string) => markdown.value(s, { refs: true })

const project = computed(() => projects.value.find(p => p.key === key.value))
const editable = computed(() => can('tasks.edit') && ['contributor', 'maintainer'].includes(project.value?.access ?? ''))
const shown = computed(() => status.value ? rows.value.filter(r => r.status === status.value) : rows.value)
const count = (s: string) => rows.value.filter(r => r.status === s).length
const creating = computed(() => draft.value !== null && f.value === null)

// The address: #KB, #KB-F3, #new/KB or #new/KB-12.
function route() {
  const h = decodeURIComponent(location.hash.slice(1)).toUpperCase()
  let m = h.match(/^NEW\/([A-Z][A-Z0-9]*)(?:-(\d+))?$/)
  if (m) return { key: m[1], finding: '', task: m[2] ? `${m[1]}-${m[2]}` : '', create: true }
  m = h.match(/^([A-Z][A-Z0-9]*)(?:-F(\d+))?$/)
  return m ? { key: m[1], finding: m[2] ? h : '', task: '', create: false } : { key: '', finding: '', task: '', create: false }
}
const go = (h: string) => { if (location.hash.slice(1) !== h) location.hash = h; else onHash() }
async function onHash() {
  const r = route()
  error.value = ''
  const k = r.key && projects.value.some(p => p.key === r.key) ? r.key : key.value || projects.value[0]?.key || ''
  if (k !== key.value) { key.value = k; setCodebase(project.value?.codebase ?? ''); await loadList() }
  versions.value = null
  if (r.create) { f.value = null; draft.value = { claim: '', body: '', task: r.key === k ? r.task : '' }; return }
  draft.value = null
  const ref = r.finding || rows.value[0]?.ref
  if (ref) await open(ref); else f.value = null
}
async function loadList() {
  if (!key.value) return
  const search = archived.value ? '&archived=1' : q.value.trim() ? `&q=${encodeURIComponent(q.value.trim())}` : ''
  try { rows.value = await getJSON(`/api/findings?project=${key.value}${search}`) } catch (e: any) { error.value = e.message }
}
let searchTimer: ReturnType<typeof setTimeout> | undefined
watch(q, () => { clearTimeout(searchTimer); archived.value = false; searchTimer = setTimeout(loadList, 250) })
const toggleArchived = () => { archived.value = !archived.value; status.value = ''; loadList() }
// Of several findings clicked in turn, the last one opens.
const opening = latest()
watch(f, v => { if (!v) opening.cancel() })
async function open(ref: string) {
  if (f.value?.ref !== ref) asking.value = null
  try { f.value = await opening(signal => getJSON(`/api/findings/${ref}`, { signal })) }
  catch (e: any) { if (!isStale(e)) { f.value = null; error.value = e.message } }
}
const chooseProject = (k: string) => go(k)

// A finding whose evidence changed: it still holds, or an agent is asked to re-check it (a task, linked here).
const recheckTask = ref('')
async function askRecheck() {
  recheckTask.value = (await change<Finding & { task: string }>({ agent: true }, '/recheck'))?.task ?? ''
}
// A change to the open finding: the API answers with the finding as it now is (and what else the change made).
async function change<T extends Finding = Finding>(body: Record<string, unknown>, path = ''): Promise<T | undefined> {
  if (!f.value) return
  try {
    const r: T = await post(`/api/findings/${f.value.ref}${path}`, JSON.stringify(body))
    f.value = r; error.value = ''; loadList()
    return r
  } catch (e: any) { error.value = e.message }
}
async function save() {
  const d = draft.value
  if (!d || !d.claim.trim()) return
  if (f.value) {
    await change({ claim: d.claim, body: d.body })
    if (!error.value) draft.value = null
    return
  }
  try {
    const made = await post('/api/findings', JSON.stringify({ project: key.value, claim: d.claim, body: d.body, task: d.task }))
    await loadList(); go(made.ref)
  } catch (e: any) { error.value = e.message }
}
function cancel() {
  if (creating.value) { history.length > 1 && route().task ? history.back() : go(key.value) }
  else draft.value = null
}
// A person accepts a finding, contests or supersedes it with a reason, or returns it to draft.
const asking = ref<{ status: string; reason: string } | null>(null)
async function setStatus(status: string, reason?: string) {
  await change(reason === undefined ? { status } : { status, reason })
  if (!error.value) asking.value = null
}
// A draft made by mistake is deleted; any finding can be archived, and brought back.
async function remove() {
  if (!f.value || !confirm(`Delete ${f.value.ref}? Its history goes with it.`)) return
  try { await post(`/api/findings/${f.value.ref}/delete`, '{}'); f.value = null; await loadList(); go(key.value) }
  catch (e: any) { error.value = e.message }
}
const archive = (restore = false) => change({ restore }, '/archive')
async function showVersions() {
  if (versions.value || !f.value) { versions.value = null; return }
  try { versions.value = await getJSON(`/api/findings/${f.value.ref}/versions`) } catch (e: any) { error.value = e.message }
}

// Comments, and correcting one's own.
const comment = ref('')
const editingComment = ref<{ id: number; text: string } | null>(null)
async function sendComment() {
  if (!comment.value.trim()) return
  await change({ text: comment.value }, '/comments')
  if (!error.value) comment.value = ''
}
async function saveComment() {
  const c = editingComment.value
  if (!c || !c.text.trim()) return
  await change({ text: c.text }, `/comments/${c.id}`)
  if (!error.value) editingComment.value = null
}
const mine = (a: Activity) => a.kind === 'comment' && !a.by_agent && a.who === me.value?.name

// Sources, grouped by kind; a finding's sources by how it relates to them.
const GROUPS: [string, string, (s: Source) => boolean][] = [
  ['From', 'task', s => s.kind === 'task'],
  ['Papers', 'paper', s => s.kind === 'paper'],
  ['Notebooks', 'notebook', s => s.kind === 'notebook'],
  ['Code', 'code', s => s.kind === 'code'],
  ['Results', 'result', s => s.kind === 'result'],
  ['Builds on', 'finding', s => s.kind === 'finding' && s.relation !== 'contradicts'],
  ['Contradicts', 'finding', s => s.kind === 'finding' && s.relation === 'contradicts'],
]
const groups = computed(() => GROUPS.map(([title, kind, pick]) => ({ title, kind, items: (f.value?.sources ?? []).filter(pick) }))
                                    .filter(g => g.items.length))
// A finding is on this page already.
const sourceHref = (s: Source) => s.kind === 'finding' ? `#${s.target}` : refSourceHref(s.kind, s.target, s.label)
const sourceName = (s: Source) =>
  s.kind === 'code' ? splitCodeTarget(s.target)[1] :
  s.kind === 'result' && s.target.startsWith('media/') ? s.target.split('/').pop()! :
  s.label || s.target
const isImage = (s: Source) => s.kind === 'result' && s.target.startsWith('media/') && /\.(png|jpe?g|gif|svg|webp)$/i.test(s.target)
// A source is named as it is mentioned anywhere: an @-reference, a paper's page after `#p`.
const adding = ref<{ source: string; relation: string; note: string } | null>(null)
const SOURCE_HINT = '@arXiv:2401.00001#p5, @doc-…, @KB-12, @KB-F3, @code:path#name'
const isFinding = (source: string) => /^@?[A-Za-z][A-Za-z0-9]*-F\d+$/i.test(source.trim())
async function addSource() {
  const a = adding.value
  if (!a || !a.source.trim()) return
  const relation = a.relation === 'contradicts' ? 'contradicts' : isFinding(a.source) ? 'builds_on' : 'supports'
  await change({ source: a.source, relation, note: a.note }, '/evidence')
  if (!error.value) adding.value = null
}
// A cited source kept as evidence, as an @-reference, so a page or note can go with it.
const keep = (s: Source) => {
  adding.value = { source: refFor(s.kind, s.target, s.label || s.target), relation: s.relation === 'contradicts' ? 'contradicts' : 'supports', note: '' }
}

// A task referred to in the text opens on the board.
const followRef = onTaskRef(r => { location.href = taskHref(r) })

// Following changes (see /api/tasks/changes): the list, and the open finding unless it is being edited.
let following = true
async function follow() {
  let since = -1
  while (following) {
    try {
      const r = await getJSON(`/api/tasks/changes?since=${since}`)
      if (since >= 0 && r.version !== since) {
        await loadList()
        if (f.value && !draft.value) await open(f.value.ref)
      }
      since = r.version
    } catch { await new Promise(res => setTimeout(res, 5000)) }
  }
}

onMounted(async () => { markdown.value = await loadMarkdown() })
onLive(async () => {
  if (!can('tasks.view')) return
  try { projects.value = (await getJSON('/api/projects')).projects } catch (e: any) { error.value = e.message; return }
  window.addEventListener('hashchange', onHash)
  await onHash()
  follow()
  return () => window.removeEventListener('hashchange', onHash)
})
onBeforeUnmount(() => { following = false })
</script>

<template>
  <div class="kbf">
    <KBNeedsService permission="tasks.view">
      <p v-if="!projects.length && !error" class="kbf-dim">No projects.</p>
      <template v-else>
        <div class="kbf-bar">
          <select :value="key" class="kbf-select" aria-label="Project" @change="chooseProject(($event.target as HTMLSelectElement).value)">
            <option v-for="p in projects" :key="p.key" :value="p.key">{{ p.key }} · {{ p.name }}</option>
          </select>
          <a class="kbf-small" :href="projectHref(key)">Board</a>
          <span class="kbf-spacer"></span>
          <button v-if="editable && !creating" class="kbf-small" @click="go(`new/${key}`)"><KBIcon name="plus" :size="15" />Finding</button>
        </div>
        <p v-if="error" class="kb-error kbf-error">{{ error }}</p>

        <div class="kbf-layout">
          <nav class="kbf-list" aria-label="Findings">
            <input v-model="q" type="search" class="kb-field kbf-search" placeholder="Search" aria-label="Search findings" />
            <div v-if="rows.length" class="kbf-filters">
              <button class="kb-pill" :class="{ on: !status }" @click="status = ''">all {{ rows.length }}</button>
              <template v-for="s in STATUSES" :key="s">
                <button v-if="count(s)" class="kb-pill" :class="{ on: status === s }" @click="status = status === s ? '' : s">{{ s }} {{ count(s) }}</button>
              </template>
            </div>
            <p v-else class="kbf-dim">{{ q.trim() ? 'Nothing found.' : 'None.' }}</p>
            <button class="kbf-archived-toggle" :class="{ on: archived }" @click="toggleArchived">{{ archived ? 'Back to findings' : 'Archived' }}</button>
            <a v-for="r in shown" :key="r.ref" class="kbf-row" :class="{ on: f?.ref === r.ref }" :href="`#${r.ref}`">
              <span class="kbf-row-head"><span class="kbf-ref">{{ r.ref }}</span><span class="kbf-tag" :class="r.status">{{ r.status }}</span>
                <span v-if="r.recheck?.length" class="kbf-tag recheck" title="Its evidence changed">re-check</span>
                <span class="kbf-dim kbf-row-day">{{ day(r.updated_at) }}</span></span>
              <span class="kbf-row-claim">{{ r.claim }}</span>
            </a>
          </nav>

          <article v-if="draft" class="kbf-main kbf-editing">
            <div class="kbf-head">
              <span class="kbf-ref">{{ f ? f.ref : 'New finding' }}</span>
              <a v-if="draft.task" class="kbf-chip" :href="taskHref(draft.task)">from {{ draft.task }}</a>
            </div>
            <textarea v-model="draft.claim" class="kbf-claim-field" rows="2" placeholder="Claim" aria-label="Claim"></textarea>
            <KBRefText v-model="draft.body" :project="key" multiline :rows="18" :draft="`finding:${f ? f.ref : `new:${key}`}:body`" send="save" @submit="save"
                       placeholder="Write-up" />
            <div class="kbf-actions">
              <button class="kbf-button" :disabled="!draft.claim.trim()" @click="save">{{ f ? 'Save' : 'Create' }}</button>
              <button class="kbf-small" @click="cancel">Cancel</button>
            </div>
          </article>

          <article v-else-if="f" class="kbf-main" @click="followRef" @keydown="followRef">
            <div class="kbf-head">
              <span class="kbf-ref">{{ f.ref }}</span>
              <span class="kbf-tag" :class="f.status">{{ f.status }}</span>
              <KBCite compact :cite="{ reference: `@${f.ref}` }" :title="f.claim" :link="findingHref(f.ref)" />
              <span class="kbf-dim">{{ f.created_by }}{{ f.by_agent ? ' (agent)' : '' }} · {{ when(f.updated_at) }}</span>
              <span class="kbf-spacer"></span>
              <template v-if="editable && !asking && !f.archived_at">
                <button v-if="f.status !== 'accepted'" class="kbf-small kbf-accept" @click="setStatus('accepted')">Accept</button>
                <button v-if="f.status === 'accepted'" class="kbf-small" @click="asking = { status: 'contested', reason: '' }">Contest</button>
                <button v-if="f.status === 'accepted' || f.status === 'contested'" class="kbf-small"
                        @click="asking = { status: 'superseded', reason: '' }">Supersede</button>
                <button v-if="f.status !== 'draft'" class="kbf-small" @click="setStatus('draft')">Back to draft</button>
              </template>
              <button v-if="editable" class="kbf-icon" title="Edit" aria-label="Edit" @click="draft = { claim: f.claim, body: f.body, task: '' }">
                <KBIcon name="edit" :size="15" /></button>
              <button v-if="editable && !f.archived_at" class="kbf-icon" title="Archive" aria-label="Archive" @click="archive()">
                <KBIcon name="archive" :size="15" /></button>
              <button v-if="editable && f.status === 'draft'" class="kbf-icon kbf-danger" title="Delete" aria-label="Delete" @click="remove">
                <KBIcon name="trash" :size="15" /></button>
            </div>
            <form v-if="asking" class="kbf-asking" @submit.prevent="setStatus(asking.status, asking.reason)">
              <KBRefText v-model="asking.reason" :project="key" :placeholder="asking.status === 'contested' ? 'Why' : 'Superseded by (@KB-F5), and why'" />
              <button class="kbf-button" :disabled="!asking.reason.trim()">{{ asking.status === 'contested' ? 'Contest' : 'Supersede' }}</button>
              <button type="button" class="kbf-small" @click="asking = null">Cancel</button>
            </form>
            <div v-if="f.archived_at" class="kbf-archived">Archived by {{ f.archived_by }} · {{ when(f.archived_at) }}
              <button v-if="editable" class="kbf-small" @click="archive(true)"><KBIcon name="unarchive" :size="14" />Restore</button></div>
            <h1 class="kbf-claim">{{ f.claim }}</h1>
            <div v-if="f.status_reason" class="kbf-reason" :class="f.status">
              <span class="kbf-reason-who">{{ f.status }} by {{ f.status_by }}</span>
              <div class="kb-md" v-html="render(f.status_reason)"></div>
            </div>
            <div v-if="f.recheck?.length" class="kbf-reason recheck">
              <span class="kbf-reason-who">Its evidence changed since it was written</span>
              <ul class="kbf-changes"><li v-for="r in f.recheck" :key="r">{{ r }}</li></ul>
              <div v-if="editable" class="kbf-actions">
                <button class="kbf-small" @click="change({ keep: true }, '/recheck')">Still holds</button>
                <button class="kbf-small" @click="askRecheck">Ask an agent to re-check</button>
                <a v-if="recheckTask" :href="taskHref(recheckTask)">{{ recheckTask }}</a>
              </div>
            </div>
            <div v-if="f.body" class="kb-md kbf-body" v-html="render(f.body)"></div>

            <section class="kbf-activity" aria-label="Activity">
              <h2>Activity</h2>
              <ol>
                <li v-for="a in f.activity" :key="a.kind + a.at + a.id" :class="a.kind">
                  <template v-if="a.kind === 'comment'">
                    <div class="kbf-said">
                      <span class="kbf-who">{{ a.who }}<span v-if="a.by_agent" class="kbf-agent">agent</span></span>
                      <span class="kbf-dim">{{ when(a.at) }}{{ a.edited ? ' · edited' : '' }}</span>
                      <button v-if="editable && mine(a) && editingComment?.id !== a.id" class="kbf-x" title="Edit" aria-label="Edit your comment"
                              @click="editingComment = { id: a.id, text: a.text }"><KBIcon name="edit" :size="13" /></button>
                    </div>
                    <form v-if="editingComment?.id === a.id" class="kbf-comment-form" @submit.prevent="saveComment">
                      <KBRefText v-model="editingComment.text" :project="key" multiline :rows="4" send="save" @submit="saveComment" />
                      <div class="kbf-actions"><button class="kbf-button" :disabled="!editingComment.text.trim()">Save</button>
                        <button type="button" class="kbf-small" @click="editingComment = null">Cancel</button></div>
                    </form>
                    <div v-else class="kb-md kbf-comment" v-html="render(a.text)"></div>
                  </template>
                  <div v-else class="kbf-change">
                    <span class="kbf-who">{{ a.who }}</span>{{ a.by_agent ? ' (agent)' : '' }}
                    {{ a.kind === 'created' ? 'drafted it' : a.text }} <span class="kbf-dim">· {{ when(a.at) }}</span>
                  </div>
                </li>
              </ol>
              <form v-if="editable" class="kbf-comment-form" @submit.prevent="sendComment">
                <KBRefText v-model="comment" :project="key" multiline :rows="3" :draft="`finding:${f.ref}:comment`" send="send"
                           placeholder="Comment: a question, an objection, a suggestion (Markdown, @-references)" @submit="sendComment" />
                <div class="kbf-actions"><button class="kbf-button" :disabled="!comment.trim()">Comment</button></div>
              </form>
            </section>

            <div v-if="f.versions" class="kbf-history">
              <button class="kbf-small" @click="showVersions">{{ versions ? 'Hide' : 'History' }} · {{ f.versions }}</button>
              <ol v-if="versions" class="kbf-versions">
                <li v-for="(v, i) in [...versions].reverse()" :key="i">
                  <div class="kbf-dim">{{ when(v.changed_at) }} · replaced by {{ v.changed_by }}{{ v.by_agent ? ' (agent)' : '' }} · was {{ v.status }}<template
                    v-if="v.status_reason">: {{ v.status_reason }}</template></div>
                  <details><summary>{{ v.claim }}</summary><div class="kb-md" v-html="render(v.body)"></div></details>
                </li>
              </ol>
            </div>
          </article>
          <div v-else class="kbf-main"></div>

          <aside v-if="f && !draft" class="kbf-sources" aria-label="Sources">
            <section v-for="g in groups" :key="g.title">
              <h3>{{ g.title }}</h3>
              <ul>
                <li v-for="s in g.items" :key="s.kind + s.target + s.evidence">
                  <div class="kbf-source">
                    <a v-if="sourceHref(s)" :href="sourceHref(s)" :class="{ mono: ['task', 'finding', 'code'].includes(s.kind) && !s.label }"><KBTitle :text="sourceName(s)" /></a>
                    <span v-else class="mono"><KBTitle :text="sourceName(s)" /></span>
                    <span v-if="s.kind === 'task' || s.kind === 'finding'" class="kbf-dim mono">{{ s.target }}</span>
                    <span v-if="s.page" class="kbf-dim">p. {{ s.page }}</span>
                    <span class="kbf-spacer"></span>
                    <button v-if="editable && !s.evidence" class="kbf-x" title="Add a passage" aria-label="Add a passage" @click="keep(s)">
                      <KBIcon name="plus" :size="13" /></button>
                    <button v-if="editable && s.evidence" class="kbf-x" title="Remove" aria-label="Remove"
                            @click="change({}, `/evidence/${s.evidence}/delete`)">✕</button>
                  </div>
                  <img v-if="isImage(s)" :src="mediaUrl(s.target)" :alt="sourceName(s)" class="kbf-figure" loading="lazy" />
                  <blockquote v-if="s.excerpt" class="kbf-excerpt">{{ s.excerpt }}</blockquote>
                  <div v-if="s.note" class="kbf-note kb-md" v-html="render(s.note)"></div>
                  <div v-if="Object.keys(s.detail ?? {}).length" class="kbf-dim kbf-detail">
                    <span v-for="(v, k) in s.detail" :key="k">{{ k }} {{ v }}</span></div>
                </li>
              </ul>
            </section>
            <section v-if="f.used_by.length">
              <h3>Used by</h3>
              <ul><li v-for="u in f.used_by" :key="u.ref + u.relation"><div class="kbf-source">
                <a :href="`#${u.ref}`">{{ u.claim }}</a><span class="kbf-dim mono">{{ u.ref }}</span>
                <span class="kbf-dim">{{ u.relation === 'contradicts' ? 'contradicts' : 'builds on' }}</span></div></li></ul>
            </section>
            <form v-if="adding" class="kbf-add" @submit.prevent="addSource">
              <KBRefText v-model="adding.source" :project="key" :placeholder="SOURCE_HINT" aria-label="Source" />
              <select v-model="adding.relation" aria-label="Relation">
                <option value="supports">{{ isFinding(adding.source) ? 'builds on it' : 'supports it' }}</option>
                <option value="contradicts">contradicts it</option></select>
              <KBRefText v-model="adding.note" :project="key" multiline :rows="3" placeholder="What it shows (Markdown)" aria-label="Note" />
              <div class="kbf-actions"><button class="kbf-button" :disabled="!adding.source.trim()">Add</button>
                <button type="button" class="kbf-small" @click="adding = null">Cancel</button></div>
            </form>
            <button v-else-if="editable" class="kbf-small" @click="adding = { source: '', relation: 'supports', note: '' }">
              <KBIcon name="plus" :size="15" />Source</button>
          </aside>
        </div>
      </template>
    </KBNeedsService>
  </div>
</template>

<style scoped>
.kbf-bar { display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.8rem; }
.kbf-spacer { flex: 1; }
.kbf-select, .kbf-add input, .kbf-add select, .kbf-add textarea, .kbf-claim-field {
  padding: 0.25rem 0.5rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft);
  color: var(--vp-c-text-1); font: inherit; font-size: 0.88rem; }
.kbf-dim { color: var(--vp-c-text-3); font-size: 0.8rem; }
.mono { font-family: var(--vp-font-family-mono); font-size: 0.82em; }
.kbf-error { font-size: 0.85rem; }
.kbf-small { display: inline-flex; align-items: center; gap: 0.2rem; padding: 0.15rem 0.55rem; border-radius: 6px; border: 1px solid var(--vp-c-divider);
  background: none; color: var(--vp-c-text-2); font: inherit; font-size: 0.8rem; cursor: pointer; text-decoration: none; }
.kbf-small:hover { border-color: var(--vp-c-brand-1); color: var(--vp-c-brand-1); }
.kbf-button { padding: 0.3rem 0.9rem; border-radius: 6px; border: none; background: var(--vp-c-brand-1); color: var(--vp-c-white); font: inherit; cursor: pointer; }
.kbf-button:disabled { opacity: 0.5; cursor: default; }
.kbf-icon { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; border-radius: 6px; border: none;
  background: none; color: var(--vp-c-text-2); cursor: pointer; }
.kbf-icon:hover { background: var(--vp-c-default-soft); }
.kbf-actions { display: flex; gap: 0.5rem; align-items: center; margin-top: 0.6rem; }

.kbf-layout { display: grid; grid-template-columns: 17rem minmax(0, 1fr) 20rem; gap: 1.6rem; align-items: start; }
@media (max-width: 1200px) { .kbf-layout { grid-template-columns: 15rem minmax(0, 1fr); } .kbf-sources { grid-column: 2; } }
@media (max-width: 760px) { .kbf-layout { grid-template-columns: minmax(0, 1fr); } .kbf-sources { grid-column: 1; } }

.kbf-list { display: flex; flex-direction: column; gap: 0.15rem; position: sticky; top: calc(var(--vp-nav-height) + 1rem);
  max-height: calc(100vh - var(--vp-nav-height) - 2rem); overflow-y: auto; }
.kbf-search { box-sizing: border-box; width: 100%; margin-bottom: 0.4rem; padding: 0.25rem 0.5rem; font-size: 0.85rem; }
.kbf-filters { display: flex; flex-wrap: wrap; gap: 0.25rem; margin-bottom: 0.4rem; }
.kbf-row { display: block; overflow-wrap: anywhere; padding: 0.4rem 0.55rem; border-radius: 8px; color: inherit; text-decoration: none; }
.kbf-row:hover { background: var(--vp-c-default-soft); }
.kbf-row.on { background: var(--vp-c-brand-soft); }
.kbf-row-head { display: flex; align-items: center; gap: 0.4rem; }
.kbf-row-day { margin-left: auto; font-size: 0.72rem; }
.kbf-row-claim { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; margin-top: 0.1rem;
  font-size: 0.85rem; line-height: 1.35; color: var(--vp-c-text-1); }
.kbf-ref { font-family: var(--vp-font-family-mono); font-size: 0.78rem; color: var(--vp-c-text-2); }

.kbf-tag { padding: 0.02rem 0.5rem; border-radius: 999px; font-size: 0.72rem; background: var(--vp-c-default-soft); color: var(--vp-c-text-2); }
.kbf-tag.accepted { background: var(--vp-c-green-soft, rgba(63,182,124,0.16)); color: var(--vp-c-green-1, #3fb67c); }
.kbf-tag.contested { background: var(--vp-c-danger-soft); color: var(--vp-c-danger-1); }
.kbf-tag.superseded { text-decoration: line-through; }
.kbf-tag.recheck { background: var(--vp-c-warning-soft); color: var(--vp-c-warning-1); }

.kbf-main { min-width: 0; }
.kbf-danger:hover { color: var(--vp-c-danger-1); background: var(--vp-c-danger-soft); }
.kbf-archived { display: flex; align-items: center; gap: 0.6rem; margin-top: 0.5rem; font-size: 0.85rem; color: var(--vp-c-text-2); }
.kbf-archived-toggle { align-self: flex-start; margin-top: 0.6rem; padding: 0; border: none; background: none; color: var(--vp-c-text-3);
  font: inherit; font-size: 0.78rem; cursor: pointer; }
.kbf-archived-toggle:hover, .kbf-archived-toggle.on { color: var(--vp-c-brand-1); }
.kbf-accept { border-color: var(--vp-c-brand-1); color: var(--vp-c-brand-1); }
.kbf-asking { display: flex; align-items: flex-start; gap: 0.5rem; margin-top: 0.6rem; }
.kbf-asking > :first-child { flex: 1; }
.kbf-reason { margin: -0.4rem 0 1rem; padding: 0.4rem 0.8rem; border-radius: 0 8px 8px 0; border-left: 3px solid var(--vp-c-divider);
  background: var(--vp-c-bg-soft); font-size: 0.9rem; }
.kbf-reason.contested { border-left-color: var(--vp-c-danger-1); }
.kbf-reason.recheck { border-left-color: var(--vp-c-warning-1); }
.kbf-changes { margin: 0.2rem 0 0.4rem; padding-left: 1.1rem; font-size: 0.88rem; }
.kbf-reason-who { font-size: 0.72rem; letter-spacing: 0.05em; text-transform: uppercase; color: var(--vp-c-text-2); }
.kbf-reason :deep(p) { margin: 0.15rem 0 0; }
.kbf-head { display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; }
.kbf-chip { padding: 0.02rem 0.5rem; border-radius: 999px; background: var(--vp-c-default-soft); font-family: var(--vp-font-family-mono);
  font-size: 0.75rem; text-decoration: none; }
.kbf-claim { overflow-wrap: anywhere; margin: 0.5rem 0 1rem; padding: 0; border: none; font-size: 1.6rem; line-height: 1.3; letter-spacing: -0.01em; }
.kbf-body { font-size: 0.97rem; line-height: 1.7; }
.kbf-body :deep(> :first-child) { margin-top: 0; }
.kbf-claim-field { display: block; width: 100%; box-sizing: border-box; margin: 0.5rem 0 0.6rem; font-size: 1.2rem; font-weight: 600; resize: vertical; }
.kbf-activity { margin-top: 2rem; padding-top: 0.8rem; border-top: 1px solid var(--vp-c-divider); }
.kbf-activity h2 { margin: 0 0 0.6rem; padding: 0; border: none; font-size: 0.78rem; letter-spacing: 0.05em; text-transform: uppercase;
  color: var(--vp-c-text-2); }
.kbf-activity ol { list-style: none; margin: 0 0 0.8rem; padding: 0 0 0 0.9rem; border-left: 2px solid var(--vp-c-divider); }
.kbf-activity li { position: relative; padding: 0.3rem 0; }
.kbf-activity li::before { content: ''; position: absolute; left: calc(-0.9rem - 5px); top: 0.75rem; width: 8px; height: 8px; border-radius: 50%;
  background: var(--vp-c-divider); }
.kbf-activity li.comment::before { background: var(--vp-c-brand-1); }
.kbf-activity li.comment { margin: 0.3rem 0; padding: 0.5rem 0.75rem; border-radius: 10px; background: var(--vp-c-bg-soft); }
.kbf-activity li.comment::before { left: calc(-0.9rem - 5px); }
.kbf-said { display: flex; align-items: baseline; gap: 0.5rem; }
.kbf-who { font-weight: 600; font-size: 0.85rem; }
.kbf-agent { margin-left: 0.35rem; padding: 0 0.4rem; border-radius: 999px; background: var(--vp-c-default-soft); font-size: 0.68rem; font-weight: 500;
  color: var(--vp-c-text-2); }
.kbf-comment { margin-top: 0.2rem; font-size: 0.92rem; }
.kbf-comment :deep(> :first-child) { margin-top: 0; }
.kbf-comment :deep(> :last-child) { margin-bottom: 0; }
.kbf-change { font-size: 0.83rem; color: var(--vp-c-text-2); }
.kbf-change .kbf-who { font-weight: 500; font-size: 0.83rem; color: var(--vp-c-text-1); }
.kbf-comment-form { display: flex; flex-direction: column; gap: 0.3rem; margin-top: 0.4rem; }
.kbf-history { margin-top: 2rem; padding-top: 0.8rem; border-top: 1px solid var(--vp-c-divider); }
.kbf-versions { list-style: none; margin: 0.6rem 0 0; padding: 0 0 0 0.8rem; border-left: 2px solid var(--vp-c-divider); }
.kbf-versions li { padding: 0.3rem 0; }
.kbf-versions summary { cursor: pointer; font-size: 0.9rem; color: var(--vp-c-text-2); }

.kbf-sources { position: sticky; top: calc(var(--vp-nav-height) + 1rem); max-height: calc(100vh - var(--vp-nav-height) - 2rem); overflow-y: auto;
  padding-left: 1rem; border-left: 1px solid var(--vp-c-divider); }
.kbf-sources h3 { margin: 0 0 0.3rem; padding: 0; border: none; font-size: 0.72rem; letter-spacing: 0.05em; text-transform: uppercase; color: var(--vp-c-text-2); }
.kbf-sources section { margin-bottom: 1.1rem; }
.kbf-sources ul { list-style: none; margin: 0; padding: 0; }
.kbf-sources li { overflow-wrap: anywhere; padding: 0.25rem 0; font-size: 0.87rem; line-height: 1.4; }
.kbf-source { display: flex; align-items: baseline; gap: 0.4rem; flex-wrap: wrap; }
.kbf-source a { text-decoration: none; }
.kbf-source a:hover { text-decoration: underline; }
.kbf-x { display: inline-flex; border: none; background: none; color: var(--vp-c-text-3); cursor: pointer; padding: 0 0.15rem; font-size: 0.8rem; }
.kbf-x:hover { color: var(--vp-c-text-1); }
.kbf-figure { display: block; max-width: 100%; margin: 0.3rem 0; border-radius: 6px; border: 1px solid var(--vp-c-divider); }
.kbf-excerpt { margin: 0.25rem 0 0; padding-left: 0.6rem; border-left: 2px solid var(--vp-c-divider); color: var(--vp-c-text-2); font-size: 0.83rem; }
.kbf-detail { display: flex; gap: 0.6rem; flex-wrap: wrap; }
.kbf-add { display: flex; flex-direction: column; gap: 0.35rem; }
.kbf-note { margin: 0.25rem 0 0; font-size: 0.83rem; color: var(--vp-c-text-2); }
.kbf-filters .kb-pill { padding: 0.05rem 0.5rem; font-size: 0.75rem; }
</style>

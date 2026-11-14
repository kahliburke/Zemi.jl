<!--
  The knowledge base's settings that can change while it runs: which model does what (summaries,
  classification, the tutor and how hard it thinks, notebooks, the paper of the day), search's
  defaults, the arXiv watch, the group as agents are told of it (its focus areas and the tutoring
  profile's questions too), the dataset and its content files in conflict, and who may sign in to the
  shared service. Changes are checked as a whole configuration before they apply, and are written to
  the settings file beside the config, never to the config file itself.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import KBModelChoice, { type ModelInfo, type Choice } from './KBModelChoice.vue'
import { ref, computed, onMounted } from 'vue'
import { mode, connect, getJSON, post, can, shared, api } from './kbApi'
import { plainCopy } from './kbUtils'
import { when } from './kbFormat'

type Setting = { key: string; kind: string; label: string; help: string; value: any; follows?: boolean }
type Conf = { settings: Setting[]; summarizers: { name: string; kind: string; model: string }[]; layers: string[]; roles: string[]; file: string; config: string }
const base = (p: string) => p.split('/').pop()
const conf = ref<Conf | null>(null)
const draft = ref<Record<string, any>>({})
const error = ref('')
const saved = ref('')

const editable = computed(() => can('config.edit'))
const shown = computed(() => (conf.value?.settings ?? []).filter(s => shared.value || !s.key.startsWith('shared.')))
const groups = computed(() => [
  { title: 'Who does what', keys: ['summarizer', 'code_summarizer', 'record_summarizer', 'judge', 'tutor', 'tutor_effort', 'notebooker', 'analyst', 'watch.judge'] },
  { title: 'Search', keys: ['search.layers', 'search.keyword'] },
  { title: 'New on arXiv', keys: ['watch.categories', 'watch.days', 'watch.hours', 'watch.read_from', 'watch.record_from'] },
  { title: 'The group', keys: ['group.name', 'group.field', 'group.description', 'group.focus_areas', 'group.questions', 'group.panels', 'contact'] },
  { title: 'Sharing', keys: ['dataset.role', 'dataset.stream', 'dataset.content', 'dataset.store', 'dataset.endpoint', 'dataset.bucket',
                             'dataset.prefix', 'dataset.credentials', 'dataset.check_hours', 'dataset.autosync_hours', 'dataset.read_unread'] },
  { title: 'Codebases', keys: ['shared.nightly_ingest', 'shared.timezone'] },
  { title: 'Zotero', keys: ['sources.zotero.prescreen'] },
  { title: 'Signing in', keys: ['shared.sign_up', 'shared.default_role', 'shared.session_days'] },
].map(g => ({ ...g, settings: shown.value.filter(s => g.keys.includes(s.key)) })).filter(g => g.settings.length))

function reset() { draft.value = Object.fromEntries((conf.value?.settings ?? []).map(s => [s.key, plainCopy(s.value)])) }
type Conflict = { path: string; stream: string; hash: string; at: string }
const conflicts = ref<Conflict[]>([])
// The logo and the front page's images: shown as they are, replaced by uploading, or put back.
type Brand = Record<string, { own: boolean; version: string }>
const brand = ref<Brand | null>(null)
const brandRows = [
  { id: 'logo', label: 'Logo', help: 'The top bar\'s logo, and the icons and favicon made from it. Square, 256 pixels or more; SVG or any image.' },
  { id: 'hero-light', label: 'Front page image (light)', help: 'Beside the title on the front page in the light theme. SVG or any image.' },
  { id: 'hero-dark', label: 'Front page image (dark)', help: 'The same in the dark theme.' },
]
// An image as a PNG at most `max` pixels across (a vector image drawn at `max`); with `square`, centred on a transparent square.
async function asPng(file: Blob, max: number, square: boolean): Promise<Blob> {
  const url = URL.createObjectURL(file)
  try {
    const img = new Image(); img.src = url; await img.decode()
    const vector = file.type === 'image/svg+xml'
    let w = img.naturalWidth || max, h = img.naturalHeight || max
    const scale = vector ? max / Math.max(w, h) : Math.min(1, max / Math.max(w, h))
    w = Math.round(w * scale); h = Math.round(h * scale)
    const side = Math.max(w, h)
    const canvas = document.createElement('canvas')
    canvas.width = square ? side : w; canvas.height = square ? side : h
    canvas.getContext('2d')!.drawImage(img, (canvas.width - w) / 2, (canvas.height - h) / 2, w, h)
    return await new Promise((ok, fail) => canvas.toBlob(b => b ? ok(b) : fail(new Error('The image could not be read')), 'image/png'))
  } finally { URL.revokeObjectURL(url) }
}
async function upload(which: string, e: Event) {
  const input = e.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (file) await setImage(which, file)
}
// An image from the clipboard: the paste button reads it, or ⌘V / Ctrl+V with the image's preview focused.
async function pasteButton(which: string) {
  error.value = ''
  try {
    for (const item of await navigator.clipboard.read()) {
      const type = item.types.find(t => t.startsWith('image/'))
      if (type) return await setImage(which, await item.getType(type))
    }
    error.value = 'The clipboard holds no image.'
  } catch (e: any) { error.value = `The clipboard could not be read (${e.message}); focus the image and press ⌘V or Ctrl+V.` }
}
async function pasted(which: string, e: ClipboardEvent) {
  const file = [...(e.clipboardData?.files ?? [])].find(f => f.type.startsWith('image/'))
  if (!file) return
  e.preventDefault()
  await setImage(which, file)
}
async function setImage(which: string, file: Blob) {
  error.value = ''; saved.value = ''
  try {
    const body = which === 'logo' ? await asPng(file, 512, true) : file.type === 'image/svg+xml' ? file : await asPng(file, 1200, false)
    brand.value = await post(`/api/config/brand/${which}`, body, body.type || 'application/octet-stream')
    saved.value = 'Saved; the site is being rebuilt with it.'
  } catch (e: any) { error.value = e.message }
}
async function resetBrand(which: string) {
  error.value = ''
  try { brand.value = await post(`/api/config/brand/${which}?reset=1`, ''); saved.value = 'Put back; the site is being rebuilt.' }
  catch (e: any) { error.value = e.message }
}
// The model that reads papers, chosen as setup chooses it, with what this machine has.
const modelInfo = ref<ModelInfo | null>(null)
const model = ref<Choice>({ id: '', model: '', url: '', key: '' })
const modelChanged = computed(() => !!modelInfo.value && (model.value.key !== '' ||
  JSON.stringify({ ...model.value, key: '' }) !== JSON.stringify({ ...modelInfo.value.model, key: '' })))
async function loadModel(keepChoice = false) {
  modelInfo.value = await getJSON('/api/config/model')
  if (!keepChoice) model.value = { ...modelInfo.value!.model, key: '' }
}
async function load() {
  try {
    await loadModel()
    conf.value = await getJSON('/api/config'); reset()
    conflicts.value = (await getJSON('/api/config/conflicts')).conflicts
    brand.value = await getJSON('/api/config/brand')
  } catch (e: any) { error.value = e.message }
}
async function settle(c: Conflict, take: boolean) {
  error.value = ''
  try { saved.value = (await post('/api/config/conflicts', JSON.stringify({ path: c.path, stream: c.stream, hash: c.hash, take }))).done; await load() }
  catch (e: any) { error.value = e.message }
}
const options = (q: any) => q.options.join('\n')
// The Zotero groups read, from the config and linked on projects' libraries (see src/zotero_links.jl).
type ZoteroGroup = { group: string; name: string; project: string; linked_by: string; configured: boolean; read: string; items: number; error: string }
const zotero = ref<ZoteroGroup[]>([])
const loadZotero = async () => { try { zotero.value = (await getJSON('/api/zotero')).groups } catch { /* shown as none */ } }
onMounted(async () => { await connect(); if (mode.value === 'live') { await load(); loadZotero() } })

const changes = computed(() => Object.fromEntries((conf.value?.settings ?? [])
  .filter(s => JSON.stringify(s.value) !== JSON.stringify(draft.value[s.key])).map(s => [s.key, draft.value[s.key]])))
const count = computed(() => Object.keys(changes.value).length + (modelChanged.value ? 1 : 0))
const dirty = computed(() => count.value > 0)

// The model first, as its own choice (which adds what it needs), then the other settings.
async function save() {
  error.value = ''; saved.value = ''
  try {
    if (modelChanged.value) {
      modelInfo.value = await post('/api/config/model', JSON.stringify(model.value))
      model.value = { ...modelInfo.value!.model, key: '' }
    }
    conf.value = Object.keys(changes.value).length ? await post('/api/config', JSON.stringify({ changes: changes.value }))
                                                   : await getJSON('/api/config')
    reset()
    saved.value = 'Saved.'
  } catch (e: any) { error.value = e.message }
}
function undo() { reset(); if (modelInfo.value) model.value = { ...modelInfo.value.model, key: '' } }
function toggle(key: string, item: string) {
  const v: string[] = draft.value[key]
  draft.value[key] = v.includes(item) ? v.filter(x => x !== item) : [...v, item]
}
// Move item `i` of a list setting one place earlier.
const moveUp = (list: unknown[], i: number) => list.splice(i - 1, 0, ...list.splice(i, 1))
</script>

<template>
  <div class="kbcf">
    <KBNeedsService permission="config.view">
      <template v-if="conf">
        <p class="kb-dim">Stored in <code>{{ base(conf.file) }}</code> (overrides <code>{{ base(conf.config) }}</code>)<span v-if="!editable"> · read-only</span></p>
        <section v-if="brand">
          <h2>Look</h2>
          <div v-for="b in brandRows" :key="b.id" class="kbcf-row">
            <label class="kbcf-label">{{ b.label }}<span class="kbcf-key">{{ brand[b.id].own ? 'this knowledge base\'s' : 'Zemi\'s' }}</span></label>
            <div class="kbcf-field kbcf-brand">
              <img :class="b.id" :src="`${api}/api/config/brand/${b.id}?v=${brand[b.id].version}`" :alt="b.label"
                   :tabindex="editable ? 0 : -1" title="Focus and paste an image to use it" @paste="pasted(b.id, $event)" />
              <span class="kbcf-help-line">{{ b.help }}</span>
              <span v-if="editable">
                <label class="kb-link kbcf-link">upload<input type="file" accept="image/*" hidden @change="upload(b.id, $event)" /></label> ·
                <button class="kb-link kbcf-link" @click="pasteButton(b.id)">paste</button>
                <template v-if="brand[b.id].own"> · <button class="kb-link kbcf-link" @click="resetBrand(b.id)">use Zemi's</button></template>
              </span>
            </div>
          </div>
        </section>
        <section v-if="modelInfo" id="model">
          <h2>The model that reads papers</h2>
          <p class="kbcf-help-line">It summarizes papers, codebases and records, sorts what is added, and picks the paper of the day.
            Who does each of these can be set apart below.</p>
          <KBModelChoice v-model="model" :info="modelInfo" :editable="editable" @refresh="loadModel(true)" />
        </section>
        <section v-for="g in groups" :key="g.title">
          <h2>{{ g.title }}</h2>
          <div v-for="s in g.settings" :key="s.key" class="kbcf-row">
            <label class="kbcf-label" :for="s.key" :title="s.help">{{ s.label }} <span class="kbcf-help" :title="s.help">ⓘ</span><code class="kbcf-key">{{ s.key }}</code></label>
            <div class="kbcf-field">
              <select v-if="s.kind === 'summarizer' || s.kind === 'summarizer?'" :id="s.key" v-model="draft[s.key]" :disabled="!editable || s.follows">
                <option v-if="s.kind === 'summarizer?'" value="">(summarizer)</option>
                <option v-for="m in conf.summarizers" :key="m.name" :value="m.name">{{ m.name }} ({{ m.kind }}, {{ m.model }})</option>
              </select>
              <select v-else-if="s.kind === 'effort'" :id="s.key" v-model="draft[s.key]" :disabled="!editable">
                <option v-for="e in ['low', 'medium', 'high', 'max']" :key="e" :value="e">{{ e }}</option>
              </select>
              <select v-else-if="s.kind === 'sign_up'" :id="s.key" v-model="draft[s.key]" :disabled="!editable">
                <option value="invite">invitation only</option><option value="open">open</option>
              </select>
              <select v-else-if="s.kind === 'dataset_role'" :id="s.key" v-model="draft[s.key]" :disabled="!editable">
                <option value="none">none</option><option value="publish">publish and import</option><option value="consume">import only</option>
              </select>
              <div v-else-if="s.kind === 'areas'" class="kbcf-list">
                <div v-for="(a, i) in draft[s.key]" :key="i" class="kbcf-area">
                  <input v-model="a.name" placeholder="Name" :disabled="!editable" />
                  <input v-model="a.description" placeholder="What it covers" :disabled="!editable" />
                  <button v-if="editable" class="kb-link kbcf-link" @click="draft[s.key].splice(i, 1)">remove</button>
                </div>
                <button v-if="editable" class="kb-link kbcf-link" @click="draft[s.key].push({ name: '', description: '' })">add</button>
              </div>
              <div v-else-if="s.kind === 'panels'" class="kbcf-list">
                <div v-for="(p, i) in draft[s.key]" :key="i" class="kbcf-panel">
                  <input v-model="p.title" placeholder="Title" :disabled="!editable" />
                  <input v-model="p.link" placeholder="Link, e.g. /projects (optional)" :disabled="!editable" />
                  <textarea v-model="p.text" rows="2" placeholder="What it leads to" :disabled="!editable"></textarea>
                  <div class="kbcf-question-foot">
                    <span>
                      <button v-if="editable && Number(i) > 0" class="kb-link kbcf-link" @click="moveUp(draft[s.key], Number(i))">move up</button>
                    </span>
                    <button v-if="editable" class="kb-link kbcf-link" @click="draft[s.key].splice(i, 1)">remove</button>
                  </div>
                </div>
                <button v-if="editable" class="kb-link kbcf-link" @click="draft[s.key].push({ title: '', text: '', link: '' })">add</button>
              </div>
              <div v-else-if="s.kind === 'questions'" class="kbcf-list">
                <div v-for="(q, i) in draft[s.key]" :key="i" class="kbcf-question">
                  <input v-model="q.id" placeholder="id" :disabled="!editable" />
                  <input v-model="q.text" placeholder="The question" :disabled="!editable" />
                  <textarea :value="options(q)" rows="3" placeholder="Answers, one a line" :disabled="!editable"
                            @change="q.options = ($event.target as HTMLTextAreaElement).value.split('\n').map(x => x.trim()).filter(Boolean)"></textarea>
                  <div class="kbcf-question-foot">
                    <label><input v-model="q.many" type="checkbox" :disabled="!editable" /> several answers</label>
                    <button v-if="editable" class="kb-link kbcf-link" @click="draft[s.key].splice(i, 1)">remove</button>
                  </div>
                </div>
                <button v-if="editable" class="kb-link kbcf-link" @click="draft[s.key].push({ id: '', text: '', options: [], many: false })">add</button>
              </div>
              <select v-else-if="s.kind === 'role'" :id="s.key" v-model="draft[s.key]" :disabled="!editable">
                <option v-for="r in conf.roles" :key="r" :value="r">{{ r }}</option>
              </select>
              <div v-else-if="s.kind === 'layers'" class="kbcf-checks">
                <label v-for="l in conf.layers" :key="l"><input type="checkbox" :checked="draft[s.key].includes(l)" :disabled="!editable" @change="toggle(s.key, l)" /> {{ l }}</label>
              </div>
              <input v-else-if="s.kind === 'bool'" :id="s.key" v-model="draft[s.key]" type="checkbox" :disabled="!editable" />
              <input v-else-if="s.kind === 'int' || s.kind === 'float'" :id="s.key" v-model.number="draft[s.key]" type="number"
                     :step="s.kind === 'int' ? 1 : 'any'" :disabled="!editable" />
              <input v-else-if="s.kind === 'strings'" :id="s.key" :value="draft[s.key].join(', ')" :disabled="!editable"
                     @change="draft[s.key] = ($event.target as HTMLInputElement).value.split(',').map(x => x.trim()).filter(Boolean)" />
              <textarea v-else-if="s.kind === 'text'" :id="s.key" v-model="draft[s.key]" rows="5" :disabled="!editable"></textarea>
              <input v-else :id="s.key" v-model="draft[s.key]" :disabled="!editable" />
              <span v-if="s.follows" class="kbcf-help-line">Set by the dataset</span>
            </div>
          </div>
          <div v-if="g.title === 'Zotero'" class="kbcf-zotero">
            <p v-if="!zotero.length" class="kb-dim">No Zotero group is read. A project's maintainers link one from its library.</p>
            <div v-for="z in zotero" :key="z.group" class="kbcf-row">
              <span><a :href="`https://www.zotero.org/groups/${z.group}`" target="_blank" rel="noopener">{{ z.name || `Group ${z.group}` }}</a>
                <span class="kb-dim"> · {{ z.project || 'no project' }} · {{ z.read ? `${z.items} items, read ${when(z.read)}` : 'not read yet' }}
                  {{ z.configured ? '· in the config file' : z.linked_by ? `· linked by ${z.linked_by}` : '' }}</span></span>
              <span v-if="z.error" class="kb-error">{{ z.error }}</span>
            </div>
          </div>
        </section>
        <section v-if="conflicts.length">
          <h2>Content in conflict</h2>
          <p class="kb-dim">Changed here and by another member. Keep yours, which publishes it, or take theirs.</p>
          <div v-for="c in conflicts" :key="c.path + c.stream + c.hash" class="kbcf-row">
            <span><code>{{ c.path }}</code> <span class="kb-dim">· {{ c.stream }}{{ c.hash ? '' : ' deleted it' }} · {{ c.at }}</span></span>
            <span v-if="editable"><button class="kb-link kbcf-link" @click="settle(c, false)">keep this one</button> ·
              <button class="kb-link kbcf-link" @click="settle(c, true)">take {{ c.stream }}'s</button></span>
          </div>
        </section>
        <div v-if="editable" class="kbcf-actions">
          <button class="kb-primary kbcf-button" :disabled="!dirty" @click="save">Save{{ dirty ? ` (${count})` : '' }}</button>
          <button v-if="dirty" class="kb-link kbcf-link" @click="undo">undo</button>
          <span v-if="saved" class="kbcf-saved">{{ saved }}</span>
        </div>
      </template>
    </KBNeedsService>
    <p v-if="error" class="kb-error kbcf-error">{{ error }}</p>
  </div>
</template>

<style scoped>
.kbcf-saved { color: var(--vp-c-brand-1); font-size: 0.9rem; }
.kbcf-row { display: grid; grid-template-columns: minmax(12rem, 1fr) 2fr; gap: 1rem; align-items: start; padding: 0.55rem 0;
  border-bottom: 1px solid var(--vp-c-divider); }
@media (max-width: 720px) { .kbcf-row { grid-template-columns: 1fr; gap: 0.3rem; } }
.kbcf-label { font-size: 0.92rem; cursor: help; }
.kbcf-help { font-size: 0.75rem; color: var(--vp-c-text-3); }
.kbcf-key { display: block; font-size: 0.72rem; color: var(--vp-c-text-3); margin-top: 0.15rem; background: none; padding: 0; }
.kbcf-field select, .kbcf-field input:not([type=checkbox]), .kbcf-field textarea { width: 100%; box-sizing: border-box; padding: 0.35rem 0.6rem;
  border-radius: 6px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font: inherit; font-size: 0.9rem; }
.kbcf-brand { display: grid; grid-template-columns: 7rem 1fr; gap: 0.3rem 1rem; align-items: center; }
.kbcf-brand img { grid-row: span 2; width: 7rem; height: 5rem; object-fit: contain; border-radius: 8px; padding: 0.3rem;
  border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); box-sizing: border-box; }
.kbcf-brand img:focus { outline: 2px solid var(--vp-c-brand-1); }
.kbcf-brand img.hero-light { background: #fff; }
.kbcf-brand img.hero-dark { background: #1b1b1f; }
.kbcf-help-line { font-size: 0.8rem; color: var(--vp-c-text-2); }
.kbcf-list { display: flex; flex-direction: column; gap: 0.5rem; align-items: flex-start; }
.kbcf-area { display: grid; grid-template-columns: 1fr 2fr auto; gap: 0.5rem; width: 100%; }
.kbcf-panel { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; width: 100%; }
.kbcf-panel textarea, .kbcf-panel .kbcf-question-foot { grid-column: 1 / -1; }
.kbcf-question { display: grid; grid-template-columns: 6rem 1fr; gap: 0.4rem; width: 100%; padding-bottom: 0.5rem;
  border-bottom: 1px dashed var(--vp-c-divider); }
.kbcf-question textarea, .kbcf-question-foot { grid-column: 1 / -1; }
.kbcf-question-foot { display: flex; justify-content: space-between; font-size: 0.86rem; }
.kbcf-checks { display: flex; flex-wrap: wrap; gap: 0.3rem 1rem; font-size: 0.88rem; }
.kbcf-actions { position: sticky; bottom: 0; display: flex; gap: 1rem; align-items: center; padding: 0.8rem 0; background: var(--vp-c-bg); }
.kbcf-button:disabled { opacity: 0.5; cursor: default; }
</style>

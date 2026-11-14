<!--
  A project's library, opened from its board: the papers, notebooks and codebases it works from, each
  with why it matters and the tasks and findings that cite it. What an agent proposed waits at the top
  for a person to keep it. Items are added as they are mentioned anywhere (`@arXiv:…`, `@doc-…`, a
  notebook, `code-…`, a repository's address).
-->
<script setup lang="ts">
import KBTitle from './KBTitle.vue'
import KBZoteroGroups from './KBZoteroGroups.vue'
import { ref, computed, onMounted } from 'vue'
import { findingHref } from './kbLinks'
import { day } from './kbFormat'
import { getJSON, post } from './kbApi'
import { href } from './kbRefs'
import { citedAs } from './kbKinds'
import KBIcon from './KBIcon.vue'
import KBDialog from './KBDialog.vue'
import KBRefText from './KBRefText.vue'

const props = defineProps<{ project: string; editable: boolean }>()
const emit = defineEmits<{ close: []; open: [ref: string] }>()

type Kind = 'paper' | 'notebook' | 'codebase'
type Item = { id: number; kind: Kind; target: string; label: string; why: string; status: string;
              added_by: string; by_agent: boolean; added_at: string; tasks: string[]; findings: string[] }
const items = ref<Item[] | null>(null)
const error = ref('')
const sending = ref(false)
const adding = ref<{ source: string; why: string } | null>(null)
const filter = ref('')
// What the tiles narrow the library to: a kind, the proposals, or everything.
const only = ref<Kind | 'proposed' | ''>('')

async function load() {
  try { items.value = await getJSON(`/api/projects/${props.project}/library`); error.value = '' }
  catch (e: any) { error.value = e.message }
}
async function send(path: string, body: Record<string, unknown> = {}) {
  if (sending.value) return false
  sending.value = true
  try { items.value = await post(`/api/projects/${props.project}/library${path}`, JSON.stringify(body)); error.value = ''; return true }
  catch (e: any) { error.value = e.message; return false }
  finally { sending.value = false }
}
async function add() {
  const a = adding.value
  if (a && a.source.trim() && await send('', { source: a.source, why: a.why })) adding.value = null
}

// Escape, or a click beside it, puts away an item being added, else the library.
const back = () => adding.value ? (adding.value = null) : emit('close')
onMounted(load)

const KINDS: { kind: Kind; title: string; one: string }[] = [
  { kind: 'paper', title: 'Papers', one: 'paper' },
  { kind: 'notebook', title: 'Notebooks', one: 'notebook' },
  { kind: 'codebase', title: 'Codebases', one: 'codebase' }]
const all = computed(() => items.value ?? [])
const count = (k: Kind) => all.value.filter(x => x.kind === k && x.status !== 'proposed').length
const proposedCount = computed(() => all.value.filter(x => x.status === 'proposed').length)
const cited = computed(() => all.value.filter(x => x.tasks.length || x.findings.length).length)
const pick = (k: typeof only.value) => { only.value = only.value === k ? '' : k }

const name = (x: Item) => x.label && x.label !== x.target ? x.label : x.kind === 'paper' ? citedAs(x.target) : x.target
const matches = (x: Item) => {
  const q = filter.value.trim().toLowerCase()
  return !q || [x.label, x.target, x.why, x.added_by, ...x.tasks, ...x.findings].some(s => s.toLowerCase().includes(q))
}
const proposed = computed(() => only.value && only.value !== 'proposed' ? [] : all.value.filter(x => x.status === 'proposed' && matches(x)))
const groups = computed(() => only.value === 'proposed' ? [] :
  KINDS.filter(k => !only.value || k.kind === only.value)
       .map(k => ({ ...k, items: all.value.filter(x => x.kind === k.kind && x.status !== 'proposed' && matches(x)) }))
       .filter(g => g.items.length))
const empty = computed(() => !proposed.value.length && !groups.value.length)
</script>

<template>
  <KBDialog width="min(68rem, 96vw)" top bare :shade="0.45" @close="back">
    <section class="kbl-box">
      <header class="kbl-head">
        <span class="kbl-head-icon"><KBIcon name="library" :size="22" /></span>
        <h2>{{ project }} library</h2>
        <span class="kbl-spacer"></span>
        <button v-if="editable && !adding" class="kb-primary kbl-button" @click="adding = { source: '', why: '' }"><KBIcon name="plus" :size="15" /> Add</button>
        <button class="kbl-close" aria-label="Close" @click="emit('close')">✕</button>
      </header>

      <form v-if="adding" class="kbl-add" @submit.prevent="add">
        <label>Source
          <KBRefText v-model="adding.source" :project="project" placeholder="@arXiv:2401.00001, @doc-…, a notebook, code-…, a repository's address"
                     aria-label="Source" @submit="add" /></label>
        <label>Why it matters to {{ project }}
          <input v-model="adding.why" placeholder="The method the scan follows, a rival result, the code it extends…" aria-label="Why it matters" /></label>
        <div class="kbl-actions">
          <button class="kb-primary kbl-button" :disabled="!adding.source.trim() || sending">Add to the library</button>
          <button type="button" class="kbl-small" @click="adding = null">Cancel</button>
        </div>
      </form>

      <KBZoteroGroups :project="project" @read="load" />
      <p v-if="error" class="kb-error kbl-error">{{ error }}</p>
      <p v-if="!items" class="kb-dim kbl-dim kbl-loading">Reading the library…</p>
      <template v-else>
        <div class="kbl-tiles">
          <button v-for="k in KINDS" :key="k.kind" class="kbl-tile" :class="[k.kind, { on: only === k.kind }]" @click="pick(k.kind)">
            <span class="kbl-tile-icon"><KBIcon :name="k.kind" :size="18" /></span>
            <b>{{ count(k.kind) }}</b><span>{{ count(k.kind) === 1 ? k.one : k.title.toLowerCase() }}</span>
          </button>
          <button class="kbl-tile proposed" :class="{ on: only === 'proposed', none: !proposedCount }" @click="pick('proposed')">
            <span class="kbl-tile-icon"><KBIcon name="check" :size="18" /></span>
            <b>{{ proposedCount }}</b><span>to keep or remove</span>
          </button>
          <div class="kbl-tile plain">
            <span class="kbl-tile-icon"><KBIcon name="finding" :size="18" /></span>
            <b>{{ cited }}</b><span>cited by tasks or findings</span>
          </div>
        </div>

        <div class="kbl-toolbar">
          <span class="kbl-spacer"></span>
          <input v-model="filter" class="kbl-filter" type="search" placeholder="Filter by name, why, task or finding" aria-label="Filter the library" />
        </div>

        <div v-if="empty" class="kbl-empty">
          <KBIcon name="library" :size="34" />
          <p>{{ all.length ? 'Nothing matches.' : 'Nothing in the library yet.' }}</p>
        </div>

        <section v-if="proposed.length" class="kbl-proposed">
          <h3><KBIcon name="check" :size="15" /> Proposed by agents <span>{{ proposed.length }}</span></h3>
          <div class="kbl-grid">
            <article v-for="x in proposed" :key="x.kind + x.target" class="kbl-card" :class="x.kind">
              <div class="kbl-card-head">
                <span class="kbl-card-icon"><KBIcon :name="x.kind" :size="16" /></span>
                <div class="kbl-card-title">
                  <a v-if="href(x.kind, x.target)" :href="href(x.kind, x.target)"><KBTitle :text="name(x)" /></a><span v-else><KBTitle :text="name(x)" /></span>
                  <div class="kbl-id">{{ x.kind }} · {{ x.target }}</div>
                </div>
              </div>
              <p v-if="x.why" class="kbl-why">{{ x.why }}</p>
              <footer class="kbl-card-foot">
                <span>{{ x.added_by }}<template v-if="x.added_at"> · {{ day(x.added_at) }}</template></span>
                <span class="kbl-spacer"></span>
                <template v-if="editable">
                  <button class="kbl-keep" :disabled="sending" @click="send(`/${x.id}/keep`)">Keep</button>
                  <button class="kbl-small" :disabled="sending" @click="send(`/${x.id}/delete`)">Remove</button>
                </template>
              </footer>
            </article>
          </div>
        </section>

        <section v-for="g in groups" :key="g.kind" class="kbl-group" :class="g.kind">
          <h3><span class="kbl-group-icon"><KBIcon :name="g.kind" :size="15" /></span> {{ g.title }} <span class="kbl-count">{{ g.items.length }}</span></h3>
          <div class="kbl-grid">
            <article v-for="x in g.items" :key="x.kind + x.target" class="kbl-card" :class="x.kind">
              <div class="kbl-card-head">
                <span class="kbl-card-icon"><KBIcon :name="x.kind" :size="16" /></span>
                <div class="kbl-card-title">
                  <a v-if="href(x.kind, x.target)" :href="href(x.kind, x.target)"><KBTitle :text="name(x)" /></a><span v-else><KBTitle :text="name(x)" /></span>
                  <div v-if="name(x) !== x.target" class="kbl-id">{{ x.target }}</div>
                </div>
                <button v-if="editable && x.id > 0" class="kbl-x" title="Take out of the library" aria-label="Take out of the library"
                        :disabled="sending" @click="send(`/${x.id}/delete`)"><KBIcon name="trash" :size="15" /></button>
              </div>
              <p v-if="x.why" class="kbl-why">{{ x.why }}</p>
              <p v-else class="kbl-why kb-dim kbl-dim">No note on why yet.</p>
              <footer class="kbl-card-foot">
                <span v-if="x.added_by">{{ x.added_by }}<template v-if="x.added_at"> · {{ day(x.added_at) }}</template></span>
                <span v-else>Linked to the project</span>
                <span class="kbl-spacer"></span>
                <span v-if="x.tasks.length || x.findings.length" class="kbl-cited">
                  <a v-for="t in x.tasks" :key="t" class="kbl-ref" :href="`#${t}`" @click.prevent="emit('open', t)">{{ t }}</a>
                  <a v-for="f in x.findings" :key="f" class="kbl-ref finding" :href="findingHref(f)">{{ f }}</a>
                </span>
              </footer>
            </article>
          </div>
        </section>
      </template>
    </section>
  </KBDialog>
</template>

<style scoped>
.kbl-box { font-size: 0.88rem; padding: 1.1rem 1.5rem 1.7rem; border-radius: 14px; background: var(--vp-c-bg);
  border: 1px solid var(--vp-c-divider); box-shadow: var(--vp-shadow-5);
  /* each kind's colour: its tile, section heading and cards' edge */
  --paper: var(--vp-c-brand-1); --paper-soft: var(--vp-c-brand-soft);
  --notebook: var(--vp-c-green-1, #3fb67c); --notebook-soft: var(--vp-c-green-soft, rgba(63, 182, 124, 0.14));
  --codebase: var(--vp-c-purple-1, #a879e6); --codebase-soft: var(--vp-c-purple-soft, rgba(168, 121, 230, 0.14)); }
.paper { --accent: var(--paper); --accent-soft: var(--paper-soft); }
.notebook { --accent: var(--notebook); --accent-soft: var(--notebook-soft); }
.codebase { --accent: var(--codebase); --accent-soft: var(--codebase-soft); }
.proposed { --accent: var(--vp-c-warning-1); --accent-soft: var(--vp-c-warning-soft); }

.kbl-head { display: flex; align-items: center; gap: 0.75rem; padding-bottom: 0.9rem; border-bottom: 1px solid var(--vp-c-divider); }
.kbl-head h2 { margin: 0; border: none; padding: 0; font-size: 1.3rem; line-height: 1.3; }
.kbl-head-icon { display: grid; place-items: center; width: 2.4rem; height: 2.4rem; border-radius: 10px;
  background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kbl-spacer { flex: 1; }
.kbl-close { border: none; background: none; color: var(--vp-c-text-2); font-size: 1rem; cursor: pointer; padding: 0.2rem 0.4rem; }
.kbl-dim { font-size: 0.85rem; }
.kbl-loading { margin-top: 1rem; }

.kbl-add { display: grid; gap: 0.6rem; margin: 1rem 0 0.2rem; padding: 0.9rem 1rem; border-radius: 12px; background: var(--vp-c-bg-soft);
  border: 1px solid var(--vp-c-divider); }
.kbl-add label { display: grid; gap: 0.25rem; font-size: 0.78rem; font-weight: 600; letter-spacing: 0.02em; color: var(--vp-c-text-2); }
.kbl-add input, .kbl-filter { padding: 0.4rem 0.6rem; border-radius: 8px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg);
  color: var(--vp-c-text-1); font: inherit; font-size: 0.9rem; font-weight: 400; }
.kbl-actions { display: flex; gap: 0.5rem; }

.kbl-tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr)); gap: 0.6rem; margin: 1.1rem 0 0.4rem; }
.kbl-tile { display: grid; grid-template-columns: auto 1fr; grid-template-rows: auto auto; column-gap: 0.65rem; align-items: center; text-align: left;
  padding: 0.65rem 0.8rem; border-radius: 12px; border: 1px solid transparent; background: var(--vp-c-bg-soft); color: var(--vp-c-text-1);
  font: inherit; cursor: pointer; transition: border-color 0.15s, background 0.15s; }
.kbl-tile:hover { border-color: var(--accent, var(--vp-c-divider)); }
.kbl-tile.on { border-color: var(--accent); background: var(--accent-soft); }
.kbl-tile.plain { cursor: default; --accent: var(--vp-c-text-2); --accent-soft: var(--vp-c-default-soft); }
.kbl-tile.plain:hover { border-color: transparent; }
.kbl-tile.none { opacity: 0.6; }
.kbl-tile-icon { grid-row: 1 / 3; display: grid; place-items: center; width: 2.1rem; height: 2.1rem; border-radius: 9px;
  background: var(--accent-soft); color: var(--accent); }
.kbl-tile b { font-size: 1.45rem; font-weight: 650; line-height: 1.1; }
.kbl-tile span:last-child { font-size: 0.78rem; color: var(--vp-c-text-2); }

.kbl-toolbar { display: flex; align-items: center; gap: 0.5rem; margin: 0.6rem 0 0.2rem; }
.kbl-filter { width: min(22rem, 100%); }

.kbl-empty { display: grid; justify-items: center; gap: 0.2rem; margin: 2rem auto 1rem; max-width: 30rem; text-align: center; color: var(--vp-c-text-3); }
.kbl-empty p { margin: 0; color: var(--vp-c-text-1); }
.kbl-empty p.kbl-dim { color: var(--vp-c-text-2); }

.kbl-proposed { margin-top: 1.1rem; padding: 0.2rem 0.9rem 0.9rem; border-radius: 12px; background: var(--vp-c-warning-soft); }
.kbl-proposed h3, .kbl-group h3 { display: flex; align-items: center; gap: 0.4rem; margin: 0.8rem 0 0.6rem; border: none; padding: 0;
  font-size: 0.78rem; letter-spacing: 0.06em; text-transform: uppercase; }
.kbl-proposed h3 { color: var(--vp-c-warning-1); }
.kbl-proposed h3 span, .kbl-count { padding: 0 0.45rem; border-radius: 999px; background: var(--accent-soft, var(--vp-c-default-soft));
  color: var(--accent, var(--vp-c-text-2)); font-size: 0.72rem; letter-spacing: 0; }
.kbl-group { margin-top: 1.4rem; }
.kbl-group h3 { color: var(--vp-c-text-1); padding-bottom: 0.45rem; border-bottom: 2px solid var(--accent-soft); }
.kbl-group-icon { display: grid; place-items: center; width: 1.5rem; height: 1.5rem; border-radius: 6px; background: var(--accent-soft); color: var(--accent); }

.kbl-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(19rem, 1fr)); gap: 0.7rem; }
.kbl-card { display: flex; flex-direction: column; gap: 0.35rem; padding: 0.7rem 0.85rem 0.6rem; border-radius: 10px; background: var(--vp-c-bg-soft);
  border: 1px solid var(--vp-c-divider); border-left: 3px solid var(--accent); transition: box-shadow 0.15s; }
.kbl-proposed .kbl-card { background: var(--vp-c-bg); }
.kbl-card:hover { box-shadow: var(--vp-shadow-2); }
.kbl-card-head { display: flex; align-items: flex-start; gap: 0.55rem; }
.kbl-card-icon { flex: none; display: grid; place-items: center; width: 1.7rem; height: 1.7rem; border-radius: 7px; background: var(--accent-soft); color: var(--accent); }
.kbl-card-title { flex: 1; min-width: 0; font-weight: 600; font-size: 0.92rem; line-height: 1.35; }
.kbl-card-title a { color: var(--vp-c-text-1); text-decoration: none; }
.kbl-card-title a:hover { color: var(--accent); text-decoration: underline; }
.kbl-id { font-family: var(--vp-font-family-mono); font-size: 0.72rem; font-weight: 400; color: var(--vp-c-text-3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.kbl-why { margin: 0; font-size: 0.86rem; line-height: 1.45; color: var(--vp-c-text-1); }
.kbl-why.kbl-dim { font-style: italic; color: var(--vp-c-text-3); }
.kbl-card-foot { display: flex; align-items: center; flex-wrap: wrap; gap: 0.35rem; margin-top: auto; padding-top: 0.4rem;
  border-top: 1px dashed var(--vp-c-divider); font-size: 0.75rem; color: var(--vp-c-text-3); }
.kbl-cited { display: inline-flex; flex-wrap: wrap; gap: 0.25rem; }
.kbl-ref { padding: 0 0.4rem; border-radius: 5px; background: var(--vp-c-default-soft); color: var(--vp-c-text-2); font-family: var(--vp-font-family-mono);
  font-size: 0.72rem; text-decoration: none; }
.kbl-ref:hover { color: var(--vp-c-brand-1); }
.kbl-ref.finding { background: var(--vp-c-warning-soft); color: var(--vp-c-warning-1); }

.kbl-button { display: inline-flex; align-items: center; gap: 0.3rem; padding: 0.35rem 0.9rem; font-size: 0.85rem; }
.kbl-button:disabled { opacity: 0.6; cursor: default; }
.kbl-keep { padding: 0.15rem 0.75rem; border-radius: 6px; border: none; background: var(--vp-c-warning-1); color: var(--vp-c-white); font-weight: 600;
  cursor: pointer; font-size: 0.78rem; }
.kbl-small { padding: 0.15rem 0.65rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: none; color: var(--vp-c-text-2);
  cursor: pointer; font: inherit; font-size: 0.78rem; }
.kbl-x { flex: none; border: none; background: none; color: var(--vp-c-text-3); cursor: pointer; padding: 0.1rem; opacity: 0; transition: opacity 0.15s; }
.kbl-card:hover .kbl-x, .kbl-x:focus-visible { opacity: 1; }
.kbl-x:hover { color: var(--vp-c-danger-1); }
</style>

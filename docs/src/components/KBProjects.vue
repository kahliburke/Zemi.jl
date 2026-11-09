<!--
  Projects and their boards: a column per status, cards moved between columns by dragging, and a
  task's panel with its plan, subtasks, links and activity, where people comment and approve an agent's
  plan (it waits in Proposed until someone moves it on). Refreshed while open. The project, or the open
  task, is in the page's address (#KB, #KB-12), so either can be linked to.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import { ref, shallowRef, computed, onMounted, onBeforeUnmount, watch, nextTick } from 'vue'
import { api, getJSON, post, can, me, shared, latest, isStale, onLive } from './kbApi'
import KBDock from './KBDock.vue'
import KBDialog from './KBDialog.vue'
import KBIcon from './KBIcon.vue'
import KBCite from './KBCite.vue'
import KBRefText from './KBRefText.vue'
import KBTaskSearch from './KBTaskSearch.vue'
import KBProjectReview from './KBProjectReview.vue'
import KBMembers from './KBMembers.vue'
import KBRecordUpload from './KBRecordUpload.vue'
import KBLibrary from './KBLibrary.vue'
import { sourceHref, onTaskRef, setCodebase } from './kbRefs'
import { findingHref, recordHref, kbPage, taskHref } from './kbLinks'
import { loadMarkdown, escapeText, type Render } from './kbMarkdown'
import { plainLine } from './kbUtils'
import { when } from './kbFormat'
import { PRIORITIES } from './kbLabels'

type Project = { key: string; name: string; description: string; codebase: string; root: string; tasks: number; open: number;
                 active_milestone: string }
type Status = { id: string; label: string }
type Milestone = { name: string; description: string; start: string; due: string; closed: boolean; done: number; total: number; active: boolean }
type Task = { ref: string; title: string; status: string; blocked: string; priority: number; assignee: string; milestone: string;
              parent: string; subtasks: number; subtasks_done: number; created_by: string; by_agent: boolean; created_at: string; updated_at: string; sent_back?: boolean;
              archived_at: string; asap_at?: string }
// A question is asked of the agents, a person (`to_person`, as tasks are assigned) or anyone on the
// project; a reply names the question it answers or asks back about (`reply_to`).
type TaskEvent = { id: number; at: string; who: string; by_agent: boolean; by_person: string; kind: string; text: string; detail: Record<string, any>;
                   resolved_at: string; edited_at: string; to_whom: '' | 'agents' | 'anyone' | 'person'; to_person: string; to_label: string;
                   reply_to: number; state: '' | 'open' | 'asked back' | 'answered' | 'resolved' }
type Person = { id: string; label: string; agent: boolean }
type Commit = { sha: string; at: string; author: string; subject: string; ref: string; url: string; task: string;
                files: { path: string; added: number; removed: number }[]; added: number; removed: number }
type Full = Task & { body: string; project: string; links: { kind: string; target: string; label: string }[];
                     blocked_by: string[]; activity: TaskEvent[]; subtasks_list: Task[]; commits: Commit[];
                     mentions: { sha: string; at: string; author: string; subject: string; url: string }[];
                     findings: { ref: string; claim: string; status: string }[] }
type Codebase = { id: string; title: string; rev: string; remote: string; page: string }
// Who else has a board open, at the level each chose (src/people_activity.jl); what people did lately.
type Viewer = { id: number; name: string; project: string; planning: boolean; open: string; draft_ref: string; draft: string;
                following: number; view: string; at: string }
type Action = { who: string; kind: string; ref: string; title: string; text: string; detail: Record<string, any>; at: string }

const list = ref<Project[]>([])
const statuses = ref<Status[]>([])
const key = ref('')
const board = ref<{ project: Project; milestones: Milestone[]; tasks: Task[]; codebase: Codebase | null; access: string;
                    manages_members: boolean; findings: number; records: { id: string; title: string; day: string }[];
                    agents: { tasks: { ref: string; agent: string; at: string; via: string }[]; waiting: { agent: string; since: string }[] };
                    people_did: Action[]; changed_by_others?: Record<string, { at: string; who: string }> } | null>(null)
const open = ref<Full | null>(null)
// Room on the board for the docked task panel: what the panel covers past the page's own margin.
const page = ref<HTMLElement | null>(null)
const room = ref({ right: 0, bottom: 0 })
function makeRoom(space: { right: number; bottom: number }) {
  const beside = page.value ? window.innerWidth - page.value.getBoundingClientRect().right : 0
  room.value = { right: space.right && Math.max(0, space.right - beside) + 16, bottom: space.bottom && space.bottom + 16 }
}
const error = ref('')
const milestone = ref('')
const subtasks = ref(false)
// What one may do in the open project: change its work (contributors and maintainers), and manage
// the project itself, its context, codebase and milestones (maintainers); who belongs to it, and
// deleting it, is for its owner and admins (`manages_members`). See project_access.jl.
const editable = computed(() => can('tasks.edit') && ['contributor', 'maintainer'].includes(board.value?.access ?? ''))
const manages = computed(() => can('tasks.edit') && board.value?.access === 'maintainer')
// Records are added on the board by those who contribute to the project and may add documents.
const addsRecords = computed(() => editable.value && can('paper.add'))
const addingRecords = ref(false)
// Who tasks can be assigned to: the service's people and the agents.
const people = ref<Person[]>([])
const personLabel = (id: string) => people.value.find(p => p.id === id)?.label ?? id
// Who reaches the open project, whom its questions can be asked of.
const projectPeople = ref<Person[]>([])

// The address names a project (#KB) or a task in one (#KB-12).
const fromHash = () => { const m = location.hash.slice(1).toUpperCase().match(/^([A-Z][A-Z0-9]*)(?:-(\d+))?$/); return m ? { key: m[1], task: m[2] ? m[0] : '' } : null }
async function loadList() {
  const r = await getJSON('/api/projects'); list.value = r.projects; statuses.value = r.statuses
  people.value = await getJSON('/api/tasks/people')
  const named = fromHash()?.key
  if (!key.value) key.value = (named && list.value.some(p => p.key === named) ? named : list.value[0]?.key) || ''
}
// A board that arrives after another project was chosen is dropped.
async function loadBoard() {
  const k = key.value
  if (!k) { board.value = null; return }
  try {
    const [b, them] = await Promise.all([getJSON(`/api/projects/${k}`), getJSON(`/api/tasks/people?project=${k}`).catch(() => [])])
    if (k === key.value) { board.value = b; projectPeople.value = them; error.value = '' }
  } catch (e: any) { if (k === key.value) error.value = e.message }
}
// What waits on the person: plans to approve, tasks in Review, findings agents drafted, and their own open tasks.
// With them, the questions the person asked that still wait on someone (`asked`), which only Focus shows.
type Asked = Task & { question?: string; note?: number; asker?: string; answer?: string; answerer?: string; claim?: string; recheck?: string[];
                      concerns?: boolean; to_whom?: string; to_person?: string }
type Section = 'proposed' | 'questions' | 'answered' | 'review' | 'findings' | 'mine'
const waiting = ref<Record<Section | 'asked', Asked[]>>({ proposed: [], questions: [], answered: [], review: [], findings: [], mine: [], asked: [] })
const waitingOpen = ref('')
const WAITING = [{ id: 'proposed', label: 'to approve' }, { id: 'questions', label: 'to answer' }, { id: 'answered', label: 'answered' },
                 { id: 'review', label: 'to review' }, { id: 'findings', label: 'to accept' }, { id: 'mine', label: 'yours' }] as const
// Marking question `note` on task `r` resolved, settled some other way or no longer needing an
// answer; with no note, every question open there. An answer to your question waits on you until
// you write on the task again or mark it resolved.
async function resolve(r: string, note = 0) {
  await sendOnce(`resolve:${r}:${note}`, async () => {
    try {
      const t = await post(`/api/tasks/${r}/resolve`, JSON.stringify({ note }))
      if (open.value?.ref === r) open.value = t
      await loadWaiting()
    } catch (e: any) { error.value = e.message }
  })
}
// A question waiting on you opens its task ready for your reply.
async function openWaiting(t: Asked, section = waitingOpen.value) {
  await show(t)
  const e = section === 'questions' && t.note ? open.value?.activity.find(x => x.id === t.note) : undefined
  if (e) startReply(e)
}
async function loadWaiting() { try { waiting.value = await getJSON('/api/tasks/waiting') } catch { /* the board still shows */ } }
// Focus: what waits on the person in the project, and nothing else of the board, for someone who
// comes to a project to do their part. Their questions to answer, the answers to theirs, their tasks
// by where they stand, the plans and reviews that concern them, and the questions they asked still
// waiting; the rest of what waits in the project, counted. Remembered for each project in this browser.
const FOCUS = 'zemi-board-focus'
const focusKeys = ref<string[]>([])
const focus = computed(() => !!key.value && focusKeys.value.includes(key.value))
function toggleFocus() {
  const k = key.value
  focusKeys.value = focus.value ? focusKeys.value.filter(x => x !== k) : [...focusKeys.value, k]
  focusKeys.value.length ? localStorage.setItem(FOCUS, JSON.stringify(focusKeys.value)) : localStorage.removeItem(FOCUS)
}
onMounted(() => { try { const v = JSON.parse(localStorage.getItem(FOCUS) ?? '[]'); if (Array.isArray(v)) focusKeys.value = v } catch { /* none kept */ } })
const FOCUS_ORDER = ['in_progress', 'ready', 'backlog', 'review', 'proposed']
const focused = computed(() => {
  const here = (xs: Asked[]) => xs.filter(t => t.ref.startsWith(`${key.value}-`))
  const w = waiting.value, mine = here(w.mine), mineRefs = new Set(mine.map(t => t.ref))
  const decide = (xs: Asked[]) => editable.value ? here(xs).filter(t => t.concerns && !mineRefs.has(t.ref)) : []
  const rest = (xs: Asked[]) => editable.value ? here(xs).filter(t => !t.concerns && !mineRefs.has(t.ref)).length : 0
  const findings = editable.value ? here(w.findings).length : 0
  return {
    questions: here(w.questions), answered: here(w.answered), asked: here(w.asked),
    tasks: FOCUS_ORDER.map(id => ({ id, tasks: mine.filter(t => t.status === id) })).filter(g => g.tasks.length),
    approve: decide(w.proposed), review: decide(w.review),
    rest: [[rest(w.proposed), 'plan', 'to approve'], [rest(w.review), 'task', 'to review'], [findings, 'finding', 'to accept']]
      .filter(([n]) => n).map(([n, one, what]) => `${n} ${one}${n === 1 ? '' : 's'} ${what}`),
  }
})
const focusEmpty = computed(() => { const f = focused.value
  return !f.questions.length && !f.answered.length && !f.asked.length && !f.tasks.length && !f.approve.length && !f.review.length })
const askedOf = (t: Asked) => t.to_whom === 'agents' ? 'the agents' : t.to_whom === 'anyone' ? 'anyone on the project' : personLabel(t.to_person ?? '')
// The project's codebase: where its code is, which agents working there find it by, and whose
// commits are recorded against its tasks. A person links it, or changes it.
const codebases = ref<{ id: string; title: string }[] | null>(null)
const codeDraft = ref<string | null>(null)
async function editCodebase() {
  codeDraft.value = board.value?.codebase?.id ?? 'none'
  if (!codebases.value) try { codebases.value = await getJSON('/api/tasks/codebases') } catch (e: any) { error.value = e.message }
}
async function saveCodebase() {
  try { await post(`/api/projects/${key.value}`, JSON.stringify({ codebase: codeDraft.value })); codeDraft.value = null; await loadBoard() }
  catch (e: any) { error.value = e.message }
}
const remoteName = (u: string) => u.replace(/^https:\/\//, '')
// A task's commits (those whose Tasks: trailer names it or a task under it), and their changes.
const diffText = ref<string | null>(null)
async function toggleDiff() {
  if (diffText.value !== null || !open.value) { diffText.value = null; return }
  try { diffText.value = (await getJSON(`/api/tasks/${open.value.ref}/diff`)).diff } catch (e: any) { error.value = e.message }
}
const diffLines = computed(() => (diffText.value ?? '').split('\n').map(l => ({ text: l,
  cls: /^(diff --git|\+\+\+ |--- |index )/.test(l) ? 'file' : l === '---' ? '' : l.startsWith('+') ? 'add' : l.startsWith('-') ? 'del' :
       l.startsWith('@@') ? 'hunk' : l.startsWith('commit ') ? 'commit' : '' })))
const commitTotals = computed(() => (open.value?.commits ?? []).reduce((a, c) => ({ added: a.added + c.added, removed: a.removed + c.removed }), { added: 0, removed: 0 }))
// What agents are at work on (see src/agent_activity.jl): tasks in progress they worked on in the
// last half hour, which stop counting as time passes, and where they wait for people.
const ACTIVE_MS = 30 * 60_000
const clock = ref(Date.now())
// Started once mounted: during the build's server rendering an interval would keep the build running.
let ticking: ReturnType<typeof setInterval> | undefined
onMounted(() => { ticking = setInterval(() => { clock.value = Date.now() }, 30_000) })
onBeforeUnmount(() => clearInterval(ticking))
const atWork = computed(() => new Map((board.value?.agents?.tasks ?? []).filter(a => clock.value - Date.parse(a.at) < ACTIVE_MS).map(a => [a.ref, a])))
const workedDirectly = computed(() => [...atWork.value.values()].filter(a => !a.via))
const agentName = (a: string) => a.replace(/ for .*$/, '')
// The board bar's menus: the agents at work, and the project's less frequent actions.
const menu = ref<'' | 'people' | 'agents' | 'more'>('')
const toggleMenu = (m: 'people' | 'agents' | 'more') => { menu.value = menu.value === m ? '' : m }
const closeMenu = (e: MouseEvent) => { if (menu.value && !(e.target as HTMLElement).closest('.kbp-pop')) menu.value = '' }
onMounted(() => document.addEventListener('mousedown', closeMenu))
onBeforeUnmount(() => document.removeEventListener('mousedown', closeMenu))
const taskTitle = (ref: string) => board.value?.tasks.find(t => t.ref === ref)?.title ?? ''
const agentsSummary = computed(() => {
  const names = [...new Set(workedDirectly.value.map(a => agentName(a.agent)))]
  const n = workedDirectly.value.length
  return n ? `${names.join(', ')} · ${n} task${n === 1 ? '' : 's'}` : `${(board.value?.agents?.waiting ?? []).length} agent waiting`
})
// Presence (src/people_activity.jl): this board reports its person at the level they chose, hidden,
// present (the default: on the board, nothing more) or planning (the task open, what is being written
// on it, and who follows whom); and it follows the others' reports. Hidden stays as this browser was
// left; planning is chosen each visit.
const HIDDEN = 'zemi-presence-hidden'
const PRESENCE_LEVELS = [
  { id: 'hidden', label: 'Hidden', help: 'Others do not see you here.' },
  { id: 'present', label: 'Here', help: 'Others see you are on the board, nothing more.' },
  { id: 'planning', label: 'Planning', help: 'Others see the task you have open and what you write on it, and can follow you.' },
] as const
const hidden = ref(false)
const planning = ref(false)
const followee = ref(0)
const presence = ref<Viewer[]>([])
const myId = ref(0)
const presenceMode = () => hidden.value ? 'hidden' : planning.value ? 'planning' : 'present'
function setPresence(m: 'hidden' | 'present' | 'planning') {
  hidden.value = m === 'hidden'; planning.value = m === 'planning'
  hidden.value ? localStorage.setItem(HIDDEN, '1') : localStorage.removeItem(HIDDEN)
}
// What is in view, for those following: the board's view, the card nearest the middle of the screen,
// the card pointed at, and how far down the open task's panel is (a share of its height, so screens of
// different sizes show the same part).
const inView = ref({ focus: '', hover: '', panel: 0, control: '' })
const viewNow = () => JSON.stringify({ milestone: milestone.value, declined: !!declined.value, reviewing: reviewing.value,
                                       library: library.value, ...inView.value })
let soon: ReturnType<typeof setTimeout> | undefined
// At most every 120 ms while things move, so a long scroll is followed as it happens, not when it stops.
const reportSoon = () => { if (planning.value && !soon) soon = setTimeout(() => { soon = undefined; report() }, 120) }
// The part of the window the board shows through: below the site's top bar, and beside or above the
// task's panel when it is docked to the right or the bottom.
function visibleArea() {
  const top = document.querySelector('.VPNav')?.getBoundingClientRect().bottom ?? 0
  const dock = document.querySelector<HTMLElement>('.kbd')
  const d = dock?.getBoundingClientRect()
  return { top, left: 0, bottom: d && dock!.classList.contains('bottom') ? d.top : innerHeight,
           right: d && dock!.classList.contains('right') ? d.left : innerWidth }
}
// A card brought to the middle of what can be seen of the board, down the page and across the columns.
function centerOn(el: HTMLElement) {
  const a = visibleArea(), r = el.getBoundingClientRect()
  scrollBy({ top: r.top + r.height / 2 - (a.top + a.bottom) / 2, behavior: 'smooth' })
  const cols = el.closest<HTMLElement>('.kbp-board')
  if (cols) {
    const c = cols.getBoundingClientRect(), mid = (Math.max(a.left, c.left) + Math.min(a.right, c.right)) / 2
    cols.scrollBy({ left: r.left + r.width / 2 - mid, behavior: 'smooth' })
  }
}
function noteFocus() {
  let best = '', d = Infinity
  const a = visibleArea(), mx = (a.left + a.right) / 2, my = (a.top + a.bottom) / 2
  for (const el of document.querySelectorAll<HTMLElement>('.kbp-card[data-ref]')) {
    const r = el.getBoundingClientRect(), dist = Math.hypot(r.left + r.width / 2 - mx, r.top + r.height / 2 - my)
    if (dist < d) { d = dist; best = el.dataset.ref ?? '' }
  }
  if (best !== inView.value.focus) { inView.value.focus = best; reportSoon() }
}
function onScroll(e: Event) {
  if (!planning.value) return
  const t = e.target as HTMLElement
  if (t instanceof HTMLElement && t.classList.contains('kbd-body')) {
    const share = Math.round(100 * t.scrollTop / Math.max(1, t.scrollHeight - t.clientHeight)) / 100
    if (share !== inView.value.panel) { inView.value.panel = share; reportSoon() }
  } else noteFocus()
}
// The control being used (`data-control`: a task's status, priority, subtasks, the comment box…).
function onControl(e: Event) {
  if (!planning.value) return
  const c = (e.target as HTMLElement).closest?.<HTMLElement>('[data-control]')?.dataset.control ?? ''
  if (c !== inView.value.control) { inView.value.control = c; reportSoon() }
}
function onPoint(e: Event) {
  if (!planning.value) return
  const ref_ = (e.target as HTMLElement).closest?.<HTMLElement>('.kbp-card[data-ref]')?.dataset.ref ?? ''
  if (ref_ !== inView.value.hover) { inView.value.hover = ref_; reportSoon() }
}
onMounted(() => { document.addEventListener('scroll', onScroll, true); document.addEventListener('mouseover', onPoint)
                  document.addEventListener('focusin', onControl); document.addEventListener('pointerdown', onControl) })
onBeforeUnmount(() => { document.removeEventListener('scroll', onScroll, true); document.removeEventListener('mouseover', onPoint)
                        document.removeEventListener('focusin', onControl); document.removeEventListener('pointerdown', onControl) })
const report = () => shared.value ? post('/api/presence', JSON.stringify({
  mode: presenceMode(), project: key.value, open: open.value?.ref ?? '', following: followee.value, view: planning.value ? viewNow() : '',
  draft_ref: planning.value && comment.value.trim() ? open.value?.ref ?? '' : '', draft: planning.value ? comment.value : '' })).catch(() => {}) : null
let presenceVersion = -1, presenceOn = false, beat: ReturnType<typeof setInterval> | undefined, typing: ReturnType<typeof setTimeout> | undefined
async function followPresence() {
  while (presenceOn) {
    try {
      const r = await getJSON(`/api/presence?since=${presenceVersion}`)
      presenceVersion = r.version; myId.value = r.me; presence.value = r.people
    } catch { await new Promise(res => setTimeout(res, 3000)) }
  }
}
const others = computed(() => presence.value.filter(p => p.project === key.value))
const peopleDid = computed(() => board.value?.people_did ?? [])
const followers = computed(() => presence.value.filter(p => p.following === myId.value))
// Who has each task open, of those planning; and what they are writing on the open one.
const viewers = computed(() => {
  const m = new Map<string, string[]>()
  for (const p of others.value) if (p.planning && p.open) m.set(p.open, [...(m.get(p.open) ?? []), p.name])
  return m
})
const writing = computed(() => others.value.filter(p => p.planning && p.draft && p.draft_ref === open.value?.ref))
// Following someone, what they are writing is kept in view as it grows.
const writingEls: Record<number, HTMLElement> = {}
watch(() => writing.value.find(p => p.id === followee.value)?.draft, d => {
  if (d) nextTick(() => writingEls[followee.value]?.scrollIntoView({ block: 'nearest', behavior: 'smooth' }))
})
// Following someone planning: this board goes where theirs goes, until they stop planning or this
// person opens something else.
const leader = computed(() => presence.value.find(p => p.id === followee.value) ?? null)
watch(leader, l => {
  if (!followee.value) return
  if (!l || !l.planning) { followee.value = 0; return }
  if (l.open && l.open !== open.value?.ref) openRef(l.open)
  else if (!l.open && l.project !== key.value) key.value = l.project
  else if (!l.open && open.value) open.value = null
})
// And what is in view: the board's view, the card in the middle, how far down the open task, and the
// card pointed at, marked with their initials.
const pointedBy = ref<{ ref: string; name: string } | null>(null)
let centered = ''          // the card last brought to the middle, so a repeated report does not move it again
// The task's panel glides toward how far down the leader is, each frame a share of the way, so reports
// arriving unevenly move it smoothly rather than starting a new scroll each time.
let panelShare = 0, gliding = false
function glideTo(share: number) {
  panelShare = share
  if (gliding) return
  gliding = true
  const step = () => {
    const body = document.querySelector<HTMLElement>('.kbd-body')
    if (!body || !followee.value) { gliding = false; return }
    const target = panelShare * (body.scrollHeight - body.clientHeight), gap = target - body.scrollTop
    if (Math.abs(gap) < 1) { body.scrollTop = target; gliding = false; return }
    body.scrollTop += gap * 0.18
    requestAnimationFrame(step)
  }
  requestAnimationFrame(step)
}
watch(() => leader.value?.view, async v => {
  if (!followee.value || !v) { pointedBy.value = null; return }
  let w: any; try { w = JSON.parse(v) } catch { return }
  if (w.milestone !== milestone.value) milestone.value = w.milestone
  if (!!declined.value !== w.declined) toggleDeclined()
  reviewing.value = w.reviewing; library.value = w.library
  pointedBy.value = w.hover ? { ref: w.hover, name: leader.value!.name } : null
  await nextTick()
  // The control they are using, outlined (and brought into view in the task's panel).
  document.querySelectorAll('.kbp-touched').forEach(el => el.classList.remove('kbp-touched'))
  const ctl = w.control && document.querySelector<HTMLElement>(`[data-control="${w.control}"]`)
  if (ctl) { ctl.classList.add('kbp-touched'); if (ctl.closest('.kbd-body')) ctl.scrollIntoView({ block: 'nearest', behavior: 'smooth' }) }
  const card = w.focus && document.querySelector<HTMLElement>(`.kbp-card[data-ref="${w.focus}"]`)
  if (card && w.focus !== centered) { centered = w.focus; centerOn(card) }
  if (open.value) glideTo(w.panel)
})
watch(followee, f => { if (!f) { pointedBy.value = null; centered = ''; document.querySelectorAll('.kbp-touched').forEach(el => el.classList.remove('kbp-touched')) } })
watch(() => open.value?.ref, r => { const l = leader.value; if (followee.value && l && (r ?? '') !== l.open && (r || l.project === key.value)) followee.value = 0 })
// The pen of a session (src/people_activity.jl): whoever is planning, and those following them.
// With the pen out, where this person points shows on the others' boards as a dot,
// and dragging draws a line; both fade in a moment. A point is anchored to what is under it (a card,
// a control, a place in the open task), so a screen laid out differently shows it over the same thing.
// A point: the stable container it is in (`a`: a card, a control, the task's panel, the board), the
// path of child positions from there to the element under the pointer (`p`), and where in that
// element's box it is (`x`, `y`, shares of its width and height). Two people looking at the same card
// or task have the same elements inside it, so the path finds the same line, button or paragraph, and
// a point lands on the same spot of it however their screens lay it out. A line drawn is anchored once,
// at its first point: the rest are offsets from there (`dx`, `dy`), scaled by how wide its container is
// here against there (`w`), so a circle stays a circle wherever the things it crosses fall.
type InkPoint = { a: string; p: string; x: number; y: number; d: 0 | 1; t: number; dx?: number; dy?: number; w?: number }
const INK_FADE = 1500, DOT_FADE = 700
const INK_COLORS = ['#ff6b6b', '#4dabf7', '#ffd43b', '#69db7c', '#da77f2', '#ff922b', '#38d9a9', '#f783ac']
const inkColor = (id: number) => INK_COLORS[Math.abs(id) % INK_COLORS.length]
const inSession = computed(() => planning.value || !!(leader.value?.planning && leader.value.project === key.value))
const pen = ref(false)
watch(inSession, on => { if (!on) pen.value = false })
const inkCanvas = ref<HTMLCanvasElement | null>(null)
const strokes = new Map<string, { id: number; name: string; points: InkPoint[] }>()   // by person and stroke
function containerOf(el: HTMLElement): [string, HTMLElement] {
  const card = el.closest<HTMLElement>('.kbp-card[data-ref]'); if (card) return [`ref:${card.dataset.ref}`, card]
  const ctl = el.closest<HTMLElement>('[data-control]'); if (ctl) return [`ctl:${ctl.dataset.control}`, ctl]
  const body = el.closest<HTMLElement>('.kbd-body'); if (body) return ['panel', body]
  const board = el.closest<HTMLElement>('.kbp'); if (board) return ['board', board]
  return ['page', document.body]
}
function containerFor(a: string): HTMLElement | null {
  if (a.startsWith('ref:')) return document.querySelector(`.kbp-card[data-ref="${a.slice(4)}"]`)
  if (a.startsWith('ctl:')) return document.querySelector(`.kbd [data-control="${a.slice(4)}"]`) ?? document.querySelector(`[data-control="${a.slice(4)}"]`)
  return a === 'panel' ? document.querySelector('.kbd-body') : a === 'board' ? document.querySelector('.kbp') : document.body
}
function anchorAt(x: number, y: number) {
  const el = (document.elementsFromPoint(x, y) as HTMLElement[]).find(e => !e.closest('.kbp-ink-catch, .kbp-ink, .kbp-session'))
  if (!el) return { a: 'page', p: '', x: x / innerWidth, y: y / innerHeight }
  const [a, root] = containerOf(el), path: number[] = []
  for (let n: HTMLElement = el; n !== root && n.parentElement; n = n.parentElement) path.unshift(Array.prototype.indexOf.call(n.parentElement.children, n))
  const r = el.getBoundingClientRect()
  return { a, p: path.join('.'), x: r.width ? (x - r.left) / r.width : 0.5, y: r.height ? (y - r.top) / r.height : 0.5 }
}
function placeOf(p: InkPoint): [number, number] | null {
  let el: Element | null = containerFor(p.a)
  if (!el) return null
  // Down the path as far as it goes here; a step that is missing leaves the point on the deepest found.
  for (const i of p.p ? p.p.split('.').map(Number) : []) { const c: Element | undefined = el!.children[i]; if (!c) break; el = c }
  const r = el!.getBoundingClientRect(), at: [number, number] = [r.left + p.x * r.width, r.top + p.y * r.height]
  if (p.dx === undefined || !p.w) return at
  const scale = (containerFor(p.a)?.getBoundingClientRect().width ?? p.w) / p.w
  return [at[0] + p.dx * scale, at[1] + (p.dy ?? 0) * scale]
}
let drawing = false, inkFrame = 0
function paint() {
  const cv = inkCanvas.value; inkFrame = 0
  if (!cv) return
  const dpr = devicePixelRatio || 1
  if (cv.width !== innerWidth * dpr || cv.height !== innerHeight * dpr) { cv.width = innerWidth * dpr; cv.height = innerHeight * dpr }
  const g = cv.getContext('2d')!; g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, innerWidth, innerHeight)
  const now = performance.now(); let live = false
  for (const [k, s] of strokes) {
    s.points = s.points.filter(p => now - p.t < INK_FADE)
    if (!s.points.length) { strokes.delete(k); continue }
    live = true
    const color = inkColor(s.id); g.strokeStyle = color; g.lineWidth = 3; g.lineCap = 'round'; g.lineJoin = 'round'
    for (let i = 1; i < s.points.length; i++) {
      const p = s.points[i], q = s.points[i - 1]
      if (!p.d || !q.d) continue
      const a = placeOf(q), b = placeOf(p); if (!a || !b) continue
      g.globalAlpha = Math.max(0, 1 - (now - p.t) / INK_FADE); g.beginPath(); g.moveTo(a[0], a[1]); g.lineTo(b[0], b[1]); g.stroke()
    }
    const last = s.points[s.points.length - 1], at = placeOf(last), age = now - last.t
    if (at && age < DOT_FADE) {
      g.globalAlpha = 1 - age / DOT_FADE; g.fillStyle = color
      g.shadowColor = color; g.shadowBlur = 12; g.beginPath(); g.arc(at[0], at[1], 6, 0, 2 * Math.PI); g.fill(); g.shadowBlur = 0
      g.font = '600 11px system-ui, sans-serif'; g.fillText(initials(s.name), at[0] + 9, at[1] - 9)
    }
  }
  g.globalAlpha = 1
  if (live) inkFrame = requestAnimationFrame(paint)
}
const repaint = () => { if (!inkFrame) inkFrame = requestAnimationFrame(paint) }
function addPoints(id: number, name: string, stroke: string, points: InkPoint[]) {
  const k = `${id}:${stroke}`, s = strokes.get(k) ?? { id, name, points: [] }
  s.points.push(...points); strokes.set(k, s); repaint()
}
// Sending: points gathered and sent about 20 times a second, the stroke named afresh at each press.
let stroke = '', unsent: InkPoint[] = [], flushing: ReturnType<typeof setTimeout> | undefined, lastSent = 0
function send(p: InkPoint) {
  addPoints(myId.value, me.value?.name ?? '', stroke, [{ ...p, t: performance.now() }])
  unsent.push(p)
  if (!flushing) flushing = setTimeout(() => {
    flushing = undefined; const batch = unsent; unsent = []
    post('/api/ink', JSON.stringify({ project: key.value, stroke, points: JSON.stringify(batch) })).catch(() => {})
  }, 50)
}
// A line's first point, where it was on this screen, and how wide its container was.
let origin: ReturnType<typeof anchorAt> | null = null, ox = 0, oy = 0, ow = 0
function inkMove(e: PointerEvent) {
  const now = performance.now(); if (!drawing && now - lastSent < 40) return
  lastSent = now
  if (drawing && origin) send({ ...origin, d: 1, t: 0, dx: e.clientX - ox, dy: e.clientY - oy, w: ow })
  else send({ ...anchorAt(e.clientX, e.clientY), d: drawing ? 1 : 0, t: 0 })
}
function inkDown(e: PointerEvent) {
  drawing = true; stroke = Math.random().toString(36).slice(2, 8)
  origin = anchorAt(e.clientX, e.clientY); ox = e.clientX; oy = e.clientY
  ow = containerFor(origin.a)?.getBoundingClientRect().width || innerWidth
  inkMove(e)
}
function inkUp() { drawing = false; origin = null; stroke = Math.random().toString(36).slice(2, 8) }
// The wheel still scrolls what is under the pointer, the task's panel or the page.
function inkWheel(e: WheelEvent) {
  const under = (document.elementsFromPoint(e.clientX, e.clientY) as HTMLElement[]).find(el => !el.closest('.kbp-ink-catch, .kbp-ink'))
  ;(under?.closest<HTMLElement>('.kbd-body') ?? document.scrollingElement)?.scrollBy(0, e.deltaY)
}
// Esc puts the pen away; P takes it out or puts it away, unless a field is being typed in.
const inkKey = (e: KeyboardEvent) => {
  if (e.key === 'Escape' && pen.value) pen.value = false
  const typing = (e.target as HTMLElement).closest?.('input, textarea, select, [contenteditable="true"]')
  if ((e.key === 'p' || e.key === 'P') && !typing && !e.metaKey && !e.ctrlKey && !e.altKey && inSession.value) pen.value = !pen.value
}
onMounted(() => document.addEventListener('keydown', inkKey))
onBeforeUnmount(() => document.removeEventListener('keydown', inkKey))
// Receiving: the others' points, while in a session.
let inkSeq = -1, inkOn = false
async function followInk() {
  while (inkOn) {
    try {
      const r = await getJSON(`/api/ink?since=${inkSeq}&project=${encodeURIComponent(key.value)}`)
      const first = inkSeq === -1; inkSeq = r.seq
      if (first) continue
      const now = performance.now()
      for (const s of r.strokes) { const ps: InkPoint[] = JSON.parse(s.points); addPoints(s.id, s.name, s.stroke, ps.map((p, i) => ({ ...p, t: now - (ps.length - 1 - i) * 40 }))) }
    } catch { await new Promise(res => setTimeout(res, 2000)) }
  }
}
watch(inSession, on => { if (on && !inkOn) { inkOn = true; inkSeq = -1; followInk() } else if (!on) inkOn = false })
onBeforeUnmount(() => { inkOn = false })
const initials = (name: string) => name.split(/[\s@.]+/).filter(Boolean).slice(0, 2).map(w => w[0].toUpperCase()).join('')
const hereTitle = (p: Viewer) => `${p.name} · ${p.planning ? (p.open ? `planning, on ${p.open} ${taskTitle(p.open)}` : 'planning, on the board') : 'here'}`
function actionText(e: Action) {
  const t = `${e.ref} ${e.title}`
  switch (e.kind) {
    case 'created': return `created ${t}`
    case 'status': return `moved ${t} to ${label(e.detail.to)}`
    case 'comment': return `commented on ${t}`
    case 'question': return `asked about ${t}`
    case 'progress': case 'note': return `wrote on ${t}`
    default: return `${eventText(e as unknown as TaskEvent)} · ${t}`
  }
}
const since = (at: string) => {
  const m = Math.max(0, Math.round((clock.value - Date.parse(at)) / 60_000))
  return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 24 * 60 ? `${Math.round(m / 60)} h ago` : when(at)
}
const ago = (at: string) => { const m = Math.max(0, Math.round((clock.value - Date.parse(at)) / 60_000)); return m < 1 ? 'just now' : `${m} min ago` }
const workTitle = (ref: string) => { const a = atWork.value.get(ref); return a ? `${a.agent} · ${a.via ? `on ${a.via} · ` : ''}${ago(a.at)}` : '' }
// Deleting the open project with everything in it (its owner, and admins).
async function deleteProject() {
  const n = board.value?.tasks.length ?? 0
  if (!confirm(`Delete ${key.value}${n ? ` and its ${n} task${n === 1 ? '' : 's'}` : ''}?`)) return
  try {
    await post(`/api/projects/${key.value}/delete`, '{}')
    key.value = ''
    await loadList()
  } catch (e: any) { error.value = e.message }
}
// The project's review (KBProjectReview): figures over time, and the history of what it finished.
const reviewing = ref(false)
// Milestones still being worked on: what the board's chips and menus offer.
const openMilestones = computed(() => (board.value?.milestones ?? []).filter(m => !m.closed))
// Plans a person declined, kept apart from the archive with why, and brought back to Proposed at will.
const declined = ref<(Task & { reason: string; declined_at: string })[] | null>(null)
async function loadDeclined() { try { declined.value = await getJSON(`/api/projects/${key.value}/declined`) } catch (e: any) { error.value = e.message } }
const toggleDeclined = () => declined.value ? (declined.value = null) : loadDeclined()
// The project's library (KBLibrary): the papers, notebooks and codebases it works from.
const library = ref(false)
async function decline(r: string, undo = false) {
  const reason = undo ? '' : prompt(`Decline ${r}? Why (optional):`, '')
  if (reason === null) return
  await sendOnce(`task:${r}`, async () => {
    if (!undo) showMoving(r, 'declined')
    try {
      const t = await post(`/api/tasks/${r}/decline`, JSON.stringify({ reason, undo }))
      if (open.value?.ref === r) open.value = undo ? t : null
      await loadBoard(); loadWaiting()
      if (declined.value) loadDeclined()
    } catch (e: any) { error.value = e.message }
    finally { showMoving(r) }
  })
}
async function archiveTask(undo = false) {
  const r = open.value?.ref
  if (!r) return
  await sendOnce(`task:${r}`, async () => {
    try { open.value = await post(`/api/tasks/${r}/archive`, JSON.stringify({ undo })); await refresh() } catch (e: any) { error.value = e.message }
  })
}
// Picking a milestone's chip shows only it and makes it the project's active one, where new tasks go
// (agents' too); picking it again shows every milestone, and it stays active. A done one is only shown.
function pickMilestone(m: Milestone) {
  if (milestone.value === m.name) { milestone.value = ''; return }
  milestone.value = m.name
  if (manages.value && !m.closed && !m.active) setActive(m.name)
}
async function setActive(name: string) {
  try { await post(`/api/projects/${key.value}/active-milestone`, JSON.stringify({ name })); await loadBoard() } catch (e: any) { error.value = e.message }
}
// Marking a milestone done archives its completed tasks; reopening it brings nothing back.
const chosenMs = computed(() => board.value?.milestones.find(m => m.name === milestone.value) ?? null)
// Completing a milestone: each unfinished task in it is marked done or moved to the backlog (into
// another milestone, or none), then its completed tasks are archived. Reopening one is direct.
type Settle = { t: Task; action: 'done' | 'backlog'; milestone: string }
const completing = ref<{ m: Milestone; rows: Settle[]; archived: number } | null>(null)
const otherMilestones = computed(() => (board.value?.milestones ?? []).filter(x => !x.closed && x.name !== completing.value?.m.name))
// The project's description: context its people give the agents working on it (see next_task).
const editingContext = ref(false), contextDraft = ref(''), contextOpen = ref(false)
// Shown whole when short; a longer one shows its first lines until opened.
const longContext = computed(() => { const d = board.value?.project.description ?? ''; return d.length > 240 || d.split('\n').length > 3 })
function editContext() { contextDraft.value = board.value?.project.description ?? ''; editingContext.value = true }
async function saveContext() {
  try {
    await post(`/api/projects/${key.value}`, JSON.stringify({ description: contextDraft.value }))
    editingContext.value = false
    await loadBoard()
  } catch (e: any) { error.value = e.message }
}
async function finishMilestone(m: Milestone) {
  if (m.closed) {
    try { await post(`/api/projects/${key.value}/milestone-done`, JSON.stringify({ name: m.name, reopen: true })); await loadBoard() }
    catch (e: any) { error.value = e.message }
    return
  }
  const mine = (board.value?.tasks ?? []).filter(t => !t.parent && t.milestone === m.name)
  const active = board.value?.project.active_milestone ?? ''
  const next = active && active !== m.name ? active : ''
  completing.value = { m, archived: mine.filter(t => t.status === 'done').length,
                       rows: mine.filter(t => t.status !== 'done').map(t => ({ t, action: 'backlog', milestone: next })) }
}
const settleAll = (action: 'done' | 'backlog', milestone = '') =>
  completing.value?.rows.forEach(r => { r.action = action; if (action === 'backlog') r.milestone = milestone })
async function completeMilestone() {
  const c = completing.value
  if (!c) return
  const decisions = c.rows.map(r => ({ ref: r.t.ref, action: r.action, milestone: r.milestone }))
  try {
    await post(`/api/projects/${key.value}/milestone-done`, JSON.stringify({ name: c.m.name, decisions }))
    completing.value = null
    if (milestone.value === c.m.name) milestone.value = ''
    await loadBoard(); loadWaiting()
  } catch (e: any) { error.value = e.message }
}
async function archiveDone() {
  const n = column('done').filter(t => !t.parent).length
  if (!n || !confirm(`Archive the ${n} done task${n > 1 ? 's' : ''}?`)) return
  try { await post(`/api/projects/${key.value}/archive-done`, '{}'); await refresh() } catch (e: any) { error.value = e.message }
}
async function refresh() {
  loadWaiting()
  if (declined.value) loadDeclined()
  await loadBoard()
  const r = open.value?.ref
  if (!r) return
  try { const t = await opening(signal => getJSON(`/api/tasks/${r}`, { signal })); if (open.value?.ref === r) open.value = t }
  catch (e) { if (!isStale(e)) throw e }
}
onLive(async () => {
  if (!can('tasks.view')) return
  baseTitle = document.title
  const initial = fromHash()   // read before choosing the project rewrites the address
  window.addEventListener('hashchange', onHash)
  try { await loadList(); await loadBoard(); loadWaiting(); if (initial?.task) await openRef(initial.task) } catch (e: any) { error.value = e.message }
  follow()
  return () => { document.title = baseTitle; window.removeEventListener('hashchange', onHash) }
})
onBeforeUnmount(() => { following = false })

// Following changes: the server answers /api/tasks/changes when projects or tasks change (or after a
// while without), and the page asks again. An update shows without disturbing what is being edited
// (the plan's draft and a comment are kept) and waits for a drag to end; cards that changed glow,
// the count of what waits on the person pulses when it grows and is in the tab's title, and each of
// its sections pulses when what is in it changes, the rows that changed glowing in an open list.
const live = ref(false)
const flashed = ref<Set<string>>(new Set())
const pulse = ref(false)
const pulsing = ref<Set<string>>(new Set())        // sections of Waiting on you whose items changed
const freshRows = ref<Set<string>>(new Set())      // "section:ref" of the rows that changed
// What a row is, as far as noticing a change goes: the task's last change and any question with it.
const rowKey = (t: Asked) => `${t.ref}|${t.updated_at}|${t.question ?? ''}`
const sectionRows = () => Object.fromEntries(WAITING.map(w => [w.id, new Set(shownWaiting.value[w.id].map(rowKey))]))
let following = true, version = -1, pending = false, baseTitle = ''
// The bar shows what waits in the project (in the milestone, with one picked); the tab's title counts
// what waits in every project.
const shownWaiting = computed(() => {
  const m = milestone.value
  const inIt = (t: Asked) => t.ref.startsWith(`${key.value}-`) && (!m || t.milestone === m || t.claim !== undefined)
  return Object.fromEntries(WAITING.map(w => [w.id, waiting.value[w.id].filter(inIt)])) as typeof waiting.value
})
const count = (w: typeof waiting.value) => WAITING.reduce((n, x) => n + w[x.id].length, 0)
const waitingCount = () => count(shownWaiting.value)
// Whether the person is looking at the board: its page visible and focused. The service pushes them
// nothing meanwhile (see src/notify.jl), and is told at once when they stop.
const lookedAt = () => document.visibilityState === 'visible' && document.hasFocus()
function lookedAway() {
  if (!lookedAt()) fetch(`${api.value}/api/tasks/away`, { method: 'POST', body: '{}', keepalive: true,
                                                         headers: { 'Content-Type': 'application/json', 'X-Zemi': '1' } }).catch(() => {})
}
onMounted(() => { window.addEventListener('blur', lookedAway); document.addEventListener('visibilitychange', lookedAway) })
onBeforeUnmount(() => { window.removeEventListener('blur', lookedAway); document.removeEventListener('visibilitychange', lookedAway) })
async function follow() {
  while (following) {
    try {
      const r = await getJSON(`/api/tasks/changes?since=${version}${lookedAt() ? '&visible=1' : ''}`)
      live.value = true
      if (r.version !== version) { const first = version === -1; version = r.version; if (!first) await applyUpdate() }
    } catch {
      live.value = false
      await new Promise(res => setTimeout(res, 3000))
    }
  }
}
async function applyUpdate() {
  if (dragging.value) { pending = true; return }
  const before = new Map((board.value?.tasks ?? []).map(t => [t.ref, t.updated_at]))
  const had = waitingCount(), rowsBefore = sectionRows()
  await Promise.all([loadWaiting(), refresh()])
  const newRows = WAITING.flatMap(w => shownWaiting.value[w.id].filter(t => !rowsBefore[w.id].has(rowKey(t))).map(t => `${w.id}:${t.ref}`))
  if (newRows.length) {
    pulsing.value = new Set(newRows.map(r => r.split(':')[0])); freshRows.value = new Set(newRows)
    setTimeout(() => { pulsing.value = new Set(); freshRows.value = new Set() }, 6200)
  }
  const changed = (board.value?.tasks ?? []).filter(t => before.has(t.ref) ? before.get(t.ref) !== t.updated_at : before.size > 0)
  flashed.value = new Set(changed.map(t => t.ref))
  setTimeout(() => (flashed.value = new Set()), 6200)
  if (waitingCount() > had) { pulse.value = true; setTimeout(() => (pulse.value = false), 6200) }
}
watch(waiting, () => { if (baseTitle) { const n = count(waiting.value); document.title = (n ? `(${n}) ` : '') + baseTitle } }, { deep: true })
// An address that names no project (a footnote's `#fn…`, a heading's) leaves the board as it is.
function onHash() {
  const h = fromHash()
  if (!h || !list.value.some(p => p.key === h.key)) return
  if (h.key !== key.value) key.value = h.key
  if (h.task && h.task !== open.value?.ref) openRef(h.task)
}
const setHash = (h: string) => { if (location.hash.slice(1).toUpperCase() !== h) history.replaceState(history.state, '', '#' + h) }
watch(key, k => { if (k) setHash(k); open.value = null; milestone.value = ''; reviewing.value = false; declined.value = null; library.value = false; loadBoard() })
watch(open, t => { if (key.value) setHash(t ? t.ref : key.value) })
watch(() => open.value?.ref, () => { diffText.value = null })
watch(() => board.value?.codebase?.id ?? '', id => setCodebase(id), { immediate: true })

// Changes on their way to the service. Each is sent once: pressing its control again, or Enter in its
// form, waits for the answer rather than sending another, and the control shows it is working. A
// task's new status shows at once (its card in the new column) and goes back if the service refuses it.
const sending = ref(new Set<string>())
const busy = (what: string) => sending.value.has(what)
async function sendOnce(what: string, f: () => Promise<void>) {
  if (sending.value.has(what)) return
  sending.value = new Set(sending.value).add(what)
  try { await f() } finally { const s = new Set(sending.value); s.delete(what); sending.value = s }
}
const moving = ref(new Map<string, string>())
function showMoving(ref_: string, status?: string) {
  const m = new Map(moving.value)
  status ? m.set(ref_, status) : m.delete(ref_)
  moving.value = m
}

// Subtasks are on the board when asked for, and the open task always is, in its column.
// A subtask approved on its own, under a task still proposed: taken like any approved task.
const statusOf = computed(() => new Map((board.value?.tasks ?? []).map(t => [t.ref, t.status])))
const approvedAlone = (t: { parent: string; status: string }) => !!t.parent && t.status !== 'proposed' && statusOf.value.get(t.parent) === 'proposed'
// Tasks have cards; their subtasks are listed in them (when asked for), and the open task always has
// its own card, in its column.
// Each task's subtasks, read once per board: the board is drawn again on every move of a dragged
// card, so what is worked out from the tree is computed when the board changes, not when it is drawn.
const children = computed(() => {
  const m = new Map<string, Task[]>()
  for (const t of board.value?.tasks ?? []) if (t.parent) { if (!m.has(t.parent)) m.set(t.parent, []); m.get(t.parent)!.push(t) }
  return m
})
// The tasks for which `mark` holds of them or of a task under them, at any depth.
function marked(mark: (t: Task) => boolean): Set<string> {
  const out = new Set<string>()
  const visit = (t: Task): boolean => {
    let any = mark(t)
    for (const c of children.value.get(t.ref) ?? []) any = visit(c) || any
    if (any) out.add(t.ref)
    return any
  }
  const tasks = board.value?.tasks ?? [], refs = new Set(tasks.map(t => t.ref))
  for (const t of tasks) if (!t.parent || !refs.has(t.parent)) visit(t)        // from the top, and from any whose task is not here
  return out
}
// With a status chosen (`only`), the tasks in it and those with a subtask in it at any depth.
const only = ref('')
const holding = computed(() => only.value ? marked(t => (moving.value.get(t.ref) ?? t.status) === only.value) : new Set<string>())
const holds = (t: Task) => holding.value.has(t.ref)
const shown = computed(() => (board.value?.tasks ?? []).map(t => moving.value.has(t.ref) ? { ...t, status: moving.value.get(t.ref)! } : t)
  .filter(t => t.ref === open.value?.ref || !t.parent && (!milestone.value || t.milestone === milestone.value) && (!only.value || holds(t))))
// The subtasks a card lists: all of them, or with a status chosen, those in it and the ones leading to them.
const cardSubs = (r: string) => flat(below(r)).filter(n => !only.value || holds(n.t))
// How each column is sorted, as this browser was left. In the order the cards were put in (by
// dragging), a card an agent is working on now, itself or under it, comes first. The other sorts
// keep that order among cards they rank alike.
const SORT = 'zemi-board-sort'
const SORTS = [
  { id: 'manual', label: 'Your order', help: 'The order cards were dragged into, with those agents are working on first' },
  { id: 'priority', label: 'Priority', help: 'ASAP first, in the order marked so, then high, normal and low' },
  { id: 'milestone', label: 'Milestone', help: 'By when their milestone is due, the soonest first; tasks in none last' },
  { id: 'assignee', label: 'Assignee', help: 'Yours first, then by whom, the unassigned last' },
  { id: 'updated', label: 'Recently changed', help: 'The latest changed first' },
  { id: 'created', label: 'Newest', help: 'The latest made first' },
] as const
type SortId = typeof SORTS[number]['id']
const sortBy = ref<SortId>('manual')
const sorted = computed(() => sortBy.value !== 'manual')
watch(sortBy, s => s === 'manual' ? localStorage.removeItem(SORT) : localStorage.setItem(SORT, s))
onMounted(() => {
  const s = localStorage.getItem(SORT)
  if (SORTS.some(x => x.id === s)) sortBy.value = s as SortId
})
const working = computed(() => marked(t => atWork.value.has(t.ref)))
// What a card hints at: in colour, a question waiting on your answer (or an answer to yours) and a task
// of yours; with a dot, one others changed (people, or agents, yours too), filled since you opened the
// board, else hollow within the hours chosen, as this browser was left.
const CHANGED_HOURS = 'zemi-board-changed-hours', CHANGED_OFF = 'zemi-board-changed-off'
const CHANGED_CHOICES = [[1, '1 hour'], [4, '4 hours'], [24, 'a day'], [72, '3 days'], [168, 'a week']] as const
const changedOn = ref(true)
const changedHours = ref(4)
watch(changedOn, on => on ? localStorage.removeItem(CHANGED_OFF) : localStorage.setItem(CHANGED_OFF, '1'))
watch(changedHours, h => h === 4 ? localStorage.removeItem(CHANGED_HOURS) : localStorage.setItem(CHANGED_HOURS, String(h)))
onMounted(() => {
  changedOn.value = localStorage.getItem(CHANGED_OFF) !== '1'
  const h = Number(localStorage.getItem(CHANGED_HOURS) ?? NaN)
  if (CHANGED_CHOICES.some(([x]) => x === h)) changedHours.value = h
})
const openedAt = ref(Date.now())
const changeOf = (t: Task) => board.value?.changed_by_others?.[t.ref]
const changeTitle = (t: Task) => { const c = changeOf(t); return c ? `Changed by ${c.who}, ${when(c.at)}` : '' }
watch(key, () => { openedAt.value = Date.now() })
const askingMe = computed(() => new Set(waiting.value.questions.map(q => q.ref)))
const answeredMe = computed(() => new Set(waiting.value.answered.map(q => q.ref)))
function hints(t: Task) {
  const when = changeOf(t) ? Date.parse(changeOf(t)!.at) : 0
  const fresh = changedOn.value && when > openedAt.value
  return { mine: !!myPersonId.value && t.assignee === myPersonId.value, asking: askingMe.value.has(t.ref),
           answered: answeredMe.value.has(t.ref), fresh,
           recent: !fresh && changedOn.value && clock.value - when < changedHours.value * 3_600_000 }
}
// A milestone's place: dated ones by when they are due, then undated ones as the board lists them,
// then no milestone.
const milestoneRank = computed(() => {
  const ms = board.value?.milestones ?? []
  const dated = ms.filter(m => m.due).sort((a, b) => a.due.localeCompare(b.due))
  return new Map([...dated, ...ms.filter(m => !m.due)].map((m, i) => [m.name, i]))
})
const assigneeKey = (t: Task) => !t.assignee ? '￿' : t.assignee === myPersonId.value ? '' : personLabel(t.assignee).toLowerCase()
function sortKey(t: Task): (number | string)[] {
  switch (sortBy.value) {
    case 'priority': return [t.priority, t.priority === 0 ? (t.asap_at ?? '') : '']
    case 'milestone': return [t.milestone ? milestoneRank.value.get(t.milestone) ?? Infinity : Infinity]
    case 'assignee': return [assigneeKey(t)]
    case 'updated': return [-Date.parse(t.updated_at)]
    case 'created': return [-Date.parse(t.created_at)]
    default: return [working.value.has(t.ref) ? 0 : 1]
  }
}
const compareKeys = (a: (number | string)[], b: (number | string)[]) => {
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1
  return 0
}
const columns = computed(() => {
  const m = new Map<string, Task[]>()
  for (const t of shown.value) { if (!m.has(t.status)) m.set(t.status, []); m.get(t.status)!.push(t) }
  // Array sort is stable: cards ranked alike keep the board's order.
  for (const [s, ts] of m) {
    const keys = new Map(ts.map(t => [t.ref, sortKey(t)]))
    m.set(s, ts.sort((a, b) => compareKeys(keys.get(a.ref)!, keys.get(b.ref)!)))
  }
  return m
})
const column = (s: string) => columns.value.get(s) ?? []

// Changes go through the API, then the board is read again.
// A task is done only with everything under it: marking it done first shows what is under it,
// with what each is now, and asks to mark those not done done with it.
type Node = { t: Task; below: Node[] }
const below = (r: string): Node[] => (children.value.get(r) ?? []).map(t => ({ t, below: below(t.ref) }))
const anyOpen = (ns: Node[]): boolean => ns.some(n => n.t.status !== 'done' || anyOpen(n.below))
const flat = (ns: Node[], d = 0): { t: Task; d: number }[] => ns.flatMap(n => [{ t: n.t, d }, ...flat(n.below, d + 1)])
const doneAsk = ref<{ ref: string; fields: Record<string, any>; tree: Node[] } | null>(null)
// The control shows the task's status until the change is made, which may first be asked about.
function pickStatus(e: Event) {
  const el = e.target as HTMLSelectElement, to = el.value
  if (!open.value) return
  el.value = open.value.status
  change(open.value.ref, { status: to })
}
// Sending work back from review: what is needed, and subtasks to add, back to the agent that did it.
const sendingBack = ref<string | null>(null)
const sendBackText = ref(''), sendBackSubtasks = ref('')
function startSendBack(r: string) { sendingBack.value = r; sendBackText.value = ''; sendBackSubtasks.value = '' }
async function sendBack() {
  const r = sendingBack.value
  if (!r || !sendBackText.value.trim()) return
  const subtasks = sendBackSubtasks.value.split('\n').map(x => x.trim()).filter(Boolean)
  await sendOnce('send-back', async () => {
    try {
      const t = await post(`/api/tasks/${r}/send-back`, JSON.stringify({ request: sendBackText.value, subtasks }))
      sendingBack.value = null
      if (open.value?.ref === r) open.value = t
      await loadBoard(); loadWaiting()
    } catch (e: any) { error.value = e.message }
  })
}
function confirmDone() {
  const a = doneAsk.value
  doneAsk.value = null
  if (a) change(a.ref, { ...a.fields, with_subtasks: true })
}
// The questions on a task still waiting on someone: not answered nor resolved.
const openQuestions = (t: Full) => t.activity.filter(e => e.kind === 'question' && (e.state === 'open' || e.state === 'asked back'))
// Marking a task done asks first about its open questions (`asked` once that is settled).
const questionsAsk = ref<{ ref: string; fields: Record<string, any>; questions: TaskEvent[] } | null>(null)
async function settleQuestions(resolveThem: boolean) {
  const a = questionsAsk.value
  questionsAsk.value = null
  if (!a) return
  if (resolveThem) await resolve(a.ref)
  change(a.ref, a.fields, true)
}
async function change(ref_: string, fields: Record<string, any>, asked = false) {
  error.value = ''
  if (fields.status === 'done' && !asked && !fields.with_subtasks) {
    try {
      const t: Full = open.value?.ref === ref_ ? open.value : await getJSON(`/api/tasks/${ref_}`)
      const questions = openQuestions(t)
      if (questions.length) { questionsAsk.value = { ref: ref_, fields, questions }; return }
    } catch { /* asked about on the server's terms instead */ }
  }
  if (fields.status === 'done' && !fields.with_subtasks) {
    const tree = below(ref_)
    if (anyOpen(tree)) { doneAsk.value = { ref: ref_, fields, tree }; return }
  }
  await sendOnce(`task:${ref_}`, async () => {
    if (fields.status) showMoving(ref_, fields.status)
    try { const t = await post(`/api/tasks/${ref_}`, JSON.stringify(fields)); if (open.value?.ref === ref_) open.value = t; await loadBoard() }
    catch (e: any) { error.value = e.message }
    finally { showMoving(ref_) }
  })
}
// Opening a task: of several clicked in turn, the last one opens, and closing it drops what was on its way.
const opening = latest()
watch(open, t => { if (!t) opening.cancel() })
async function openRef(r: string) {
  try {
    const t: Full = await opening(signal => getJSON(`/api/tasks/${r}`, { signal }))
    if (t.project !== key.value) { key.value = t.project; await loadBoard() }
    open.value = t; editingBody.value = false
  } catch (e: any) { if (!isStale(e)) error.value = e.message }
}
const show = (t: { ref: string }) => openRef(t.ref)

// Dragging a card onto a column moves it there (a subtask dropped there leaves its task, for the top
// level); onto the top of another card, just above that card, beside it; onto the rest of a card,
// into that task, as a subtask.
const dragging = ref('')
const over = ref('')
const target = ref<{ ref: string; zone: 'before' | 'into' } | null>(null)
// Only what is done, at every level, goes into a done task: anything else is placed before it.
const allDone = (r: string): boolean => {
  const t = board.value?.tasks.find(x => x.ref === r)
  return !!t && t.status === 'done' && below(r).every(n => allDone(n.t.ref))
}
function aim(e: DragEvent, t: Task) {
  const box = (e.currentTarget as HTMLElement).getBoundingClientRect()
  const zone = e.clientY - box.top >= box.height * 0.3 && (t.status !== 'done' || allDone(dragging.value)) ? 'into' : 'before'
  // Sorted otherwise than by hand, a card has no place before another: dropped there, it goes to the column.
  if (sorted.value && zone === 'before') { if (target.value) target.value = null; return }
  // Dragging over a card fires many times a second: the board is drawn again only when the aim changes.
  if (target.value?.ref !== t.ref || target.value.zone !== zone) target.value = { ref: t.ref, zone }
}
// The drop areas show once the drag has begun: a browser drops a drag whose card something covers
// as it starts, and the areas lie over the top of each column.
const strips = ref(false)
function startDrag(r: string) {
  dragging.value = r
  setTimeout(() => { strips.value = dragging.value === r })
}
function dragEnded() {
  dragging.value = ''; target.value = null; topOf.value = ''; strips.value = false
  if (pending) { pending = false; applyUpdate() }
}
// The card dropped, and the drag ended: live updates held back meanwhile are applied.
function dropped(): Task | undefined {
  const r = dragging.value
  dragging.value = ''; over.value = ''; target.value = null; topOf.value = ''; strips.value = false
  if (pending) { pending = false; setTimeout(applyUpdate) }
  return board.value?.tasks.find(x => x.ref === r) ?? open.value?.subtasks_list.find(x => x.ref === r)
}
function drop(status: string, onto?: Task) {
  const zone = target.value?.zone
  if (sorted.value && zone !== 'into') onto = undefined
  const t = dropped()
  if (!t || t.ref === onto?.ref) return
  const fields: Record<string, any> = {}
  if (onto && zone === 'into') fields.parent = onto.ref
  else {
    if (t.status !== status) fields.status = status
    if (onto) { fields.before = onto.ref; if (t.parent !== onto.parent) fields.parent = onto.parent }
    else if (t.parent) fields.parent = ''
  }
  if (Object.keys(fields).length) change(t.ref, fields)
}
// The top of each column, while a card is dragged: dropped there, the card goes to that column, at
// its top and at the top level, however full of cards it is.
const topOf = ref('')
const draggedStatus = computed(() => board.value?.tasks.find(x => x.ref === dragging.value)?.status ?? '')
const draggedParent = computed(() => board.value?.tasks.find(x => x.ref === dragging.value)?.parent ?? '')
// Sorted otherwise than by hand, a column's top is only for moving a card there, or a subtask out of its task.
const topStrip = (s: string) => !sorted.value || draggedStatus.value !== s || !!draggedParent.value
function dropTop(status: string) {
  const t = dropped()
  if (!t) return
  const fields: Record<string, any> = {}
  if (t.status !== status) fields.status = status
  if (t.parent) fields.parent = ''
  const first = column(status).find(x => !x.parent && x.ref !== t.ref)
  if (first && !sorted.value) fields.before = first.ref
  if (Object.keys(fields).length) change(t.ref, fields)
}
// A milestone's chip, while a card is dragged: dropped there, the task goes into that milestone, or
// out of any onto "No milestone". Its column and place stay.
const msAimed = ref<string | null>(null)
const draggedMilestone = computed(() => board.value?.tasks.find(x => x.ref === dragging.value)?.milestone ?? '')
function aimMilestone(e: DragEvent, name: string) {
  if (!dragging.value || !editable.value) return                  // a file, or nothing of the board's
  e.preventDefault()
  msAimed.value = name
}
function dropMilestone(name: string) {
  msAimed.value = null
  const t = dropped()
  if (t && t.milestone !== name) change(t.ref, { milestone: name })
}

const newTitle = ref('')
async function addTask() {
  if (!newTitle.value.trim()) return
  await sendOnce('task', async () => {
    try { await post('/api/tasks', JSON.stringify({ project: key.value, title: newTitle.value, milestone: milestone.value }))
          newTitle.value = ''; await loadBoard() } catch (e: any) { error.value = e.message }
  })
}
const newProject = ref<{ name: string; key: string; codebase: string } | null>(null)
async function addProject() {
  await sendOnce('project', async () => {
    try { const r = await post('/api/projects', JSON.stringify(newProject.value)); newProject.value = null; await loadList(); key.value = r.key }
    catch (e: any) { error.value = e.message }
  })
}
const newMilestone = ref<{ name: string; due: string } | null>(null)
async function addMilestone() {
  await sendOnce('milestone', async () => {
    try { await post(`/api/projects/${key.value}/milestones`, JSON.stringify(newMilestone.value)); newMilestone.value = null; await loadBoard() }
    catch (e: any) { error.value = e.message }
  })
}
// Changing a milestone: its name, dates and description. A cleared date is sent as none.
const editMilestone = ref<{ was: string; name: string; start: string; due: string; description: string } | null>(null)
async function saveMilestone() {
  const e = editMilestone.value
  if (!e) return
  await sendOnce('milestone-edit', async () => {
    try {
      const r = await post(`/api/projects/${key.value}/milestone-update`, JSON.stringify(
        { name: e.was, rename: e.name, start: e.start, due: e.due, description: e.description }))
      if (milestone.value === e.was) milestone.value = r.milestone.name
      editMilestone.value = null; await loadBoard()
    } catch (x: any) { error.value = x.message }
  })
}

// The task's panel.
const editingBody = ref(false)
const draftBody = ref('')
const comment = ref('')
// Presence starts once the service says who is here, and reports each move (see `report` above).
watch(shared, on => {
  if (!on || presenceOn) return
  hidden.value = localStorage.getItem(HIDDEN) === '1'
  presenceOn = true; followPresence(); report(); beat = setInterval(report, 20_000)
}, { immediate: true })
onBeforeUnmount(() => { presenceOn = false; clearInterval(beat) })
watch(() => [key.value, open.value?.ref, hidden.value, planning.value, followee.value], () => { report() })
watch(() => [milestone.value, !!declined.value, reviewing.value, library.value], () => reportSoon())
watch(comment, () => { if (planning.value) { clearTimeout(typing); typing = setTimeout(report, 300) } })
const link = ref({ kind: 'paper', target: '' })
// A subtask of the open task. One given to an agent is ready for it: a person setting it approves it.
const newSubtask = ref({ title: '', assignee: 'agent:Claude' })
async function addSubtask() {
  if (!open.value || !newSubtask.value.title.trim()) return
  const agent = newSubtask.value.assignee.startsWith('agent:'), parent = open.value.ref
  await sendOnce('subtask', async () => {
    try {
      await post('/api/tasks', JSON.stringify({ project: key.value, parent, title: newSubtask.value.title,
                                                assignee: newSubtask.value.assignee.trim(), status: agent ? 'ready' : 'backlog' }))
      newSubtask.value.title = ''; await refresh()
    } catch (e: any) { error.value = e.message }
  })
}
// Deleting a task takes its subtasks with it, so the question says how many.
async function removeTask() {
  const t = open.value
  if (!t) return
  const n = t.subtasks
  if (!confirm(`Delete ${t.ref}${n ? ` and its ${n} subtask${n > 1 ? 's' : ''}` : ''}? This can't be undone.`)) return
  try { await post(`/api/tasks/${t.ref}/delete`, '{}'); open.value = null; await refresh() } catch (e: any) { error.value = e.message }
}
async function saveBody() { if (open.value) { await change(open.value.ref, { body: draftBody.value }); editingBody.value = false } }
// Questions: each asked of the agents, a person or anyone on the project, waiting on them until a
// reply answers it. A comment is a reply when it answers the question being replied to, or the one
// waiting on you (unless unticked); a question asked while replying asks back, of whoever asked.
const myPersonId = computed(() => me.value?.id ?? '')
const waitsOnMe = (e: TaskEvent) => e.kind === 'question' && e.state === 'open' &&
  (e.to_whom === 'person' ? e.to_person === myPersonId.value : e.to_whom === 'anyone' && e.by_person !== myPersonId.value)
const questionTag = (e: TaskEvent) =>
  e.state === 'resolved' ? 'resolved' : e.state === 'answered' ? 'answered' : e.state === 'asked back' ? 'asked back' :
  waitsOnMe(e) ? 'for you' : e.to_whom === 'agents' ? 'for the agents' : e.to_whom === 'anyone' ? 'for anyone' : `for ${e.to_label}`
// The activity with each reply under its question, indented by how deep it is.
const threaded = computed(() => {
  const a = open.value?.activity ?? []
  const ids = new Set(a.map(e => e.id))
  const replies = new Map<number, TaskEvent[]>()
  for (const e of a) if (e.reply_to && ids.has(e.reply_to)) replies.set(e.reply_to, [...(replies.get(e.reply_to) ?? []), e])
  const out: { e: TaskEvent; depth: number }[] = []
  const add = (e: TaskEvent, depth: number) => { out.push({ e, depth }); for (const r of replies.get(e.id) ?? []) add(r, Math.min(depth + 1, 3)) }
  for (const e of a) if (!(e.reply_to && ids.has(e.reply_to))) add(e, 0)
  return out
})
const replyTo = ref<TaskEvent | null>(null)
const answersIt = ref(true)
function startReply(e: TaskEvent) {
  replyTo.value = e
  nextTick(() => document.querySelector<HTMLElement>('[data-control="comment"] .cm-content')?.focus())
}
watch(() => open.value?.ref, () => { replyTo.value = null; answersIt.value = true })
// The latest question on the task waiting on you, which a comment answers unless unticked.
const waitingMine = computed(() => [...(open.value?.activity ?? [])].reverse().find(waitsOnMe) ?? null)
// Whom a question can be asked of: the task's assignee first (a person, not the one asking), the
// agents, the project's other people, and anyone on it.
const askOptions = computed(() => {
  const t = open.value, mine = myPersonId.value
  const assignee = t?.assignee && !t.assignee.startsWith('agent:') && t.assignee !== mine ? t.assignee : ''
  const others = projectPeople.value.filter(p => !p.agent && p.id !== mine && p.id !== assignee)
  return [...(assignee ? [{ value: assignee, label: `${personLabel(assignee)} (assignee)` }] : []),
          { value: 'agents', label: 'the agents' },
          ...others.map(p => ({ value: p.id, label: p.label })),
          ...(others.length + (assignee ? 1 : 0) > 1 ? [{ value: 'anyone', label: `anyone on ${key.value}` }] : [])]
})
const askTo = ref('agents')
watch(askOptions, o => { if (!o.some(x => x.value === askTo.value)) askTo.value = o[0]?.value ?? 'agents' }, { immediate: true })
watch(() => open.value?.ref, () => { askTo.value = askOptions.value[0]?.value ?? 'agents' })
async function addComment(kind: 'comment' | 'question' = 'comment') {
  const r = open.value?.ref
  if (!r || !comment.value.trim()) return
  const body: Record<string, any> = { text: comment.value, kind }
  const reply = replyTo.value ?? (kind === 'comment' && answersIt.value ? waitingMine.value : null)
  if (reply) body.reply_to = reply.id
  if (kind === 'question' && !replyTo.value) body.to = askTo.value
  await sendOnce('comment', async () => {
    try {
      open.value = await post(`/api/tasks/${r}/notes`, JSON.stringify(body))
      comment.value = ''; replyTo.value = null; answersIt.value = true
      loadWaiting()
    } catch (e: any) { error.value = e.message }
  })
}
async function addLink(remove = false, l = link.value) {
  const r = open.value?.ref
  if (!r || !l.target.trim()) return
  await sendOnce(`link:${remove ? l.kind + l.target : ''}`, async () => {
    try { open.value = await post(`/api/tasks/${r}/links`, JSON.stringify({ ...l, remove })); if (!remove) link.value.target = '' }
    catch (e: any) { error.value = e.message }
  })
}
function setBlocked() {
  if (!open.value) return
  const why = prompt('Blocked by what?', open.value.blocked)
  if (why !== null) change(open.value.ref, { blocked: why })
}

// Text rendered as Markdown with mathematics, code and @references (see kbMarkdown.ts); as plain text
// until the renderer has loaded.
const markdown = shallowRef<Render>(escapeText)
const render = (s: string) => markdown.value(s, { refs: true })
onMounted(async () => { markdown.value = await loadMarkdown() })
// A search result opens its task, at the comment that matched.
const flashEvent = ref(0)
async function openFromSearch(r: string, event: number) {
  await openRef(r)
  if (!event) return
  await nextTick()
  document.querySelector(`[data-event="${event}"]`)?.scrollIntoView({ block: 'center', behavior: 'smooth' })
  flashEvent.value = event
  setTimeout(() => { if (flashEvent.value === event) flashEvent.value = 0 }, 6200)
}
// A task referred to in a plan or comment opens in the panel.
const followRef = onTaskRef(r => show({ ref: r }))

const label = (s: string) => statuses.value.find(x => x.id === s)?.label ?? s
// Editing a note in place: people edit their own and agents' notes (see edit_note!). An edited note
// shows its earlier texts on request.
const NOTE_KINDS = ['comment', 'progress', 'question']
// A person edits their own notes and those of agents working for them; a maintainer, any agent's.
const canEditNote = (e: TaskEvent) => editable.value && NOTE_KINDS.includes(e.kind) &&
  (e.by_agent ? e.by_person === myPersonId.value || board.value?.access === 'maintainer' : e.who === me.value?.name)
const editingNote = ref<{ id: number; text: string } | null>(null)
const noteHistory = ref<{ id: number; rows: { at: string; who: string; by_agent: boolean; text: string }[] } | null>(null)
async function saveNote() {
  const n = editingNote.value
  if (!n || !open.value) return
  try {
    open.value = await post(`/api/tasks/${open.value.ref}/notes/${n.id}`, JSON.stringify({ text: n.text }))
    editingNote.value = null
    if (noteHistory.value?.id === n.id) showNoteHistory(n.id, true)
  } catch (e: any) { error.value = e.message }
}
async function showNoteHistory(id: number, again = false) {
  if (noteHistory.value?.id === id && !again) { noteHistory.value = null; return }
  try { noteHistory.value = { id, rows: await getJSON(`/api/tasks/${open.value!.ref}/notes/${id}/history`) } } catch (e: any) { error.value = e.message }
}
// A field's new value in a task's history, as the board names it: a priority by its name (0 is ASAP),
// a person by theirs, and nothing as a dash.
const fieldValue = (field: string, v: any) =>
  field === 'priority' ? PRIORITIES[v as number] ?? String(v) : field === 'assignee' ? (v ? personLabel(v) : '—') : v === '' || v == null ? '—' : String(v)
function eventText(e: TaskEvent) {
  switch (e.kind) {
    case 'status': return `moved it from ${label(e.detail.from)} to ${label(e.detail.to)}`
    case 'edit': return e.detail.field === 'parent' ? (e.detail.to ? `put it under ${e.detail.to}` : 'made it a task of its own') :
      `changed the ${e.detail.field}` + (e.detail.to !== undefined && e.detail.field !== 'body' ? ` to ${fieldValue(e.detail.field, e.detail.to)}` : '')
    case 'blocked': return `marked it blocked: ${e.text}`
    case 'unblocked': return 'unblocked it'
    case 'link': return e.detail.kind === 'blocks' ? `marked it as blocking ${e.text}` : `linked ${e.detail.kind} ${e.text}`
    case 'unlink': return e.detail.kind === 'blocks' ? `no longer blocking ${e.text}` : `unlinked ${e.detail.kind} ${e.text}`
    case 'deleted': return `deleted subtask ${e.text}` + (e.detail.subtasks ? ` and ${e.detail.subtasks} under it` : '')
    case 'archived': return 'archived it'
    case 'unarchived': return 'brought it back from the archive'
    case 'created': return 'created it'
    case 'comment': case 'progress': case 'question': return ''
    default: return e.kind
  }
}
const msProgress = (m: Milestone) => m.total ? Math.round(100 * m.done / m.total) : 0

// Whether a board's records are shown, as this browser last left them: closed until opened.
const RECORDS_OPEN = 'zemi-board-records-open'
const recordsOpen = ref(false)
onMounted(() => { recordsOpen.value = localStorage.getItem(RECORDS_OPEN) === '1' })
function keepRecordsOpen(open: boolean) {
  recordsOpen.value = open
  open ? localStorage.setItem(RECORDS_OPEN, '1') : localStorage.removeItem(RECORDS_OPEN)
}
</script>

<template>
  <div ref="page" class="kbp" :style="{ paddingRight: `${room.right}px`, paddingBottom: `${room.bottom}px` }">
    <KBNeedsService permission="tasks.view">
      <div class="kbp-top">
        <div class="kbp-project">
          <select v-if="list.length" v-model="key" class="kbp-project-select" aria-label="Project">
            <option v-for="p in list" :key="p.key" :value="p.key">{{ p.key }} · {{ p.name }} ({{ p.open }} open)</option>
          </select>
          <span class="kbp-live" :class="{ on: live }" :title="live ? 'Following changes' : 'Reconnecting…'"
                :aria-label="live ? 'Following changes' : 'Reconnecting'"></span>
        </div>
        <nav v-if="board" class="kbp-views" aria-label="The project's views">
          <button class="kbp-view" :class="{ on: focus }" :aria-pressed="focus" title="Only what waits on you in the project" @click="toggleFocus">
            <KBIcon name="focus" :size="16" />Focus</button>
          <button class="kbp-view" @click="reviewing = true"><KBIcon name="chart" :size="16" />Review</button>
          <a class="kbp-view" :href="findingHref(key)"><KBIcon name="finding" :size="16" />Findings<span v-if="board.findings" class="kbp-view-n">{{ board.findings }}</span></a>
          <button class="kbp-view" @click="library = true"><KBIcon name="library" :size="16" />Library</button>
          <button v-if="!focus" class="kbp-view" :class="{ on: declined }" :aria-pressed="!!declined" @click="toggleDeclined"><KBIcon name="block" :size="16" />Declined</button>
        </nav>
        <span class="kbp-spacer"></span>
        <div v-if="(shared && board) || peopleDid.length" class="kbp-pop">
          <button class="kbp-people-button" :class="{ on: menu === 'people', planning }" :aria-expanded="menu === 'people'"
                  :title="others.length ? others.map(hereTitle).join('\n') : 'People'" @click="toggleMenu('people')">
            <span v-for="p in others.slice(0, 4)" :key="p.id" class="kbp-face" :class="{ planning: p.planning }">{{ initials(p.name) }}</span>
            <span v-if="others.length > 4" class="kbp-face">+{{ others.length - 4 }}</span>
            <span v-if="!others.length" class="kbp-people-label">People</span></button>
          <div v-if="menu === 'people'" class="kbp-menu kbp-agents-menu" role="menu">
            <template v-if="shared">
              <div class="kbp-menu-label">You are</div>
              <div class="kbp-levels" role="radiogroup" aria-label="What others see of you">
                <button v-for="l in PRESENCE_LEVELS" :key="l.id" class="kbp-level" role="radio" :aria-checked="presenceMode() === l.id"
                        :class="{ on: presenceMode() === l.id }" :title="l.help" @click="setPresence(l.id)">{{ l.label }}</button>
              </div>
              <div class="kbp-menu-item kbp-menu-wait">{{ PRESENCE_LEVELS.find(l => l.id === presenceMode())!.help }}</div>
            </template>
            <template v-if="others.length">
              <div class="kbp-menu-label">Here now</div>
              <div v-for="p in others" :key="p.id" class="kbp-menu-item kbp-person">
                <span class="kbp-face" :class="{ planning: p.planning }">{{ initials(p.name) }}</span><span class="kbp-menu-title">{{ p.name }}</span>
                <span class="kbp-menu-dim">{{ p.planning ? (p.open ? `planning · ${p.open}` : 'planning') : 'here' }}</span>
                <button v-if="p.planning" class="kbp-small" @click="followee = followee === p.id ? 0 : p.id; menu = ''">
                  {{ followee === p.id ? 'Stop' : 'Follow' }}</button>
              </div>
            </template>
            <div v-if="followers.length" class="kbp-menu-item kbp-menu-wait">Following you: {{ followers.map(p => p.name).join(', ') }}</div>
            <div class="kbp-menu-label">Lately</div>
            <button v-for="(e, i) in peopleDid" :key="i" class="kbp-menu-item" role="menuitem" @click="menu = ''; show({ ref: e.ref })">
              <span class="kbp-menu-title"><b>{{ e.who }}</b> {{ actionText(e) }}</span><span class="kbp-menu-dim">{{ since(e.at) }}</span></button>
            <div v-if="!peopleDid.length" class="kbp-menu-item kbp-menu-wait">Nothing from others in the last week</div>
          </div>
        </div>
        <div v-if="workedDirectly.length || board?.agents?.waiting.length" class="kbp-pop">
          <button class="kbp-agents-button" :class="{ on: menu === 'agents' }" :aria-expanded="menu === 'agents'" @click="toggleMenu('agents')">
            <span v-if="workedDirectly.length" class="kbp-working"></span>{{ agentsSummary }}</button>
          <div v-if="menu === 'agents'" class="kbp-menu kbp-agents-menu" role="menu">
            <div class="kbp-menu-label">At work, the last half hour</div>
            <button v-for="a in workedDirectly" :key="a.ref" class="kbp-menu-item" role="menuitem" :title="workTitle(a.ref)"
                    @click="menu = ''; show({ ref: a.ref })">
              <span class="kbp-working"></span><span class="kbp-menu-ref">{{ a.ref }}</span>
              <span class="kbp-menu-title">{{ taskTitle(a.ref) }}</span><span class="kbp-menu-dim">{{ agentName(a.agent) }} · {{ ago(a.at) }}</span></button>
            <div v-for="w in board?.agents?.waiting ?? []" :key="w.agent" class="kbp-menu-item kbp-menu-wait">
              {{ agentName(w.agent) }} waiting for work · since {{ when(w.since) }}</div>
          </div>
        </div>
        <div v-if="(manages && board) || can('projects.create') || board?.manages_members" class="kbp-pop">
          <button class="kbp-icon" :class="{ on: menu === 'more' }" title="More" aria-label="More" :aria-expanded="menu === 'more'"
                  @click="toggleMenu('more')">⋯</button>
          <div v-if="menu === 'more'" class="kbp-menu kbp-more-menu" role="menu">
            <button v-if="manages && board" class="kbp-menu-item" role="menuitem" @click="menu = ''; newMilestone = { name: '', due: '' }">
              <KBIcon name="plus" :size="15" />New milestone</button>
            <button v-if="can('projects.create')" class="kbp-menu-item" role="menuitem" @click="menu = ''; newProject = { name: '', key: '', codebase: '' }">
              <KBIcon name="plus" :size="15" />New project</button>
            <button v-if="board?.manages_members" class="kbp-menu-item kbp-menu-danger" role="menuitem" @click="menu = ''; deleteProject()">
              <KBIcon name="trash" :size="15" />Delete {{ key }}…</button>
          </div>
        </div>
      </div>
      <!-- At the end of the document, outside the page's wrappers, so these stay fixed to the window. -->
      <Teleport to="body">
        <div v-if="inSession" class="kbp-session" :class="{ lit: pen }" role="toolbar" aria-label="Planning session"
             :title="leader && followee ? `Following ${leader.name}` : `Planning${followers.length ? `, ${followers.length} following` : ''}`">
          <span v-if="leader && followee" class="kbp-face planning">{{ initials(leader.name) }}</span>
          <span v-else class="kbp-session-what">{{ followers.length ? `${followers.length} following` : 'Planning' }}</span>
          <button class="kbp-pen" :class="{ on: pen }" :aria-pressed="pen" aria-label="Pen" title="Pen (P): point to show the others, drag to draw · Esc to stop"
                  @click="pen = !pen"><KBIcon name="edit" :size="13" /></button>
          <button v-if="leader && followee" class="kbp-session-stop" title="Stop following" aria-label="Stop following" @click="followee = 0">×</button>
        </div>
        <div v-if="pen" class="kbp-ink-catch" @pointermove="inkMove" @pointerdown.prevent="inkDown" @pointerup="inkUp" @pointerleave="inkUp" @wheel="inkWheel"></div>
        <canvas v-show="inSession" ref="inkCanvas" class="kbp-ink"></canvas>
      </Teleport>
      <form v-if="newProject" class="kbp-form" @submit.prevent="addProject">
        <input v-model="newProject.name" placeholder="Name" required />
        <input v-model="newProject.key" placeholder="Key (KB)" required class="kbp-short" />
        <input v-model="newProject.codebase" placeholder="Codebase id (optional)" />
        <button class="kb-primary kbp-button" :disabled="busy('project')"><span v-if="busy('project')" class="kbp-spin"></span>Create</button> <button type="button" class="kb-primary kbp-button kbp-secondary" @click="newProject = null">Cancel</button>
      </form>
      <form v-if="newMilestone" class="kbp-form" @submit.prevent="addMilestone">
        <input v-model="newMilestone.name" placeholder="Milestone" required />
        <input v-model="newMilestone.due" type="date" />
        <button class="kb-primary kbp-button" :disabled="busy('milestone')"><span v-if="busy('milestone')" class="kbp-spin"></span>Add</button> <button type="button" class="kb-primary kbp-button kbp-secondary" @click="newMilestone = null">Cancel</button>
      </form>
      <p v-if="error" class="kb-error kbp-error">{{ error }}</p>

      <div v-if="board && !focus && (board.project.description || manages || shared)" class="kbp-context" :class="{ empty: !board.project.description && !editingContext }">
        <template v-if="editingContext">
          <KBRefText :project="key" v-model="contextDraft" multiline :rows="6" :draft="`project:${key}:context`" send="save"
                     placeholder="Context for the project's work" @submit="saveContext" />
          <div class="kbp-context-actions">
            <button class="kb-primary kbp-button" @click="saveContext">Save</button>
            <button class="kb-primary kbp-button kbp-secondary" @click="editingContext = false">Cancel</button>
          </div>
        </template>
        <template v-else-if="board.project.description">
          <div class="kbp-context-head"><span class="kbp-waiting-label">About {{ board.project.key }}</span>
            <button v-if="manages" class="kbp-icon" title="Edit the project's context" aria-label="Edit the project's context"
                    @click="editContext"><KBIcon name="edit" :size="15" /></button>
            <button v-if="longContext" class="kb-link kbp-link kbp-context-toggle" @click="contextOpen = !contextOpen">{{ contextOpen ? 'less' : 'more' }}</button></div>
          <div class="kbp-note kbp-context-text kb-md" :class="{ clipped: longContext && !contextOpen }" v-html="render(board.project.description)"></div>
        </template>
        <button v-else-if="manages" class="kb-link kbp-link" @click="editContext">+ Context</button>
        <div class="kbp-codebase">
          <span class="kbp-waiting-label">Code</span>
          <template v-if="codeDraft === null">
            <template v-if="board.codebase">
              <a :href="board.codebase.page">{{ board.codebase.title }}</a>
              <code v-if="board.codebase.rev" class="kb-dim kbp-dim" :title="board.codebase.rev.endsWith('+') ? 'with changes not committed' : 'checked out'">{{ board.codebase.rev }}</code>
              <a v-if="board.codebase.remote" :href="board.codebase.remote" target="_blank" rel="noopener" class="kb-dim kbp-dim">{{ remoteName(board.codebase.remote) }}</a>
            </template>
            <span v-else class="kb-dim kbp-dim">No codebase linked</span>
            <button v-if="manages" class="kbp-icon" title="Link a codebase" aria-label="Link a codebase" @click="editCodebase"><KBIcon name="edit" :size="15" /></button>
          </template>
          <template v-else>
            <select v-model="codeDraft" class="kbp-select" aria-label="Codebase">
              <option value="none">None</option>
              <option v-for="c in codebases ?? []" :key="c.id" :value="c.id">{{ c.title }}</option>
            </select>
            <button class="kbp-small" @click="saveCodebase">Save</button>
            <button class="kbp-small" @click="codeDraft = null">Cancel</button>
          </template>
        </div>
        <details v-if="board.records?.length || addsRecords" class="kbp-records" :open="recordsOpen"
                 @toggle="keepRecordsOpen(($event.target as HTMLDetailsElement).open)">
          <summary class="kbp-records-head">
            <span class="kbp-waiting-label">Records</span>
            <span class="kb-dim kbp-dim">{{ board.records?.length ? `${board.records.length} · latest ${board.records[0].day}` : 'None yet' }}</span>
            <button v-if="addsRecords" class="kbp-icon" title="Add records" aria-label="Add records"
                    @click.prevent="addingRecords = !addingRecords; keepRecordsOpen(true)">
              <KBIcon name="plus" :size="15" /></button>
          </summary>
          <ul v-if="board.records?.length" class="kbp-records-list">
            <li v-for="r in board.records.slice(0, 5)" :key="r.id">
              <span class="kb-dim kbp-dim">{{ r.day }}</span><a :href="recordHref(r.id)">{{ r.title }}</a>
            </li>
          </ul>
          <a v-if="(board.records?.length ?? 0) > 5" class="kb-dim kbp-dim kbp-records-more"
             :href="`${kbPage('records')}?project=${encodeURIComponent(key)}`">{{ board.records.length - 5 }} more</a>
        </details>
        <KBRecordUpload v-if="addingRecords && addsRecords" :project="key" @uploaded="loadBoard" />
        <KBMembers v-if="shared" :project="key" :manages="!!board.manages_members" />
      </div>

      <div v-if="!focus && WAITING.some(w => shownWaiting[w.id].length)" class="kbp-waiting" :class="{ pulse }">
        <span class="kbp-waiting-label">Waiting on you</span>
        <button v-for="w in WAITING" :key="w.id" v-show="shownWaiting[w.id].length" class="kbp-ms" :class="[`w-${w.id}`, { on: waitingOpen === w.id, pulse: pulsing.has(w.id) }]"
                @click="waitingOpen = waitingOpen === w.id ? '' : w.id"><strong class="kbp-n">{{ shownWaiting[w.id].length }}</strong> {{ w.label }}</button>
        <ul v-if="waitingOpen" class="kbp-waiting-list">
          <li v-for="t in shownWaiting[waitingOpen as Section]" :key="`${t.ref}:${t.note ?? ''}`"
              :class="{ flash: freshRows.has(`${waitingOpen}:${t.ref}`) }">
            <template v-if="t.claim !== undefined"><a class="kbp-reflink" :href="findingHref(t.ref)">{{ t.ref }}</a>
              <span v-if="t.recheck?.length" class="kbp-tag" title="Its evidence changed">re-check</span> {{ t.claim }}
              <span class="kb-dim kbp-dim">{{ t.created_by }}</span></template>
            <template v-else><button class="kbp-reflink" @click="openWaiting(t)">{{ t.ref }}</button> {{ t.title }}
              <span class="kb-dim kbp-dim">{{ label(t.status) }}<template v-if="t.parent"> · in {{ t.parent }}</template></span></template>
            <button v-if="waitingOpen === 'review' && editable" class="kbp-small kbp-dismiss-wide" @click="startSendBack(t.ref)">Send back</button>
            <button v-if="waitingOpen === 'answered'" class="kbp-icon kbp-dismiss" title="Resolved: answered to your satisfaction"
                    aria-label="Mark resolved" :disabled="busy(`resolve:${t.ref}:${t.note}`)" @click="resolve(t.ref, t.note)">
              <KBIcon name="check" :size="15" /></button>
            <button v-if="waitingOpen === 'questions' && editable" class="kbp-icon kbp-dismiss" title="Resolved: settled some other way, or no longer needs an answer"
                    aria-label="Mark resolved" :disabled="busy(`resolve:${t.ref}:${t.note}`)" @click="resolve(t.ref, t.note)">
              <KBIcon name="check" :size="15" /></button>
            <div v-if="t.question" class="kbp-question-line"><b v-if="t.asker && waitingOpen === 'questions'">{{ t.asker }}:</b> {{ t.question }}</div>
            <div v-if="t.answer" class="kbp-question-line kbp-answer-line"><b v-if="t.answerer">{{ t.answerer }}:</b> {{ plainLine(t.answer) }}</div>
          </li>
        </ul>
      </div>

      <div v-if="!focus && openMilestones.length" class="kbp-milestones">
        <button v-for="m in openMilestones" :key="m.name" class="kbp-ms" :class="{ on: milestone === m.name, closed: m.closed, active: m.active, aimed: msAimed === m.name }"
                :title="(milestone === m.name ? 'Showing only this milestone; click to show all' : 'Show only this milestone, and work in it') +
                        (m.active ? ' · active: new tasks go here' : '')"
                @click="pickMilestone(m)" @dragover="aimMilestone($event, m.name)" @dragleave="msAimed = null" @drop.prevent="dropMilestone(m.name)">
          <span v-if="m.active" class="kbp-active-dot"></span><span>{{ m.name }}</span><span class="kb-dim kbp-dim" v-if="m.due"> · {{ m.start ? m.start + ' – ' : '' }}{{ m.due }}</span>
          <span class="kbp-meter"><span :style="{ width: msProgress(m) + '%' }"></span></span>
          <span class="kb-dim kbp-dim">{{ m.done }}/{{ m.total }}</span>
        </button>
        <span v-if="strips && editable && draggedMilestone" class="kbp-ms kbp-ms-none" :class="{ aimed: msAimed === '' }"
              @dragover="aimMilestone($event, '')" @dragleave="msAimed = null" @drop.prevent="dropMilestone('')">No milestone</span>
        <button v-if="manages && chosenMs" class="kbp-small"
                @click="editMilestone = { was: chosenMs.name, name: chosenMs.name, start: chosenMs.start, due: chosenMs.due, description: chosenMs.description }">
          <KBIcon name="edit" :size="15" />Edit</button>
        <button v-if="manages && chosenMs" class="kbp-small" @click="finishMilestone(chosenMs)">
          <KBIcon :name="chosenMs.closed ? 'unarchive' : 'check'" :size="15" />{{ chosenMs.closed ? 'Reopen' : 'Mark done' }}</button>
      </div>
      <form v-if="editMilestone" class="kbp-form kbp-ms-edit" @submit.prevent="saveMilestone">
        <input v-model="editMilestone.name" aria-label="Milestone name" required />
        <label>Starts <input v-model="editMilestone.start" type="date" /></label>
        <label>Due <input v-model="editMilestone.due" type="date" /></label>
        <input v-model="editMilestone.description" aria-label="Description" placeholder="Description" />
        <button class="kb-primary kbp-button" :disabled="busy('milestone-edit')"><span v-if="busy('milestone-edit')" class="kbp-spin"></span>Save</button>
        <button type="button" class="kb-primary kbp-button kbp-secondary" @click="editMilestone = null">Cancel</button>
      </form>

      <KBProjectReview v-if="reviewing" :project="key" :editable="manages" @close="reviewing = false"
                       @open="r => { reviewing = false; openRef(r) }" @changed="loadBoard" @library="reviewing = false; library = true" />
      <KBLibrary v-if="library" :project="key" :editable="editable" @close="library = false"
                 @open="r => { library = false; openRef(r) }" />

      <div v-if="declined && !focus" class="kbp-archive">
        <h3>Declined <span class="kb-dim kbp-dim">{{ declined.length }}</span></h3>
        <p v-if="!declined.length" class="kb-dim kbp-dim">Nothing declined.</p>
        <ul class="kbp-waiting-list">
          <li v-for="t in declined" :key="t.ref"><button class="kbp-reflink" @click="show(t)">{{ t.ref }}</button> {{ t.title }}
            <span class="kb-dim kbp-dim">declined {{ when(t.declined_at) }}</span>
            <button v-if="editable" class="kbp-small kbp-dismiss-wide" :disabled="busy(`task:${t.ref}`)" @click="decline(t.ref, true)">Bring back</button>
            <div v-if="t.reason" class="kbp-question-line">{{ t.reason }}</div></li>
        </ul>
      </div>

      <section v-if="board && focus" class="kbp-focus" aria-label="What waits on you in the project">
        <div v-if="board.project.description" class="kbp-focus-about">
          <div class="kbp-context-head"><span class="kbp-waiting-label">About {{ board.project.key }}</span>
            <button v-if="longContext" class="kb-link kbp-link kbp-context-toggle" @click="contextOpen = !contextOpen">{{ contextOpen ? 'less' : 'more' }}</button></div>
          <div class="kbp-note kbp-context-text kb-md" :class="{ clipped: longContext && !contextOpen }" v-html="render(board.project.description)"></div>
        </div>
        <p v-if="focusEmpty" class="kbp-focus-none">Nothing waits on you in {{ key }}.</p>
        <template v-if="focused.questions.length">
          <h3 class="kbp-focus-head asking">For you to answer</h3>
          <ul class="kbp-focus-list">
            <li v-for="t in focused.questions" :key="`q${t.note}`">
              <div class="kbp-focus-task"><button class="kbp-reflink" @click="show(t)">{{ t.ref }}</button> {{ t.title }}</div>
              <div class="kbp-question-line"><b v-if="t.asker">{{ t.asker }}:</b> {{ t.question }}</div>
              <button v-if="editable" class="kbp-small" @click="openWaiting(t, 'questions')">Answer</button>
            </li>
          </ul>
        </template>
        <template v-if="focused.answered.length">
          <h3 class="kbp-focus-head answered">Answers to your questions</h3>
          <ul class="kbp-focus-list">
            <li v-for="t in focused.answered" :key="`a${t.note}`">
              <div class="kbp-focus-task"><button class="kbp-reflink" @click="show(t)">{{ t.ref }}</button> {{ t.title }}</div>
              <div class="kbp-question-line">{{ t.question }}</div>
              <div class="kbp-question-line kbp-answer-line"><b v-if="t.answerer">{{ t.answerer }}:</b> {{ plainLine(t.answer ?? '') }}</div>
              <button class="kbp-small" :disabled="busy(`resolve:${t.ref}:${t.note}`)" title="Answered to your satisfaction"
                      @click="resolve(t.ref, t.note)"><KBIcon name="check" :size="15" />Resolved</button>
            </li>
          </ul>
        </template>
        <template v-if="focused.tasks.length">
          <h3 class="kbp-focus-head mine">Your tasks</h3>
          <div v-for="g in focused.tasks" :key="g.id" class="kbp-focus-group">
            <div class="kbp-waiting-label">{{ label(g.id) }}</div>
            <ul class="kbp-focus-list">
              <li v-for="t in g.tasks" :key="t.ref" class="kbp-focus-card" @click="show(t)">
                <div class="kbp-focus-task"><span class="kbp-ref">{{ t.ref }}</span>
                  <span v-if="t.priority === 0" class="kbp-tag asap">ASAP</span><span v-else-if="t.priority === 1" class="kbp-tag high">high</span>
                  <span v-if="t.blocked" class="kbp-tag blocked" :title="t.blocked">blocked</span>
                  <span v-if="t.sent_back" class="kbp-tag sent">sent back</span>
                  <span v-if="askingMe.has(t.ref)" class="kbp-tag asking" title="A question here waits on your answer">your answer</span> {{ t.title }}</div>
                <div class="kbp-meta"><span v-if="t.milestone">{{ t.milestone }}</span>
                  <span v-if="t.subtasks">{{ t.subtasks_done }}/{{ t.subtasks }} subtasks</span><span v-if="t.parent">in {{ t.parent }}</span></div>
              </li>
            </ul>
          </div>
        </template>
        <template v-if="focused.approve.length || focused.review.length">
          <h3 class="kbp-focus-head">Waiting on your decision</h3>
          <ul class="kbp-focus-list">
            <li v-for="t in [...focused.approve, ...focused.review]" :key="`d${t.ref}`" class="kbp-focus-card" @click="show(t)">
              <div class="kbp-focus-task"><span class="kbp-ref">{{ t.ref }}</span> {{ t.title }}</div>
              <div class="kbp-meta"><span>{{ t.status === 'proposed' ? 'to approve' : 'to review' }}</span>
                <span>by {{ t.created_by }}{{ t.by_agent ? ' (agent)' : '' }}</span></div>
            </li>
          </ul>
        </template>
        <template v-if="focused.asked.length">
          <h3 class="kbp-focus-head">Your questions, waiting for an answer</h3>
          <ul class="kbp-focus-list">
            <li v-for="t in focused.asked" :key="`w${t.note}`">
              <div class="kbp-focus-task"><button class="kbp-reflink" @click="show(t)">{{ t.ref }}</button> {{ t.title }}</div>
              <div class="kbp-question-line">{{ t.question }} <span class="kb-dim kbp-dim">· asked of {{ askedOf(t) }}</span></div>
            </li>
          </ul>
        </template>
        <p class="kb-dim kbp-dim kbp-focus-rest">
          <template v-if="focused.rest.length">Also waiting in {{ key }}: {{ focused.rest.join(', ') }}. </template>
          <button class="kb-link kbp-link" @click="toggleFocus">Show the whole board</button></p>
      </section>

      <!-- What the columns show, and in what order: just above them. -->
      <div v-if="key && !focus" class="kbp-filters">
        <KBTaskSearch :project="key" @open="openFromSearch" />
        <select v-if="board" v-model="only" class="kbp-select" aria-label="Show tasks in a status"
                title="Show the tasks in a status, and those with a subtask in it">
          <option value="">Every status</option><option v-for="s in statuses" :key="s.id" :value="s.id">{{ s.label }}</option></select>
        <select v-if="board" v-model="sortBy" class="kbp-select" aria-label="Sort each column"
                :title="`Sort each column: ${SORTS.find(x => x.id === sortBy)!.help.toLowerCase()}${sorted ? '. Dragging moves a card between columns; reorder by hand in Your order' : ''}`">
          <option v-for="x in SORTS" :key="x.id" :value="x.id">Sort: {{ x.label }}</option></select>
        <label class="kbp-check"><input v-model="subtasks" type="checkbox" /> Subtasks</label>
        <span class="kbp-changed" title="Tint the cards others changed (people, or agents): more strongly since you opened the board">
          <label class="kbp-check"><input v-model="changedOn" type="checkbox" /> Changed by others in</label>
          <select v-model.number="changedHours" class="kbp-select" :disabled="!changedOn" aria-label="Show what others changed within">
            <option v-for="[h, label] in CHANGED_CHOICES" :key="h" :value="h">{{ label }}</option></select></span>
      </div>
      <div v-if="board && !focus" class="kbp-board">
        <section v-for="s in statuses" :key="s.id" class="kbp-col" :class="[s.id, { over: over === s.id }]"
                 @dragover.prevent="over = s.id" @dragleave="over = ''" @drop.prevent="drop(s.id)">
          <h3>{{ s.label }} <span class="kb-dim kbp-dim">{{ column(s.id).length }}</span>
            <button v-if="s.id === 'done' && editable && column('done').length" class="kbp-icon kbp-col-action" title="Archive every done task"
                     aria-label="Archive every done task" @click="archiveDone"><KBIcon name="archive" :size="15" /></button></h3>
          <div v-if="strips && editable && topStrip(s.id)" class="kbp-drop-top" :class="{ aimed: topOf === s.id }"
               @dragover.prevent.stop="topOf = s.id; target = null" @dragleave="topOf = ''" @drop.prevent.stop="dropTop(s.id)">
            {{ draggedStatus !== s.id ? `Move to ${s.label}` : sorted ? 'Out of its task' : 'To the top' }}</div>
          <article v-for="t in column(s.id)" :key="t.ref" class="kbp-card" :data-ref="t.ref"
                   :data-pointer="pointedBy?.ref === t.ref ? initials(pointedBy.name) : undefined"
                   :class="{ ...hints(t), pointed: pointedBy?.ref === t.ref, open: open?.ref === t.ref, agent: t.by_agent, flash: flashed.has(t.ref), saving: busy(`task:${t.ref}`), 'drop-before': target?.ref === t.ref && target.zone === 'before',
                             'drop-into': target?.ref === t.ref && target.zone === 'into' }"
                   :draggable="editable" @dragstart="startDrag(t.ref)" @dragend="dragEnded"
                   @dragover.prevent.stop="aim($event, t)" @dragleave="target = null" @drop.prevent.stop="drop(s.id, t)" @click="show(t)">
            <div class="kbp-card-top"><span class="kbp-ref">{{ t.ref }}</span>
              <span v-if="atWork.has(t.ref)" class="kbp-working" :title="workTitle(t.ref)"></span>
              <span v-for="n in viewers.get(t.ref) ?? []" :key="n" class="kbp-face kbp-face-small" :title="`${n} has it open`">{{ initials(n) }}</span>
              <span v-if="t.priority === 0" class="kbp-tag asap" title="Taken before anything else, in the order marked so">ASAP</span>
              <span v-if="t.priority === 1" class="kbp-tag high">high</span>
              <span v-if="t.blocked" class="kbp-tag blocked" :title="t.blocked">blocked</span>
              <span v-if="t.by_agent" class="kbp-tag" title="Planned by an agent">agent</span>
              <span v-if="approvedAlone(t)" class="kbp-tag alone" :title="`Approved on its own: ${t.parent} is still proposed`">approved alone</span>
              <span v-if="t.sent_back" class="kbp-tag sent" title="Sent back from review: being reworked">sent back</span>
              <span v-if="askingMe.has(t.ref)" class="kbp-tag asking" title="A question here waits on your answer">your answer</span>
              <span v-else-if="answeredMe.has(t.ref)" class="kbp-tag answered" title="Your question here has an answer">answered</span>
              <span v-if="hints(t).fresh || hints(t).recent" class="kbp-changed-dot" :class="{ fresh: hints(t).fresh }" :title="changeTitle(t)"
                    :aria-label="changeTitle(t)" role="img"></span></div>
            <div class="kbp-title">{{ t.title }}</div>
            <div class="kbp-meta">
              <span v-if="t.milestone">{{ t.milestone }}</span>
              <span v-if="t.subtasks">{{ t.subtasks_done }}/{{ t.subtasks }} subtasks</span>
              <span v-if="t.assignee">@{{ personLabel(t.assignee) }}</span>
              <span v-if="t.parent">in {{ t.parent }}</span>
            </div>
            <ul v-if="(subtasks || only) && t.subtasks && !t.parent && cardSubs(t.ref).length" class="kbp-card-subs">
              <li v-for="n in cardSubs(t.ref)" :key="n.t.ref" :style="{ paddingLeft: `${n.d * 0.9}rem` }"
                  :class="{ done: n.t.status === 'done', open: open?.ref === n.t.ref, match: only && n.t.status === only }"
                  :draggable="editable" @dragstart.stop="startDrag(n.t.ref)" @dragend="dragEnded" @click.stop="show(n.t)">
                <span class="kbp-ref">{{ n.t.ref }}</span> <span v-if="atWork.has(n.t.ref)" class="kbp-working" :title="workTitle(n.t.ref)"></span>
                <span class="kbp-sub-title" :title="n.t.title">{{ n.t.title }}</span>
                <span class="kbp-sub-status">{{ label(n.t.status) }}</span>
              </li>
            </ul>
            <div v-if="s.id === 'proposed' && editable" class="kbp-proposal-actions">
              <button class="kbp-approve" :disabled="busy(`task:${t.ref}`)" @click.stop="change(t.ref, { status: 'ready' })">Approve</button>
              <button v-if="!t.parent" class="kbp-approve kbp-decline" :disabled="busy(`task:${t.ref}`)" @click.stop="decline(t.ref)">Decline</button>
            </div>
          </article>
          <form v-if="s.id === 'backlog' && editable" class="kbp-add" data-control="new-task" @submit.prevent="addTask">
            <input v-model="newTitle" placeholder="+ task" :readonly="busy('task')" :aria-busy="busy('task')" />
            <span v-if="busy('task')" class="kbp-spin kbp-spin-in"></span>
          </form>
        </section>
      </div>
      <p v-else-if="!board && !list.length" class="kb-dim kbp-dim">{{ can('projects.all') ? 'No projects yet.' : 'No projects. Ask an administrator to add you to one.' }}</p>

      <KBDock v-if="open" name="task" @close="open = null" @space="makeRoom">
        <template #head>
          <span class="kbp-ref">{{ open.ref }}</span>
          <KBCite compact :cite="{ reference: `@${open.ref}` }" :title="open.title" :link="taskHref(open.ref)" />
          <select v-if="editable" class="kbp-select" data-control="status" :value="moving.get(open.ref) ?? open.status" :disabled="busy(`task:${open.ref}`)" @change="pickStatus">
            <option v-for="s in statuses" :key="s.id" :value="s.id">{{ s.label }}</option>
          </select>
          <span v-else>{{ label(open.status) }}</span>
          <span class="kbp-spacer"></span>
          <button v-if="editable && open.status === 'done' && !open.archived_at" class="kbp-icon" title="Archive" aria-label="Archive" :disabled="busy(`task:${open.ref}`)" @click="archiveTask()"><KBIcon name="archive" /></button>
          <button v-if="editable" class="kbp-icon kbp-danger" title="Delete" aria-label="Delete task" @click="removeTask">
            <KBIcon name="trash" />
          </button>
        </template>
        <div class="kbp-panel" @click="followRef" @keydown="followRef">
        <h2 class="kbp-panel-title">{{ open.title }}</h2>
        <p class="kb-dim kbp-dim">By {{ open.created_by }}{{ open.by_agent ? ' (agent)' : '' }}, {{ when(open.created_at) }}<template v-if="open.parent"> · part of <button class="kbp-reflink" @click="show({ ref: open.parent })">{{ open.parent }}</button></template></p>
        <p v-if="atWork.has(open.ref)" class="kbp-at-work"><span class="kbp-working"></span> At work: {{ workTitle(open.ref) }}</p>
        <div v-if="open.archived_at" class="kbp-proposal">
          Archived {{ when(open.archived_at) }}. <button v-if="editable" class="kb-primary kbp-button kbp-secondary" :disabled="busy(`task:${open.ref}`)" @click="archiveTask(true)"><KBIcon name="unarchive" :size="15" />Unarchive</button>
        </div>
        <div v-if="approvedAlone(open)" class="kbp-proposal kbp-alone">
          Approved on its own, so agents may take it, though {{ open.parent }} is still proposed.
        </div>
        <div v-if="open.status === 'review' && editable" class="kbp-proposal kbp-review-bar">
          Waiting for your review.
          <button class="kb-primary kbp-button" :disabled="busy(`task:${open.ref}`)" @click="change(open.ref, { status: 'done' })">Mark done</button>
          <button class="kb-primary kbp-button kbp-secondary" @click="startSendBack(open.ref)">Send back</button>
        </div>
        <div v-if="open.status === 'proposed' && editable" class="kbp-proposal">
          Waiting for approval. <button class="kb-primary kbp-button" :disabled="busy(`task:${open.ref}`)" @click="change(open.ref, { status: 'ready' })">Approve</button>
          <button v-if="!open.parent" class="kb-primary kbp-button kbp-secondary" :disabled="busy(`task:${open.ref}`)" @click="decline(open.ref)">Decline</button>
        </div>
        <div class="kbp-fields" v-if="editable">
          <label>Milestone <select class="kbp-select" data-control="milestone" :value="open.milestone" @change="change(open.ref, { milestone: ($event.target as HTMLSelectElement).value })">
            <option value="">—</option><option v-for="m in (board?.milestones ?? []).filter(x => !x.closed || x.name === open?.milestone)" :key="m.name" :value="m.name">{{ m.name }}</option></select></label>
          <label>Priority <select class="kbp-select" data-control="priority" :value="open.priority" @change="change(open.ref, { priority: +($event.target as HTMLSelectElement).value })">
            <option v-for="(name, n) in PRIORITIES" :key="n" :value="n">{{ name }}</option></select></label>
          <label>Assignee <select class="kbp-select" data-control="assignee" :value="open.assignee"
            @change="change(open.ref, { assignee: ($event.target as HTMLSelectElement).value })">
            <option value="">nobody</option>
            <option v-if="open.assignee && !people.some(p => p.id === open?.assignee)" :value="open.assignee">{{ open.assignee }}</option>
            <option v-for="p in people" :key="p.id" :value="p.id">{{ p.label }}</option></select></label>
          <button class="kbp-icon" data-control="blocked" :class="{ on: open.blocked }" :title="open.blocked ? 'Unblock' : 'Mark blocked'" :aria-label="open.blocked ? 'Unblock' : 'Mark blocked'"
                  @click="open.blocked ? change(open.ref, { blocked: '' }) : setBlocked()"><KBIcon name="block" /></button>
        </div>
        <p v-if="open.blocked" class="kbp-blocked">Blocked: {{ open.blocked }}</p>
        <p v-if="open.blocked_by.length" class="kbp-blocked">Blocked by
          <button v-for="b in open.blocked_by" :key="b" class="kbp-reflink" @click="show({ ref: b })">{{ b }}</button></p>

        <h3>Plan <button v-if="editable && !editingBody" class="kbp-icon" title="Edit the plan" aria-label="Edit the plan" @click="editingBody = true; draftBody = open.body"><KBIcon name="edit" :size="15" /></button></h3>
        <template v-if="editingBody">
          <KBRefText :project="key" v-model="draftBody" multiline :rows="10" :draft="`task:${open.ref}:plan`" send="save" @submit="saveBody" />
          <button class="kb-primary kbp-button" @click="saveBody">Save</button> <button class="kb-primary kbp-button kbp-secondary" @click="editingBody = false">Cancel</button>
        </template>
        <div v-else-if="open.body" class="kbp-body kb-md" v-html="render(open.body)"></div>
        <p v-else class="kb-dim kbp-dim">No plan written.</p>

        <template v-if="open.subtasks_list.length || editable">
          <h3>Subtasks <span v-if="open.subtasks" class="kb-dim kbp-dim">{{ open.subtasks_done }}/{{ open.subtasks }}</span></h3>
          <ul class="kbp-subtasks">
            <li v-for="s in open.subtasks_list" :key="s.ref" :class="{ done: s.status === 'done' }"
                :draggable="editable" @dragstart="startDrag(s.ref)" @dragend="dragEnded" title="Drag onto a column to make it a task of its own">
              <input v-if="editable" type="checkbox" :data-control="`subtask:${s.ref}`" :checked="s.status === 'done'"
                     @change="($event.target as HTMLInputElement).checked = s.status === 'done'; change(s.ref, { status: s.status === 'done' ? 'backlog' : 'done' })" />
              <button class="kbp-reflink" @click="show(s)">{{ s.ref }}</button> {{ s.title }}
              <span class="kb-dim kbp-dim">{{ label(s.status) }}<template v-if="s.assignee"> · {{ personLabel(s.assignee) }}</template></span>
              <span v-if="open.status === 'proposed' && s.status !== 'proposed'" class="kbp-tag alone" title="Approved on its own, while this task is still proposed">approved alone</span>
            </li>
          </ul>
          <form v-if="editable" class="kbp-form" data-control="new-subtask" @submit.prevent="addSubtask">
            <KBRefText :project="key" v-model="newSubtask.title" placeholder="+ subtask" />
            <select v-model="newSubtask.assignee" class="kbp-select" aria-label="Assignee">
              <option value="">nobody</option><option v-for="p in people" :key="p.id" :value="p.id">{{ p.label }}</option></select>
            <button class="kb-primary kbp-button" :disabled="!newSubtask.title.trim() || busy('subtask')"><span v-if="busy('subtask')" class="kbp-spin"></span>Add</button>
          </form>
        </template>

        <h3>Links</h3>
        <ul class="kbp-links">
          <li v-for="l in open.links" :key="l.kind + l.target"><span class="kb-dim kbp-dim">{{ l.kind }}</span>
            <button v-if="l.kind === 'task' || l.kind === 'blocks'" class="kbp-reflink" @click="show({ ref: l.target })">{{ l.target }}</button>
            <a v-else-if="sourceHref(l.kind, l.target, l.label)" :href="sourceHref(l.kind, l.target, l.label)" target="_blank" rel="noopener">{{ l.label || l.target }}</a><span v-else>{{ l.label || l.target }}</span>
            <button v-if="editable" class="kb-link kbp-link" title="Remove" @click="addLink(true, l)">✕</button></li>
        </ul>
        <form v-if="editable" class="kbp-form" @submit.prevent="addLink()">
          <select v-model="link.kind" class="kbp-select"><option v-for="k in ['paper', 'notebook', 'code', 'chat', 'url', 'task', 'blocks', 'author', 'person']" :key="k">{{ k }}</option></select>
          <input v-model="link.target" placeholder="arXiv id, path, URL or task" /> <button class="kb-primary kbp-button" :disabled="busy('link:')"><span v-if="busy('link:')" class="kbp-spin"></span>Link</button>
        </form>

        <template v-if="open.commits?.length">
          <h3>Commits <span class="kb-dim kbp-dim">{{ open.commits.length }} · <span class="kbp-add">+{{ commitTotals.added }}</span>
            <span class="kbp-del">−{{ commitTotals.removed }}</span></span></h3>
          <ul class="kbp-commits">
            <li v-for="c in open.commits" :key="c.sha">
              <a v-if="c.url" :href="c.url" target="_blank" rel="noopener" class="kbp-sha">{{ c.sha.slice(0, 8) }}</a>
              <code v-else class="kbp-sha">{{ c.sha.slice(0, 8) }}</code>
              <span class="kbp-commit-subject">{{ c.subject }}</span>
              <span class="kb-dim kbp-dim">{{ c.ref }} · {{ when(c.at) }} · <span class="kbp-add">+{{ c.added }}</span> <span class="kbp-del">−{{ c.removed }}</span>
                <template v-if="c.task !== open.ref"> · <button class="kbp-reflink" @click="show({ ref: c.task })">{{ c.task }}</button></template></span>
            </li>
          </ul>
          <button class="kbp-small" :class="{ 'kbp-primary': open.status === 'review' && diffText === null }" @click="toggleDiff">
            {{ diffText === null ? 'Show the changes' : 'Hide the changes' }}</button>
          <div v-if="diffText !== null" class="kbp-diff" role="region" aria-label="Changes"><span v-for="(l, i) in diffLines" :key="i" :class="l.cls">{{ l.text }}</span></div>
        </template>

        <template v-if="open.findings?.length || editable">
          <h3>Findings <a v-if="editable" class="kbp-small kbp-head-action" :href="findingHref(`new/${open.ref}`)"><KBIcon name="plus" :size="14" />Finding</a></h3>
          <ul class="kbp-links">
            <li v-for="f in open.findings" :key="f.ref"><a class="kbp-reflink" :href="findingHref(f.ref)">{{ f.ref }}</a> {{ f.claim }}
              <span class="kb-dim kbp-dim">{{ f.status }}</span></li>
          </ul>
        </template>

        <template v-if="open.mentions?.length">
          <h3>Mentioned in <span class="kb-dim kbp-dim">{{ open.mentions.length }} commit{{ open.mentions.length === 1 ? '' : 's' }}</span></h3>
          <ul class="kbp-commits kbp-mentions">
            <li v-for="c in open.mentions" :key="c.sha">
              <a v-if="c.url" :href="c.url" target="_blank" rel="noopener" class="kbp-sha">{{ c.sha.slice(0, 8) }}</a>
              <code v-else class="kbp-sha">{{ c.sha.slice(0, 8) }}</code>
              <span class="kbp-commit-subject">{{ c.subject }}</span><span class="kb-dim kbp-dim">{{ c.author }} · {{ when(c.at) }}</span>
            </li>
          </ul>
        </template>

        <h3>Activity</h3>
        <ul class="kbp-activity">
          <li v-for="{ e, depth } in threaded" :key="e.id" :class="[e.kind, { flash: flashEvent === e.id, reply: depth > 0 }]" :data-event="e.id"
              :style="depth ? { marginLeft: `${1.2 * depth}rem` } : undefined">
            <div class="kbp-event-head"><span class="kbp-who">{{ e.who }}</span><span v-if="e.by_agent" class="kbp-tag">agent</span>
              <span v-if="e.reply_to && e.kind === 'comment'" class="kbp-tag kbp-answer-tag">answer</span>
              <span v-else-if="e.kind === 'question'" class="kb-dim kbp-dim">{{ e.reply_to ? 'asked back' : 'asked' }} {{ e.to_label }}</span>
              <span class="kb-dim kbp-dim kbp-when">{{ when(e.at) }}</span>
              <button v-if="e.edited_at" class="kb-link kbp-link kbp-edited" :title="'Edited ' + when(e.edited_at) + '; show the earlier text'"
                      @click="showNoteHistory(e.id)">edited</button>
              <span class="kbp-spacer"></span>
              <button v-if="canEditNote(e) && editingNote?.id !== e.id" class="kbp-icon kbp-note-edit" title="Edit" aria-label="Edit this note"
                      @click="editingNote = { id: e.id, text: e.text }"><KBIcon name="edit" :size="14" /></button></div>
            <form v-if="editingNote?.id === e.id" class="kbp-form kbp-note-editing" @submit.prevent="saveNote">
              <KBRefText :project="key" v-model="editingNote.text" multiline :rows="4" :draft="`note:${editingNote.id}`" send="save" @submit="saveNote" />
              <div class="kbp-comment-actions">
                <button class="kb-primary kbp-button" :disabled="!editingNote.text.trim()">Save</button>
                <button type="button" class="kb-primary kbp-button kbp-secondary" @click="editingNote = null">Cancel</button>
              </div>
            </form>
            <div v-else-if="e.kind === 'question'" class="kbp-question" :class="{ open: e.state === 'open' || e.state === 'asked back', mine: waitsOnMe(e) }">
              <span class="kbp-tag" :class="{ alone: waitsOnMe(e) }">{{ questionTag(e) }}</span>
              <button v-if="editable && e.state !== 'resolved'" class="kb-link kbp-link kbp-resolve kbp-reply"
                      :title="`Answer ${e.who}, or ask a question back`" @click="startReply(e)">reply</button>
              <button v-if="editable && e.state !== 'resolved'" class="kb-link kbp-link kbp-resolve"
                      title="Settled some other way, or no longer needs an answer" :disabled="busy(`resolve:${open.ref}:${e.id}`)"
                      @click="resolve(open.ref, e.id)">mark resolved</button>
              <div class="kbp-note kb-md" v-html="render(e.text)"></div>
            </div>
            <div v-else-if="e.kind === 'comment' || e.kind === 'progress'" class="kbp-note kb-md" v-html="render(e.text)"></div>
            <div v-else class="kbp-event">{{ eventText(e) }}</div>
            <ol v-if="noteHistory?.id === e.id" class="kbp-note-history">
              <li v-if="!noteHistory.rows.length" class="kb-dim kbp-dim">No earlier text.</li>
              <li v-for="(h, j) in noteHistory.rows" :key="j">
                <div class="kb-dim kbp-dim">Before {{ h.who }}'s edit, {{ when(h.at) }}</div>
                <div class="kbp-note kb-md" v-html="render(h.text)"></div>
              </li>
            </ol>
          </li>
        </ul>
        <form v-if="editable" class="kbp-form kbp-comment" @submit.prevent="addComment()">
          <div v-for="p in writing" :key="p.id" :ref="el => { if (el) writingEls[p.id] = el as HTMLElement }" class="kbp-writing"><b>{{ p.name }}</b> is writing:<div class="kbp-writing-text">{{ p.draft }}</div></div>
          <div v-if="replyTo" class="kbp-replying">Replying to {{ replyTo.who }}'s question:
            <span class="kb-dim kbp-dim">{{ plainLine(replyTo.text) }}</span>
            <button type="button" class="kb-link kbp-link" @click="replyTo = null">not a reply</button></div>
          <div data-control="comment">
          <KBRefText :project="key" v-model="comment" multiline :rows="3" :placeholder="replyTo ? 'Your answer, or a question back' : 'Comment'"
                     :draft="`task:${open.ref}:comment`" send="send" @submit="comment.trim() && addComment('comment')" /></div>
          <label v-if="!replyTo && waitingMine" class="kbp-answers"><input v-model="answersIt" type="checkbox" />
            Answers {{ waitingMine.who }}'s question: <span class="kb-dim kbp-dim">{{ plainLine(waitingMine.text) }}</span></label>
          <div class="kbp-comment-actions">
            <template v-if="replyTo">
              <button class="kb-primary kbp-button" :disabled="!comment.trim() || busy('comment')"><span v-if="busy('comment')" class="kbp-spin"></span>Answer</button>
              <button type="button" class="kb-primary kbp-button kbp-secondary" :disabled="!comment.trim() || busy('comment')"
                      :title="`Ask ${replyTo.who} a question about it; the first waits on their answer`" @click="addComment('question')">Ask back</button>
            </template>
            <template v-else>
              <button class="kb-primary kbp-button" :disabled="!comment.trim() || busy('comment')"><span v-if="busy('comment')" class="kbp-spin"></span>Comment</button>
              <span class="kbp-ask">
                <button type="button" class="kb-primary kbp-button kbp-secondary" :disabled="!comment.trim() || busy('comment')"
                        title="It waits on them until they reply" @click="addComment('question')">Ask</button>
                <select v-model="askTo" class="kbp-ask-to" aria-label="Whom to ask">
                  <option v-for="o in askOptions" :key="o.value" :value="o.value">{{ o.label }}</option></select></span>
            </template>
          </div>
        </form>
        </div>
      </KBDock>
      <KBDialog v-if="completing" width="min(52rem, 94vw)" @close="completing = null">
        <form class="kbp-modal-box" @submit.prevent="completeMilestone">
          <h3>Complete {{ completing.m.name }}</h3>
          <p class="kb-dim kbp-dim">
            <template v-if="completing.archived">Archives {{ completing.archived }} completed. </template>
            <template v-if="completing.rows.length">Not done yet:</template>
          </p>
          <div v-if="completing.rows.length > 1" class="kbp-settle-all">
            All: <button type="button" class="kbp-small" @click="settleAll('done')">Mark done</button>
            <button type="button" class="kbp-small" @click="settleAll('backlog', '')">Backlog, no milestone</button>
            <button v-for="o in otherMilestones" :key="o.name" type="button" class="kbp-small" @click="settleAll('backlog', o.name)">Backlog, {{ o.name }}</button>
          </div>
          <ul class="kbp-settle">
            <li v-for="r in completing.rows" :key="r.t.ref">
              <span class="kbp-ref">{{ r.t.ref }}</span>
              <span class="kbp-settle-title">{{ r.t.title }}<span v-if="r.t.subtasks" class="kb-dim kbp-dim"> · {{ r.t.subtasks_done }}/{{ r.t.subtasks }} subtasks</span></span>
              <span class="kbp-tag">{{ label(r.t.status) }}</span>
              <select v-model="r.action" class="kbp-select" :aria-label="`What happens to ${r.t.ref}`">
                <option value="done">Mark done</option><option value="backlog">Move to backlog</option></select>
              <select v-model="r.milestone" class="kbp-select" :disabled="r.action !== 'backlog'" :aria-label="`Milestone for ${r.t.ref}`">
                <option value="">No milestone</option>
                <option v-for="o in otherMilestones" :key="o.name" :value="o.name">{{ o.name }}</option></select>
            </li>
          </ul>
          <div class="kbp-modal-actions">
            <button type="button" class="kb-primary kbp-button kbp-secondary" @click="completing = null">Cancel</button>
            <button class="kb-primary kbp-button">Complete {{ completing.m.name }}</button>
          </div>
        </form>
      </KBDialog>
      <KBDialog v-if="sendingBack" @close="sendingBack = null">
        <form class="kbp-modal-box" @submit.prevent="sendBack">
          <h3>Send {{ sendingBack }} back</h3>
          <label class="kbp-field-label">What's needed</label>
          <KBRefText :project="key" v-model="sendBackText" multiline :rows="4" placeholder="What to change" :draft="`send-back:${sendingBack}`" send="send"
                     @submit="sendBack" />
          <label class="kbp-field-label">Subtasks, one per line</label>
          <textarea v-model="sendBackSubtasks" class="kbp-text kbp-wide" rows="3"></textarea>
          <div class="kbp-modal-actions">
            <button type="button" class="kb-primary kbp-button kbp-secondary" @click="sendingBack = null">Cancel</button>
            <button class="kb-primary kbp-button" :disabled="!sendBackText.trim() || busy('send-back')"><span v-if="busy('send-back')" class="kbp-spin"></span>Send back</button>
          </div>
        </form>
      </KBDialog>
      <KBDialog v-if="questionsAsk" @close="questionsAsk = null">
        <div class="kbp-modal-box">
          <h3>{{ questionsAsk.ref }} has {{ questionsAsk.questions.length }} open question{{ questionsAsk.questions.length > 1 ? 's' : '' }}</h3>
          <ul class="kbp-tree">
            <li v-for="q in questionsAsk.questions" :key="q.id"><span class="kb-dim kbp-dim">{{ q.who }}</span> {{ plainLine(q.text) }}</li>
          </ul>
          <div class="kbp-modal-actions">
            <button class="kb-primary kbp-button kbp-secondary" @click="questionsAsk = null">Cancel</button>
            <button class="kb-primary kbp-button kbp-secondary" @click="settleQuestions(false)">Mark done</button>
            <button class="kb-primary kbp-button" @click="settleQuestions(true)">Resolve and mark done</button>
          </div>
        </div>
      </KBDialog>
      <KBDialog v-if="doneAsk" @close="doneAsk = null">
        <div class="kbp-modal-box">
          <h3>Mark {{ doneAsk.ref }} done, with its subtasks?</h3>
          <p class="kb-dim kbp-dim">Also marks done:</p>
          <ul class="kbp-tree">
            <li v-for="n in flat(doneAsk.tree)" :key="n.t.ref" :class="{ done: n.t.status === 'done' }" :style="{ paddingLeft: `${n.d * 1.3}rem` }">
              <span class="kbp-ref">{{ n.t.ref }}</span> <span class="kbp-tree-title">{{ n.t.title }}</span>
              <span class="kbp-tag">{{ label(n.t.status) }}</span>
            </li>
          </ul>
          <div class="kbp-modal-actions">
            <button class="kb-primary kbp-button kbp-secondary" @click="doneAsk = null">Cancel</button>
            <button class="kb-primary kbp-button" autofocus @click="confirmDone">Mark all done</button>
          </div>
        </div>
      </KBDialog>
    </KBNeedsService>
  </div>
</template>

<style scoped>
.kbp { font-size: 0.88rem; }
.kbp-form { display: flex; flex-wrap: wrap; gap: 0.6rem; align-items: center; margin: 0.6rem 0; }
/* The board's bar: the project, its views and menus; then the filters for its tasks. */
.kbp-top { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem 1rem; margin: 0.8rem 0 0.5rem; }
.kbp-project { display: inline-flex; align-items: center; gap: 0.5rem; min-width: 0; }
.kbp-project-select { max-width: min(30rem, 80vw); padding: 0.25rem 1.8rem 0.25rem 0.6rem; border-radius: 8px; border: 1px solid transparent;
  background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font: inherit; font-size: 1.05rem; font-weight: 600; cursor: pointer; }
.kbp-project-select:hover, .kbp-project-select:focus { border-color: var(--vp-c-divider); outline: none; }
.kbp-views { display: inline-flex; align-items: center; gap: 0.15rem; padding: 0.15rem; border-radius: 9px; background: var(--vp-c-bg-soft); }
.kbp-view { display: inline-flex; align-items: center; gap: 0.35rem; padding: 0.25rem 0.65rem; border-radius: 7px; border: none; background: none;
  color: var(--vp-c-text-2); font: inherit; font-size: 0.85rem; cursor: pointer; text-decoration: none; white-space: nowrap; }
.kbp-view:hover { background: var(--vp-c-default-soft); color: var(--vp-c-text-1); }
.kbp-view.on { background: var(--vp-c-bg); color: var(--vp-c-brand-1); box-shadow: var(--vp-shadow-1); }
.kbp-view-n { padding: 0 0.4rem; border-radius: 999px; background: var(--vp-c-default-soft); font-size: 0.72rem; }
.kbp-filters { display: flex; flex-wrap: wrap; align-items: center; gap: 0.6rem; margin: 0 0 0.8rem; }
.kbp-pop { position: relative; }
.kbp-agents-button { display: inline-flex; align-items: center; gap: 0.4rem; padding: 0.2rem 0.7rem; border-radius: 999px; cursor: pointer;
  border: 1px solid var(--vp-c-green-soft, rgba(61,214,140,0.3)); background: none; color: var(--vp-c-text-2); font: inherit; font-size: 0.82rem; }
.kbp-agents-button:hover, .kbp-agents-button.on { color: var(--vp-c-text-1); border-color: var(--vp-c-green-1, #3dd68c); }
.kbp-menu { position: absolute; z-index: 46; top: calc(100% + 6px); right: 0; min-width: 14rem; padding: 0.3rem; border-radius: 10px;
  border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg); box-shadow: var(--vp-shadow-3); }
.kbp-agents-menu { width: min(30rem, 90vw); }
.kbp-people-button { display: inline-flex; align-items: center; gap: 0.15rem; padding: 0.2rem; border-radius: 999px;
  cursor: pointer; border: 1px solid var(--vp-c-divider); background: none; color: var(--vp-c-text-2); font: inherit; font-size: 0.82rem; }
.kbp-people-label { padding: 0 0.45rem; }
.kbp-people-button:hover, .kbp-people-button.on { color: var(--vp-c-text-1); border-color: var(--vp-c-brand-1); }
.kbp-face { display: inline-grid; place-items: center; flex: none; width: 22px; height: 22px; border-radius: 50%; font-size: 0.62rem;
  font-weight: 700; line-height: 1; background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); box-shadow: 0 0 0 2px var(--vp-c-bg); }
.kbp-face.planning { background: var(--vp-c-green-soft, rgba(61,214,140,0.16)); color: var(--vp-c-green-1, #3dd68c); }
.kbp-people-button.planning { border-color: var(--vp-c-green-1, #3dd68c); }
.kbp-levels { display: flex; gap: 0.3rem; padding: 0.2rem 0.6rem; }
.kbp-level { flex: 1; padding: 0.25rem 0.4rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: none; cursor: pointer;
  font: inherit; font-size: 0.82rem; color: var(--vp-c-text-2); }
.kbp-level.on { border-color: var(--vp-c-brand-1); color: var(--vp-c-text-1); background: var(--vp-c-brand-soft); }
.kbp-person { display: flex; align-items: center; gap: 0.5rem; }
.kbp-following { display: flex; align-items: center; gap: 0.5rem; margin: 0.4rem 0; padding: 0.35rem 0.7rem; border-radius: 8px;
  font-size: 0.85rem; background: var(--vp-c-green-soft, rgba(61,214,140,0.12)); color: var(--vp-c-text-1); }
.kbp-writing { margin: 0.4rem 0; padding: 0.4rem 0.6rem; border-left: 3px solid var(--vp-c-green-1, #3dd68c); font-size: 0.85rem; color: var(--vp-c-text-2); }
.kbp-writing-text { white-space: pre-wrap; color: var(--vp-c-text-1); margin-top: 0.2rem; }
.kbp-card.pointed { outline: 2px solid var(--vp-c-green-1, #3dd68c); outline-offset: 1px; position: relative; }
.kbp-card.pointed::after { content: attr(data-pointer); position: absolute; top: -9px; right: -9px; padding: 1px 5px; border-radius: 999px;
  font-size: 0.6rem; font-weight: 700; background: var(--vp-c-green-1, #3dd68c); color: var(--vp-c-bg); }
.kbp-touched { outline: 2px solid var(--vp-c-green-1, #3dd68c) !important; outline-offset: 2px; border-radius: 6px; }
/* In the window's bottom-right corner, over the task's panel when it is docked there. */
.kbp-session { position: fixed; right: 12px; bottom: 12px; z-index: 100;
  display: flex; align-items: center; gap: 0.3rem; padding: 2px 3px 2px 5px; border-radius: 999px; font-size: 0.72rem;
  background: var(--vp-c-bg-elv); border: 1px solid var(--vp-c-divider); box-shadow: var(--vp-shadow-1); opacity: 0.55; transition: opacity 0.15s; }
.kbp-session:hover, .kbp-session.lit { opacity: 1; }
.kbp-session .kbp-face { width: 18px; height: 18px; font-size: 0.55rem; }
.kbp-session-what { white-space: nowrap; color: var(--vp-c-text-2); padding: 0 0.15rem; }
.kbp-pen { display: inline-grid; place-items: center; width: 22px; height: 20px; border-radius: 999px; cursor: pointer;
  border: 1px solid transparent; background: none; color: var(--vp-c-text-2); padding: 0; }
.kbp-pen:hover { color: var(--vp-c-text-1); border-color: var(--vp-c-divider); }
.kbp-pen.on { color: var(--vp-c-bg); background: #ff6b6b; }
.kbp-session-stop { width: 18px; height: 18px; border-radius: 50%; border: none; background: none; cursor: pointer; color: var(--vp-c-text-3);
  font-size: 0.85rem; line-height: 1; }
.kbp-session-stop:hover { color: var(--vp-c-text-1); background: var(--vp-c-default-soft); }
.kbp-ink-catch { position: fixed; inset: 0; z-index: 60; cursor: crosshair; touch-action: none; }
.kbp-ink { position: fixed; inset: 0; width: 100vw; height: 100vh; z-index: 61; pointer-events: none; }
.kbp-face-small { width: 18px; height: 18px; font-size: 0.55rem; vertical-align: middle; }
.kbp-menu-label { padding: 0.3rem 0.6rem 0.2rem; font-size: 0.7rem; letter-spacing: 0.05em; text-transform: uppercase; color: var(--vp-c-text-3); }
.kbp-menu-item { display: flex; align-items: center; gap: 0.5rem; width: 100%; padding: 0.4rem 0.6rem; border-radius: 7px; border: none;
  background: none; color: var(--vp-c-text-1); font: inherit; font-size: 0.86rem; text-align: left; cursor: pointer; }
.kbp-menu-item:hover { background: var(--vp-c-default-soft); }
.kbp-menu-ref { font-family: var(--vp-font-family-mono); font-size: 0.75rem; color: var(--vp-c-text-2); white-space: nowrap; }
.kbp-menu-title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.kbp-menu-dim { font-size: 0.75rem; color: var(--vp-c-text-3); white-space: nowrap; }
.kbp-menu-wait { cursor: default; color: var(--vp-c-text-3); }
.kbp-menu-wait:hover { background: none; }
.kbp-menu-danger { color: var(--vp-c-danger-1); }
.kbp-menu-danger:hover { background: var(--vp-c-danger-soft); }
.kbp-spacer { flex: 1; }
.kbp-select, .kbp-form input, .kbp-text, .kbp-add input { padding: 0.3rem 0.5rem; border-radius: 6px; border: 1px solid var(--vp-c-divider);
  background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font: inherit; }
.kbp-short { width: 6rem; }
.kbp-check { display: inline-flex; gap: 0.3rem; align-items: center; color: var(--vp-c-text-2); }
.kbp-button { padding: 0.3rem 0.8rem; border-radius: 6px; }
.kbp-button:disabled { opacity: 0.5; cursor: default; }
.kbp-secondary { display: inline-flex; align-items: center; gap: 0.3rem; background: none; color: var(--vp-c-brand-1); border: 1px solid var(--vp-c-brand-1); }

/* Shown only when something waits, so it stands out: an accent edge and tint, and counts in the accent. */
.kbp-waiting { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; margin: 0.4rem 0 0.8rem; padding: 0.55rem 0.8rem;
  border-radius: 10px; border-left: 4px solid var(--vp-c-brand-1);
  background: color-mix(in srgb, var(--vp-c-brand-1) 9%, var(--vp-c-bg-soft)); }
.kbp-waiting > .kbp-waiting-label { color: var(--vp-c-brand-1); font-weight: 700; }
/* A section whose tasks' cards are marked in a colour has its pill and count in that colour: questions
   to answer amber, answers to yours purple, your own tasks the accent (see `hints`). */
.kbp-waiting > .kbp-ms { border-color: var(--vp-c-divider); }
.kbp-waiting > .kbp-ms:hover { border-color: var(--vp-c-text-3); }
.kbp-waiting > .kbp-ms.w-questions { border-color: var(--vp-c-warning-1); }
.kbp-waiting > .kbp-ms.w-answered { border-color: var(--vp-c-purple-1); }
.kbp-waiting > .kbp-ms.w-mine { border-color: var(--vp-c-brand-1); }
.kbp-waiting > .kbp-ms .kbp-n { color: var(--vp-c-text-1); }
.kbp-waiting > .kbp-ms.w-questions .kbp-n { color: var(--vp-c-warning-1); }
.kbp-waiting > .kbp-ms.w-answered .kbp-n { color: var(--vp-c-purple-1); }
.kbp-waiting > .kbp-ms.w-mine .kbp-n { color: var(--vp-c-brand-1); }
.kbp-n { color: var(--vp-c-brand-1); font-weight: 700; }
.kbp-waiting-label { font-size: 0.72rem; letter-spacing: 0.05em; text-transform: uppercase; color: var(--vp-c-text-2); margin-right: 0.3rem; }
.kbp-waiting-list { flex-basis: 100%; list-style: none; margin: 0.3rem 0 0; padding: 0; }
.kbp-waiting-list li { display: flex; gap: 0.45rem; align-items: baseline; padding: 0.15rem 0; overflow-wrap: anywhere; }
.kbp-milestones { display: flex; flex-wrap: wrap; gap: 0.5rem; margin: 0.4rem 0 0.8rem; }
.kbp-ms { display: inline-flex; gap: 0.4rem; align-items: center; padding: 0.25rem 0.6rem; border-radius: 999px; cursor: pointer;
  border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font: inherit; font-size: 0.8rem; }
/* Active (where new tasks go): a faint tint of the brand; shown alone (on): filled. */
.kbp-ms.active { border-color: color-mix(in srgb, var(--vp-c-brand-1) 30%, var(--vp-c-divider)); }
.kbp-ms.on { border-color: var(--vp-c-brand-1); background: var(--vp-c-brand-soft); }
.kbp-ms.closed { opacity: 0.6; }
.kbp-ms.aimed { border-color: var(--vp-c-brand-1); outline: 2px dashed var(--vp-c-brand-1); outline-offset: 2px; }
.kbp-ms-none { border-style: dashed; color: var(--vp-c-text-2); cursor: default; }
.kbp-active-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--vp-c-brand-1); }
.kbp-meter { width: 4rem; height: 4px; border-radius: 2px; background: var(--vp-c-default-soft); overflow: hidden; }
.kbp-meter span { display: block; height: 100%; background: var(--vp-c-brand-1); }

.kbp-board { display: grid; grid-template-columns: repeat(6, minmax(11rem, 1fr)); gap: 0.6rem; overflow-x: auto; padding-bottom: 0.5rem; }
.kbp-col { position: relative; background: var(--vp-c-bg-soft); border-radius: 10px; padding: 0.5rem; min-height: 8rem; border: 1px solid transparent; }
/* Over the column's heading while a card is dragged (see dropTop), so nothing below it moves. */
.kbp-drop-top { position: absolute; inset: 0 0 auto 0; height: 5rem; z-index: 2; display: flex; align-items: center; justify-content: center;
                border: 2px dashed var(--vp-c-divider); border-radius: 10px; font-size: 0.85rem; font-weight: 600; color: var(--vp-c-text-2);
                background: var(--vp-c-bg-soft); }
.kbp-drop-top.aimed { border-color: var(--vp-c-brand-1); color: var(--vp-c-brand-1);
                      background: linear-gradient(var(--vp-c-brand-soft), var(--vp-c-brand-soft)), var(--vp-c-bg-soft); }
.kbp-col.over { border-color: var(--vp-c-brand-1); }
.kbp-col.proposed { background: color-mix(in srgb, var(--vp-c-warning-soft) 60%, var(--vp-c-bg-soft)); }
.kbp-col h3 { margin: 0.1rem 0.2rem 0.5rem; font-size: 0.75rem; letter-spacing: 0.05em; text-transform: uppercase; color: var(--vp-c-text-2); border: none; padding: 0; }
.kbp-card { background: var(--vp-c-bg); border: 1px solid var(--vp-c-divider); border-radius: 8px; padding: 0.45rem 0.55rem; margin-bottom: 0.45rem; cursor: pointer;
  overflow-wrap: anywhere; }
.kbp-card:hover, .kbp-card.open { border-color: var(--vp-c-brand-1); }
/* Hints: an edge for what is yours (the colour of you elsewhere on the board) or waits on you, a blue
   dot (.kbp-changed-dot) for what others changed lately. */
.kbp-changed-dot { flex: none; margin-left: auto; width: 8px; height: 8px; border-radius: 50%; border: 1.5px solid var(--vp-c-indigo-1); }
.kbp-changed-dot.fresh { background: var(--vp-c-indigo-1); }
.kbp-card.mine { box-shadow: inset 3px 0 0 var(--vp-c-brand-1); }
.kbp-card.answered { box-shadow: inset 3px 0 0 var(--vp-c-purple-1); }
.kbp-card.asking { box-shadow: inset 3px 0 0 var(--vp-c-warning-1); }
.kbp-changed { display: inline-flex; align-items: center; gap: 0.4rem; font-size: 0.85rem; color: var(--vp-c-text-2); }
.kbp-changed input[type=checkbox] { accent-color: var(--vp-c-indigo-1); }
.kbp-changed select:disabled { opacity: 0.5; }
.kbp-tag.asking { background: var(--vp-c-warning-soft); color: var(--vp-c-warning-1); }
.kbp-tag.answered { background: var(--vp-c-purple-soft); color: var(--vp-c-purple-1); }
/* An update pulses three times over six seconds: noticeable, then gone. */
.kbp-card.flash { animation: kbp-flash 2s ease-in-out 3; }
/* On its way to the service: see `sending`. */
.kbp-card.saving { animation: kbp-saving 1s ease-in-out infinite; }
@keyframes kbp-saving { 50% { opacity: 0.55; } }
.kbp-spin { display: inline-block; width: 0.8em; height: 0.8em; margin-right: 0.35em; vertical-align: -0.1em; border-radius: 50%;
            border: 2px solid currentColor; border-right-color: transparent; animation: kbp-spin 0.7s linear infinite; }
.kbp-spin-in { position: absolute; right: 0.5rem; top: 50%; margin: -0.4em 0 0; color: var(--vp-c-text-2); }
@keyframes kbp-spin { to { transform: rotate(360deg); } }
.kbp-button:disabled, .kbp-approve:disabled { opacity: 0.6; cursor: default; }
@keyframes kbp-flash { 0%, 100% { box-shadow: 0 0 0 0 transparent; } 30% { box-shadow: 0 0 0 2px var(--vp-c-brand-1), 0 0 14px var(--vp-c-brand-soft); } }
.kbp-waiting.pulse, .kbp-ms.pulse { animation: kbp-pulse 2s ease-out 3; }
.kbp-ms.pulse { border-color: var(--vp-c-brand-1); }
.kbp-answer-line { color: var(--vp-c-text-1); display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.kbp-answer-line::before { content: '↳ '; color: var(--vp-c-text-3); }
.kbp-resolve { margin-left: 0.4rem; font-size: 0.78rem; }
/* Approve and Decline stay on one line, sharing a narrow column, each word whole. */
.kbp-proposal-actions { display: flex; gap: 0.4rem; }
.kbp-proposal-actions .kbp-approve { flex: 0 1 auto; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  overflow-wrap: normal; }
.kbp-approve.kbp-decline { border-color: var(--vp-c-divider); color: var(--vp-c-text-2); }
.kbp-approve.kbp-decline:hover { border-color: var(--vp-c-danger-1); color: var(--vp-c-danger-1); }
.kbp-dismiss-wide { margin-left: auto; }
.kbp-dismiss { width: 22px; height: 22px; margin-left: auto; }
.kbp-activity li.flash { animation: kbp-flash 2s ease-in-out 3; border-radius: 6px; }
.kbp-waiting-list li.flash { animation: kbp-flash 2s ease-in-out 3; border-radius: 6px; }
@keyframes kbp-pulse { 0% { box-shadow: 0 0 0 0 var(--vp-c-brand-soft); } 60% { box-shadow: 0 0 0 6px transparent; } 100% { box-shadow: 0 0 0 0 transparent; } }
.kbp-at-work { display: flex; align-items: center; gap: 0.4rem; margin: -0.3rem 0 0.4rem; font-size: 0.82rem; color: var(--vp-c-text-2); }
.kbp-working { display: inline-block; flex: none; width: 8px; height: 8px; border-radius: 50%; background: var(--vp-c-green-1, #3dd68c);
  animation: kbp-working 1.8s ease-in-out infinite; vertical-align: middle; }
@keyframes kbp-working { 0%, 100% { box-shadow: 0 0 0 0 rgba(61, 214, 140, 0.55); } 50% { box-shadow: 0 0 0 4px rgba(61, 214, 140, 0); } }
.kbp-live { display: inline-flex; align-items: center; }
.kbp-live::before { content: ''; width: 8px; height: 8px; border-radius: 50%; background: var(--vp-c-text-3); }
.kbp-live.on::before { background: var(--vp-c-green-1, #3dd68c); }
.kbp-card.drop-before { box-shadow: 0 -3px 0 var(--vp-c-brand-1); }
.kbp-card.drop-into { outline: 2px dashed var(--vp-c-brand-1); outline-offset: 2px; }
.kbp-card-subs { list-style: none; margin: 0.4rem 0 0; padding: 0.3rem 0 0; border-top: 1px solid var(--vp-c-divider); font-size: 0.78rem; }
.kbp-card-subs li { display: flex; gap: 0.3rem; align-items: baseline; padding: 0.12rem 0.2rem; border-radius: 4px; cursor: pointer; }
.kbp-card-subs li:hover, .kbp-card-subs li.open { background: var(--vp-c-default-soft); }
.kbp-card-subs li.done .kbp-sub-title { color: var(--vp-c-text-3); text-decoration: line-through; }
.kbp-card-subs li.match .kbp-sub-status { color: var(--vp-c-brand-1); font-weight: 600; }
.kbp-sub-title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--vp-c-text-1); }
.kbp-sub-status { color: var(--vp-c-text-3); font-size: 0.7rem; white-space: nowrap; }
.kbp-card-top { display: flex; flex-wrap: wrap; gap: 0.3rem; align-items: center; }
.kbp-card-top .kbp-ref { white-space: nowrap; line-height: 18px; }
.kbp-ref { font-family: var(--vp-font-family-mono); font-size: 0.72rem; color: var(--vp-c-text-2); }
.kbp-title { margin: 0.15rem 0; line-height: 1.35; color: var(--vp-c-text-1); }
.kbp-meta { display: flex; flex-wrap: wrap; gap: 0.5rem; font-size: 0.72rem; color: var(--vp-c-text-2); }
.kbp-tag { white-space: nowrap; font-size: 0.65rem; padding: 0 0.35rem; border-radius: 4px; background: var(--vp-c-default-soft); color: var(--vp-c-text-2); margin-left: 0.2rem; }
.kbp-tag.high { background: var(--vp-c-warning-soft); color: var(--vp-c-warning-1); }
.kbp-tag.alone { background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kbp-proposal.kbp-alone { background: var(--vp-c-brand-soft); }
.kbp-modal-box h3 { margin: 0 0 0.4rem; border: none; padding: 0; font-size: 1.05rem; }
.kbp-tree { list-style: none; margin: 0.6rem 0; padding: 0; }
.kbp-tree li { display: flex; gap: 0.4rem; align-items: baseline; padding: 0.2rem 0; }
.kbp-tree li.done { opacity: 0.55; }
.kbp-tree-title { flex: 1; }
.kbp-modal-actions { display: flex; justify-content: flex-end; gap: 0.5rem; margin-top: 0.8rem; }
.kbp-tag.sent { background: var(--vp-c-warning-soft); color: var(--vp-c-warning-1); }
.kbp-proposal.kbp-review-bar { background: var(--vp-c-brand-soft); }
.kbp-settle-all { display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: center; margin: 0.5rem 0; font-size: 0.8rem; color: var(--vp-c-text-2); }
.kbp-settle { list-style: none; margin: 0.5rem 0; padding: 0; }
.kbp-settle li { display: flex; gap: 0.5rem; align-items: center; padding: 0.35rem 0; border-bottom: 1px solid var(--vp-c-divider); }
.kbp-settle-title { flex: 1; min-width: 0; }
.kbp-context { margin: 0.4rem 0 0.8rem; padding: 0.55rem 0.8rem; border-radius: 10px; background: var(--vp-c-bg-soft); }
.kbp-context.empty { background: none; padding: 0 0.2rem; }
.kbp-context-head { display: flex; gap: 0.5rem; align-items: center; }
.kbp-context-head .kbp-waiting-label { flex: 1; }
.kbp-context-text.clipped { max-height: 4.6em; overflow: hidden; -webkit-mask-image: linear-gradient(#000 60%, transparent); }
.kbp-context-actions { display: flex; gap: 0.5rem; margin-top: 0.5rem; }
.kbp-field-label { display: block; margin: 0.7rem 0 0.3rem; font-size: 0.8rem; color: var(--vp-c-text-2); }
.kbp-wide { width: 100%; box-sizing: border-box; }
.kbp-tag.asap { background: var(--vp-c-danger-soft); color: var(--vp-c-danger-1); font-weight: 600; }
.kbp-tag.blocked { background: var(--vp-c-danger-soft); color: var(--vp-c-danger-1); }
.kbp-approve { margin-top: 0.35rem; padding: 0.15rem 0.6rem; border-radius: 6px; border: 1px solid var(--vp-c-brand-1); background: none; color: var(--vp-c-brand-1); cursor: pointer; font: inherit; font-size: 0.78rem; }
.kbp-add input { width: 100%; box-sizing: border-box; background: transparent; }
form.kbp-add { position: relative; }

.kbp-panel-title { margin: 0.5rem 0 0.2rem; border: none; padding: 0; font-size: 1.25rem; }
.kbp-panel { overflow-wrap: anywhere; }
.kbp-panel h3 { font-size: 0.75rem; letter-spacing: 0.05em; text-transform: uppercase; color: var(--vp-c-text-2); margin: 1.1rem 0 0.4rem; }
.kbp-proposal { margin: 0.6rem 0; padding: 0.5rem 0.7rem; border-radius: 8px; background: var(--vp-c-warning-soft); display: flex; gap: 0.6rem; align-items: center; }
.kbp-fields { display: flex; flex-wrap: wrap; gap: 0.8rem; align-items: center; margin: 0.6rem 0; color: var(--vp-c-text-2); }
/* In a narrow panel a label's word stays whole and its menu goes below it. */
.kbp-fields label { display: inline-flex; flex-wrap: wrap; gap: 0.35rem; align-items: center; max-width: 100%;
  white-space: nowrap; overflow-wrap: normal; }
.kbp-fields .kbp-select { min-width: 0; max-width: 100%; }
.kbp-blocked { color: var(--vp-c-danger-1); margin: 0.3rem 0; }
.kbp-body { line-height: 1.55; }
.kbp-text { width: 100%; box-sizing: border-box; font-family: var(--vp-font-family-mono); font-size: 0.8rem; margin-bottom: 0.4rem; }
.kbp-subtasks, .kbp-links, .kbp-activity { list-style: none; padding: 0; margin: 0; }
.kbp-subtasks li, .kbp-links li { display: flex; gap: 0.45rem; align-items: baseline; padding: 0.15rem 0; }
.kbp-subtasks a, .kbp-subtasks .kbp-dim, .kbp-links .kbp-dim { white-space: nowrap; }
.kbp-subtasks li.done { color: var(--vp-c-text-2); text-decoration: line-through; }
.kbp-activity li { padding: 0.35rem 0; border-bottom: 1px solid var(--vp-c-divider); }
.kbp-activity li.comment, .kbp-activity li.progress { padding: 0.5rem 0; }
.kbp-edited { font-size: 0.72rem; color: var(--vp-c-text-3); }
.kbp-codebase { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: baseline; margin-top: 0.5rem; font-size: 0.85rem; }
.kbp-codebase code { font-size: 0.75rem; }
.kbp-records { margin-top: 0.5rem; font-size: 0.85rem; }
.kbp-records-head { display: flex; gap: 0.5rem; align-items: baseline; cursor: pointer; list-style: none; width: fit-content; }
.kbp-records-head::-webkit-details-marker { display: none; }
.kbp-records-head::before { content: '▸'; color: var(--vp-c-text-3); font-size: 0.75rem; }
.kbp-records[open] > .kbp-records-head::before { content: '▾'; }
.kbp-records-list { list-style: none; margin: 0.3rem 0 0; padding: 0; display: grid; grid-template-columns: max-content 1fr;
                    column-gap: 0.9rem; row-gap: 0.15rem; }
.kbp-records-list li { display: contents; }
/* A title is a link as wide as its text, not as its column. */
.kbp-records-list a { justify-self: start; }
.kbp-records-list .kbp-dim { font-variant-numeric: tabular-nums; }
.kbp-records-more { display: inline-block; margin-top: 0.2rem; }
.kbp-commits { list-style: none; padding: 0; margin: 0 0 0.5rem; }
.kbp-commits li { display: flex; flex-wrap: wrap; gap: 0.45rem; align-items: baseline; padding: 0.2rem 0; font-size: 0.85rem; }
.kbp-sha { font-family: var(--vp-font-family-mono); font-size: 0.75rem; }
.kbp-commit-subject { flex: 1; min-width: 12rem; }
.kbp-mentions { opacity: 0.8; }
.kbp-add { color: var(--vp-c-green-1, #3fb67c); }
.kbp-del { color: var(--vp-c-red-1, #e5534b); }
.kbp-primary { border-color: var(--vp-c-brand-1) !important; color: var(--vp-c-brand-1) !important; }
.kbp-diff { margin: 0.5rem 0 0.8rem; padding: 0.5rem 0; max-height: 60vh; overflow: auto; border-radius: 8px; background: var(--vp-c-bg-alt);
  font-family: var(--vp-font-family-mono); font-size: 0.75rem; line-height: 1.45; }
.kbp-diff span { display: block; white-space: pre; padding: 0 0.7rem; min-height: 1.45em; }
.kbp-diff .add { background: color-mix(in srgb, var(--vp-c-green-1, #3fb67c) 14%, transparent); }
.kbp-diff .del { background: color-mix(in srgb, var(--vp-c-red-1, #e5534b) 14%, transparent); }
.kbp-diff .hunk { color: var(--vp-c-text-3); }
.kbp-diff .file { font-weight: 600; color: var(--vp-c-text-1); }
.kbp-diff .commit { margin-top: 0.6rem; color: var(--vp-c-brand-1); font-weight: 600; }
.kbp-note-edit { opacity: 0; transition: opacity 0.15s; }
.kbp-activity li:hover .kbp-note-edit, .kbp-note-edit:focus-visible { opacity: 1; }
.kbp-note-history { list-style: none; margin: 0.4rem 0 0; padding: 0.3rem 0 0.3rem 0.7rem; border-left: 2px solid var(--vp-c-divider); }
.kbp-note-history li { border: none !important; padding: 0.2rem 0 !important; font-size: 0.85rem; opacity: 0.85; }
.kbp-who { font-weight: 600; }
.kbp-event-head { display: flex; align-items: center; gap: 0.35rem; }
.kbp-when { margin-left: auto; font-size: 0.75rem; }
.kbp-event { color: var(--vp-c-text-2); margin-top: 0.1rem; }
.kbp-reflink { background: none; border: none; padding: 0; font: inherit; font-family: var(--vp-font-family-mono); font-size: 0.78rem;
  color: var(--vp-c-brand-1); cursor: pointer; white-space: nowrap; }
.kbp-reflink:hover { text-decoration: underline; }
.kbp-danger { color: var(--vp-c-danger-1); }
.kbp-icon { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; border-radius: 6px;
  border: none; background: none; cursor: pointer; color: var(--vp-c-text-2); }
.kbp-icon:hover { background: var(--vp-c-default-soft); }
.kbp-icon.on { color: var(--vp-c-brand-1); }
.kbp-head-action { margin-left: 0.5rem; text-transform: none; letter-spacing: 0; text-decoration: none; vertical-align: middle; }
.kbp-fields .kbp-icon.on { color: var(--vp-c-danger-1); }
.kbp-small { display: inline-flex; align-items: center; gap: 0.2rem; padding: 0.15rem 0.55rem 0.15rem 0.4rem; border-radius: 6px; cursor: pointer;
  border: 1px solid var(--vp-c-divider); background: none; color: var(--vp-c-text-2); font: inherit; font-size: 0.8rem; }
.kbp-small:hover { border-color: var(--vp-c-brand-1); color: var(--vp-c-brand-1); }
.kbp-icon.kbp-danger { color: var(--vp-c-text-2); }
.kbp-icon.kbp-danger:hover { color: var(--vp-c-danger-1); background: var(--vp-c-danger-soft); }
.kbp-col-action { float: right; width: 22px; height: 22px; margin-top: -0.2rem; }
.kbp-archive { margin: 0.4rem 0 0.8rem; padding: 0.5rem 0.8rem; border-radius: 10px; background: var(--vp-c-bg-soft); }
.kbp-archive h3 { margin: 0 0 0.3rem; font-size: 0.75rem; letter-spacing: 0.05em; text-transform: uppercase; color: var(--vp-c-text-2); border: none; padding: 0; }
/* Focus: one calm column of what waits on the person, each kind under a heading in its board colour. */
.kbp-focus { max-width: 46rem; margin: 0.6rem auto 2rem; }
.kbp-focus-about { margin-bottom: 1.2rem; padding: 0.6rem 0.9rem; border-radius: 10px; background: var(--vp-c-bg-soft); }
.kbp-focus-none { margin: 2.5rem 0; text-align: center; font-size: 1.05rem; color: var(--vp-c-text-2); }
.kbp-focus-head { margin: 1.4rem 0 0.5rem; padding: 0 0 0 0.6rem; border: none; border-left: 3px solid var(--vp-c-divider);
                  font-size: 0.95rem; font-weight: 600; }
.kbp-focus-head.asking { border-left-color: var(--vp-c-warning-1); }
.kbp-focus-head.answered { border-left-color: var(--vp-c-purple-1); }
.kbp-focus-head.mine { border-left-color: var(--vp-c-brand-1); }
.kbp-focus-group { margin: 0.4rem 0 0.7rem; }
.kbp-focus-group > .kbp-waiting-label { display: block; margin: 0 0 0.25rem; font-size: 0.72rem; }
.kbp-focus-list { list-style: none; margin: 0; padding: 0; }
.kbp-focus-list li { margin: 0 0 0.45rem; padding: 0.5rem 0.7rem; border: 1px solid var(--vp-c-divider); border-radius: 8px;
                     background: var(--vp-c-bg); overflow-wrap: anywhere; }
.kbp-focus-list li .kbp-question-line { margin-left: 0; }
.kbp-focus-list li > .kbp-small { margin-top: 0.15rem; }
.kbp-focus-card { cursor: pointer; }
.kbp-focus-card:hover { border-color: var(--vp-c-text-3); }
.kbp-focus-task { display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: baseline; margin-bottom: 0.15rem; }
.kbp-focus-rest { margin-top: 1.6rem; text-align: center; }
.kbp-note { margin-top: 0.2rem; }
.kbp-question { margin-top: 0.3rem; padding: 0.3rem 0.6rem; border-left: 3px solid var(--vp-c-divider); }
.kbp-question.open { border-left-color: var(--vp-c-warning-1); background: var(--vp-c-warning-soft); border-radius: 0 6px 6px 0; }
.kbp-question.mine { border-left-color: var(--vp-c-brand-1); background: var(--vp-c-brand-soft); }
.kbp-activity li.reply { border-left: 2px solid var(--vp-c-divider); padding-left: 0.6rem; }
.kbp-answer-tag { background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kbp-replying, .kbp-answers { font-size: 0.82rem; display: flex; gap: 0.4rem; align-items: baseline; flex-wrap: wrap; }
.kbp-replying .kb-dim, .kbp-answers .kb-dim { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 28rem; }
.kbp-ask { display: inline-flex; gap: 0.3rem; align-items: center; }
.kbp-ask-to { font: inherit; font-size: 0.82rem; padding: 0.25rem 0.4rem; border: 1px solid var(--vp-c-divider); border-radius: 6px;
              background: var(--vp-c-bg); color: var(--vp-c-text-1); max-width: 14rem; }
.kbp-question-line { flex-basis: 100%; margin: 0.1rem 0 0.3rem 1rem; color: var(--vp-c-text-2); font-size: 0.82rem; }
.kbp-waiting-list li { flex-wrap: wrap; }
.kbp-note :deep(p) { margin: 0.2rem 0; }
.kbp-panel :deep(.kb-ref) { padding: 0 0.3rem; border-radius: 4px; background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1);
  text-decoration: none; font-weight: 500; cursor: pointer; }
.kbp-panel :deep(span.kb-ref-person), .kbp-panel :deep(span.kb-ref-notebook) { cursor: default; }
.kbp-note :deep(ul) { list-style: disc; padding-left: 1.3rem; margin: 0.2rem 0; }
.kbp-note :deep(ol) { list-style: decimal; padding-left: 1.3rem; margin: 0.2rem 0; }
.kbp-note :deep(li) { padding: 0; border: none; }
.kbp-comment { flex-direction: column; align-items: stretch; }
.kbp-comment-actions { display: flex; gap: 0.5rem; }
</style>

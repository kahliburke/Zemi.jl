// What the explore page (KBExplore.vue) and its parts share: the graph's types as /api/graph gives them
// (see src/explore.jl), the colours and names its documents and links are drawn with, and its settings,
// kept in the browser between visits.
import { ref, watch, computed, inject, provide, type InjectionKey, type Ref } from 'vue'

export type Node = {
  id: string; kind: string; title: string; year?: string; page: string; links: number; status?: string; project?: string
  access?: 'open' | 'projects' | 'private'; mine?: boolean; read?: boolean
  x?: [number, number]; p?: [number, number, number]; ux?: [number, number]; up?: [number, number, number]
  px?: [number, number]; pp?: [number, number, number]
  cluster?: number; central?: number; rating?: number
  /** What the map can be coloured by (see `explore_signals` and `explore_graph` in src/explore.jl). */
  bridge?: number; alone?: number; ahead?: number; recent?: number
  added?: string; category?: string; noted?: number; used?: number
}
export type Cluster = { id: number; name: string; description: string; size: number }
/** A subset mapped by itself (`?set=`): what it is, how many documents it has, the subsets it was opened from. */
export type SetInfo = { spec: string; kind: string; name: string; count: number; least: number; few: boolean; trail: { spec: string; name: string }[] }
export type Graph = {
  nodes: Node[]; links: [number, number, string][]; similar: [number, number, number, boolean, boolean][]; clusters: Cluster[]
  built_at: string | null; job: string | null; abstracts: boolean; abstract_only: number; set?: SetInfo
  /** The fewest documents a cluster is mapped by itself with. */
  least?: number
}
/** What the card says of a document (see `explore_node`). */
export type Detail = { id: string; title: string; authors: string[]; published: string; venue: string; abstract: string; summary: string
                       excerpt?: string; topics: string[]; read: boolean }
export type Near = { node: Node; similarity: number; linked: boolean }
export type Linked = { node: Node; kind: string; out: boolean }
export type Pair = { a: Node; b: Node; similarity: number; score: number; at: number }
export type Step = { node: Node; similarity?: number }
/** A row of the legend: `count` the documents shown, `size` a cluster's whole, whatever kinds are shown. */
export type LegendRow = { key: string; colour: string; label: string; count: number; size?: number }

export const LINK_KINDS = [['cites', 'Citations'], ['refers', 'References'], ['related', 'Related'], ['evidence', 'Evidence'], ['task', 'Tasks']] as const
export const NODE_KINDS = [['paper', 'Papers'], ['record', 'Notes and records'], ['code', 'Codebases'], ['resource', 'Resources'],
                           ['finding', 'Findings'], ['task', 'Tasks']] as const
export const KIND_COLOURS: Record<string, string> = { paper: '#5b8def', record: '#3dd68c', code: '#f0a35e', resource: '#c58af9',
                                                      finding: '#f6d55c', task: '#ef6f6c' }
export const CLUSTER_COLOURS = ['#4e79a7', '#f28e2b', '#e15759', '#76b7b2', '#59a14f', '#edc948', '#b07aa1', '#ff9da7',
                                '#9c755f', '#bab0ac', '#86bcb6', '#d37295', '#8cd17d', '#b6992d', '#499894', '#fabfd2']
export const LINK_COLOURS: Record<string, string> = { cites: '#8ab4f8', refers: '#3dd68c', related: '#c58af9', evidence: '#f6d55c', task: '#ef6f6c' }
/** Whose a document is: held for the reader, shared with projects' members, everyone's. */
export const WHOSE = [['mine', 'Yours'], ['projects', 'Projects’'], ['open', 'Everyone’s']] as const
export const WHOSE_COLOURS: Record<string, string> = { mine: '#ff7ab6', projects: '#f0a35e', open: '#5b8def' }
/** What the map is coloured by: a group each document is in (a row of the legend each), or a scale. */
export const COLOUR_BY = [['cluster', 'Cluster'], ['recent', 'The field right now'], ['bridge', 'Bridges'],
                          ['attention', 'The group’s attention'], ['ahead', 'Ahead of its time'], ['alone', 'Loners'],
                          ['year', 'Year published'], ['added', 'Date added'],
                          ['category', 'arXiv category'], ['reading', 'How it was read'], ['kind', 'Kind'], ['whose', 'Whose']] as const
export type ColourBy = typeof COLOUR_BY[number][0]
/** The scales: what a document's value is, and what each end of the scale says. Colours go by rank, so the
 * scale's middle is the middle document, however the values bunch. */
export const SCALES: Partial<Record<ColourBy, { value: (n: Node) => number | undefined; low: string; high: string; about: string }>> = {
  recent: { value: n => n.recent, low: 'quiet', high: 'busy',
            about: 'How much of what is nearest it in meaning was published in the last 30 days: where the field is busy now.' },
  bridge: { value: n => n.bridge, low: 'within its cluster', high: 'between clusters',
            about: 'How many of its nearest in meaning lie in other clusters: what joins topics.' },
  attention: { value: n => (n.kind === 'record' ? 1.5 : n.noted === undefined && !n.used ? undefined : (n.noted ?? 0) + 0.25 * Math.min(n.used ?? 0, 4)),
               low: 'collected', high: 'worked with',
               about: 'How near the group’s notes and records come to it, and how often findings and tasks use it.' },
  ahead: { value: n => n.ahead, low: 'like what came before', high: 'like what came after',
           about: 'How much more it is like the papers published after it than those before it.' },
  alone: { value: n => n.alone, low: 'among many alike', high: 'alone',
           about: 'How unlike even the documents nearest it in meaning it is.' },
  year: { value: n => (n.year ? Number(n.year) : undefined), low: 'earlier', high: 'later', about: 'When it was published.' },
  added: { value: n => (n.added ? Date.parse(n.added) : undefined), low: 'first', high: 'latest', about: 'When it came into the knowledge base.' },
}
/** A colour from a scale's low end (0) to its high end (1): viridis, from where it reads on a dark ground. */
const RAMP = ['#46337e', '#365c8d', '#277f8e', '#1fa187', '#4ac16d', '#9fda3a', '#fde725']
export function ramp(t: number) {
  const x = Math.max(0, Math.min(1, t)) * (RAMP.length - 1), i = Math.min(Math.floor(x), RAMP.length - 2)
  return mix(RAMP[i], RAMP[i + 1], x - i)
}
export const RAMP_CSS = `linear-gradient(to right, ${RAMP.join(', ')})`
/** How a document was read: in full, by its abstract alone, or a note or record of the group's. */
export const READING = [['full', 'Read in full', '#4ac16d'], ['abstract', 'Abstract only', '#5b8def'],
                        ['note', 'Notes and records', '#f0a35e'], ['other', 'Other', '#9aa0aa']] as const
export const reading = (n: Node) => (n.kind === 'record' ? 'note' : n.kind !== 'paper' ? 'other' : n.read === false ? 'abstract' : 'full')
export type ShadeBy = 'off' | 'linked' | 'central' | 'rated'
export const SHADE_BY = [['off', 'Off', 'Every document in its full colour'],
                         ['linked', 'Linked', 'Most cited and referred to among the documents here'],
                         ['central', 'Central', 'Nearest in meaning to the middle of the cluster'],
                         ['rated', 'Rated', 'How relevant the watch judged it, 0 to 3; unrated faintest']] as const
/** The selected document's ring and its nearest, and the drift's path. */
export const BRAND = '#8b7cf6'
export const TRAIL = '#ffb454'
/** How far what is not in view fades: names of other clusters, documents away from the selected one. */
export const DIMMED = 0.4

export const whose = (n: Node) => (n.mine || n.access === 'private' ? 'mine' : n.access === 'projects' ? 'projects' : 'open')
/** A reader's own: what is held for them, and notes and records (on a knowledge base of one, held for no one). */
export const own = (n: Node) => !!n.mine || n.access === 'private' || n.kind === 'record'
export const kindName = (k: string) => ({ paper: 'paper', record: 'note or record', code: 'codebase', resource: 'resource',
                                          finding: 'finding', task: 'task' }[k] ?? k)
const RELATIONS: Record<string, [string, string]> = { cites: ['cites', 'cited by'], refers: ['refers to', 'referred to by'],
                                                      related: ['related to', 'related to'],
                                                      evidence: ['rests on', 'evidence for'], task: ['linked to', 'task on'] }
/** A link's name as seen from one end: `out` from the document that made it. */
export const relation = (kind: string, out: boolean) => (RELATIONS[kind] ?? [kind, kind])[out ? 0 : 1]
export const byline = (d: Detail) => [d.authors.length > 3 ? `${d.authors.slice(0, 3).join(', ')} et al.` : d.authors.join(', '),
                                      d.venue || d.published.slice(0, 10)].filter(Boolean).join(' · ')
export const shortTitle = (t: string) => (t.length > 70 ? t.slice(0, 68).trimEnd() + '…' : t)
export const esc = (s: string) => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!))
/** Colour `b` mixed into `a` by `t`, as hex. */
export function mix(a: string, b: string, t: number) {
  const ch = (h: string, i: number) => parseInt(h.slice(1 + 2 * i, 3 + 2 * i), 16)
  return '#' + [0, 1, 2].map(i => Math.round(ch(a, i) + (ch(b, i) - ch(a, i)) * t).toString(16).padStart(2, '0')).join('')
}

/** A setting kept in the browser under `key`, `fallback` until one is kept. */
export function useStored<T>(key: string, fallback: T): Ref<T> {
  let start = fallback
  try { const v = localStorage.getItem(`kb-explore-${key}`); if (v !== null) start = JSON.parse(v) } catch { /* none kept, or no storage */ }
  const r = ref(start) as Ref<T>
  watch(r, v => { try { localStorage.setItem(`kb-explore-${key}`, JSON.stringify(v)) } catch { /* private mode */ } }, { deep: true })
  return r
}

/** How the page draws the map, as the reader set it: made by the page, and taken up by its panel. */
export function useExploreSettings() {
  const panelOpen = useStored('legend', typeof window === 'undefined' || window.innerWidth > 640)
  const panel = useStored<'colours' | 'show'>('panel', 'colours')
  return {
    view: useStored<'2d' | '3d'>('view', '2d'),
    // Where documents are placed: t-SNE keeps close neighbourhoods, UMAP and PaCMAP more of how groups lie.
    layout: useStored<'tsne' | 'umap' | 'pacmap'>('layout', 'tsne'),
    colourBy: useStored<ColourBy>('colour', 'cluster'),
    shadeBy: useStored<ShadeBy>('shade', 'linked'),
    shownLinks: useStored<string[]>('links', ['cites', 'refers', 'related', 'evidence']),
    shownKinds: useStored<string[]>('kinds', ['paper', 'record', 'code', 'resource', 'finding']),
    // Pairs close in meaning across the whole map: off at first, the selected document's own drawn from it.
    showUnlinked: useStored('pairs', false),
    threshold: useStored('threshold', 0.8),
    // The papers known only by their abstract: left out unless asked for, the map then being of every document.
    abstracts: useStored('abstracts', false),
    driftEvery: useStored('drift', 4.5),
    scope: useStored<'all' | 'cluster' | 'own'>('scope', 'own'),
    panelOpen, panel,
    settingsOpen: computed(() => panelOpen.value && panel.value === 'show'),
  }
}
export type ExploreSettings = ReturnType<typeof useExploreSettings>
export const SETTINGS: InjectionKey<ExploreSettings> = Symbol('explore settings')
export const provideSettings = (s: ExploreSettings) => provide(SETTINGS, s)
export const useSettings = () => inject(SETTINGS)!

/** Every one of a list's kinds on, or, all on already, none. */
export const all = (list: string[], kinds: readonly (readonly [string, string])[]) =>
  list.splice(0, list.length, ...(list.length === kinds.length ? [] : kinds.map(([k]) => k)))
export const toggle = (list: string[], k: string) => { const i = list.indexOf(k); i < 0 ? list.push(k) : list.splice(i, 1) }

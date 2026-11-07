<!--
  How the knowledge base service is doing, refreshed as it runs: its health (memory, disk, the
  database, the services it needs, the site's builds), its jobs and agents with what each is doing,
  and the requests it has answered; with controls for those whose roles allow them (cancel a job,
  interrupt or close an agent, rebuild the site, reload the configuration).
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import { ref, computed } from 'vue'
import { getJSON, post, can, me, onLive, every, type Job } from './kbApi'
import { when, bytes } from './kbFormat'

type Agent = { id: string; status: string; model: string; turn: number; doing: string | null; purpose: string; mine: boolean;
               usage: Record<string, number>; last_activity: number | null }
type Person = { email: string; name: string; what: string; via: string; last: string; active: boolean; open: boolean; requests: number }
type Ops = {
  activity?: { quiet: boolean; running: string[]; people: Person[]; active_minutes: number }
  health: { uptime_seconds: number; started: string; threads: number; papers: number; database_bytes: number; agents_available: boolean
            memory: { process_bytes: number; free_bytes: number; total_bytes: number }; disk: { free_bytes: number } | null
            mcp: { up: boolean; port: number } | null; missing: Record<string, string>
            site: { building: boolean; started: string | null; queued: boolean; build: string | null; finished: string | null; error: string | null }
            last: { watch: string | null; publish: string | null } }
  jobs: Job[]
  metrics: { route: string; count: number; errors: number; waits: boolean; mean_ms: number | null; p95_ms: number | null;
             max_ms: number | null }[]
}
const ops = ref<Ops | null>(null)
// Requests answered at once, and long polls, which wait for a change: their time is not work.
const requests = computed(() => (ops.value?.metrics ?? []).filter(m => !m.waits))
const waits = computed(() => (ops.value?.metrics ?? []).filter(m => m.waits))
// A time, or a dash for a route with no request past its warm-up yet.
const ms = (x: number | null) => x === null ? '—' : x >= 1000 ? `${(x / 1000).toFixed(1)} s` : `${x} ms`
const agents = ref<Agent[]>([])
const agentError = ref('')
const error = ref('')
const note = ref('')

async function load() {
  try { ops.value = await getJSON('/api/ops'); error.value = '' } catch (e: any) { error.value = e.message }
  if (can('agents.view')) {
    try { const a = await getJSON('/api/ops/agents'); agents.value = a.agents; agentError.value = a.error ?? '' }
    catch (e: any) { agentError.value = e.message }
  }
}
// Asked again 5 s after each answer, so a slow service is not asked twice at once.
onLive(async () => { await load(); return every(5000, load) })

async function act(path: string, done: string, ask?: string) {
  if (ask && !confirm(ask)) return
  try { await post(path, '{}'); note.value = done; await load() } catch (e: any) { error.value = e.message }
}

// How long ago an ISO time was, as people read it.
const agoIso = (s: string) => s ? since((Date.now() - Date.parse(s)) / 1000) + ' ago' : ''
function since(seconds: number) {
  const d = Math.floor(seconds / 86400), h = Math.floor(seconds % 86400 / 3600), m = Math.floor(seconds % 3600 / 60)
  return d ? `${d} d ${h} h` : h ? `${h} h ${m} min` : `${m} min`
}
const ago = (t: number | null) => t ? since(Date.now() / 1000 - t) + ' ago' : ''
const tokens = (u: Record<string, number>) => {
  const n = (u.inputTokens ?? 0) + (u.outputTokens ?? 0) + (u.cacheReadTokens ?? 0) + (u.cacheCreationTokens ?? 0)
  return n ? `${(n / 1000).toFixed(0)}k tokens` : ''
}
</script>

<template>
  <div class="kbo">
    <KBNeedsService permission="server.view">
      <template v-if="ops">
        <p v-if="note" class="kbo-note">{{ note }}</p>
        <template v-if="ops.activity">
          <h2>Activity</h2>
          <div class="kbo-use" :class="{ quiet: ops.activity.quiet }">
            <strong>{{ ops.activity.quiet ? 'Quiet' : 'In use' }}</strong>
            {{ ops.activity.quiet ? 'A restart now interrupts no one.' : 'A restart now would interrupt what is below.' }}
          </div>
          <ul v-if="ops.activity.running.length" class="kbo-running">
            <li v-for="r in ops.activity.running" :key="r">{{ r }}</li>
          </ul>
          <table v-if="ops.activity.people.length" class="kbo-table">
            <thead><tr><th>Person</th><th>Last did</th><th>Through</th><th>When</th><th></th></tr></thead>
            <tbody>
              <tr v-for="p in ops.activity.people" :key="p.email" :class="{ 'kbo-idle': !p.active && !p.open }">
                <td>{{ p.name || p.email }}<span v-if="p.email === me?.email" class="kbo-s"> (you)</span></td>
                <td class="kbo-s"><code v-if="p.what">{{ p.what }}</code></td>
                <td class="kbo-s">{{ p.via }}</td>
                <td class="kbo-s">{{ agoIso(p.last) }}<template v-if="p.active"> · {{ p.requests }} in {{ ops.activity.active_minutes }} min</template></td>
                <td><span v-if="p.active" class="kbo-badge active">active</span><span v-else-if="p.open" class="kbo-badge">page open</span></td>
              </tr>
            </tbody>
          </table>
          <p v-else class="kbo-dim">No one signed in since the service started.</p>
        </template>
        <h2>Health</h2>
        <div class="kbo-cards">
          <div class="kbo-card"><div class="kbo-k">Up for</div><div class="kbo-v">{{ since(ops.health.uptime_seconds) }}</div>
            <div class="kbo-s">since {{ when(ops.health.started, 'never') }} · {{ ops.health.threads }} threads</div></div>
          <div class="kbo-card"><div class="kbo-k">Memory</div><div class="kbo-v">{{ bytes(ops.health.memory.process_bytes) }}</div>
            <div class="kbo-s">{{ bytes(ops.health.memory.free_bytes) }} free of {{ bytes(ops.health.memory.total_bytes) }}</div></div>
          <div v-if="ops.health.disk" class="kbo-card"><div class="kbo-k">Disk</div><div class="kbo-v">{{ bytes(ops.health.disk.free_bytes) }} free</div>
            <div class="kbo-s">database {{ bytes(ops.health.database_bytes) }} · {{ ops.health.papers }} documents</div></div>
          <div class="kbo-card"><div class="kbo-k">Agents</div><div class="kbo-v">{{ ops.health.agents_available ? 'available' : 'unavailable' }}</div>
            <div class="kbo-s">through Kaimon</div></div>
          <div v-if="ops.health.mcp" class="kbo-card"><div class="kbo-k">MCP</div><div class="kbo-v">{{ ops.health.mcp.up ? 'serving' : 'down' }}</div>
            <div class="kbo-s">/mcp · Kaimon :{{ ops.health.mcp.port }}</div></div>
        </div>
        <ul v-if="Object.keys(ops.health.missing).length" class="kbo-missing">
          <li v-for="(why, what) in ops.health.missing" :key="what"><strong>{{ what }}</strong>: {{ why }}</li>
        </ul>
        <p v-else class="kbo-dim">All services up.</p>

        <h3>The site</h3>
        <p class="kbo-dim">
          <template v-if="ops.health.site.building">Building since {{ when(ops.health.site.started) }}{{ ops.health.site.queued ? ', another queued' : '' }} · </template>
          <template v-if="ops.health.site.build">Build {{ ops.health.site.build }}<template v-if="ops.health.site.finished">, {{ when(ops.health.site.finished) }}</template></template>
          <template v-else-if="!ops.health.site.building">Rebuilt by zemi on change</template>
          <span v-if="ops.health.site.error" class="kb-error"> · Last build failed: {{ ops.health.site.error }}</span>
        </p>
        <p class="kbo-dim">arXiv checked {{ when(ops.health.last.watch, 'never') }} · published {{ when(ops.health.last.publish, 'never') }}</p>
        <div v-if="can('server.control')" class="kbo-actions">
          <button class="kb-primary kbo-button" @click="act('/api/ops/rebuild', 'Rebuilding.')">Rebuild site</button>
          <button class="kb-primary kbo-button kbo-plain" @click="act('/api/ops/reload', 'Config reloaded.')">Reload config</button>
        </div>

        <h2>Jobs</h2>
        <table v-if="ops.jobs.length" class="kbo-table">
          <thead><tr><th>Job</th><th>Status</th><th>Doing</th><th>Time</th><th></th></tr></thead>
          <tbody>
            <tr v-for="j in ops.jobs.slice(0, 25)" :key="j.id">
              <td>{{ j.name }}</td><td :class="'kbo-st-' + j.status">{{ j.status }}</td>
              <td class="kbo-s">{{ j.error ?? j.message }}</td><td>{{ j.elapsed }}</td>
              <td><button v-if="j.status === 'running' && can('jobs.control')" class="kb-link kbo-link" @click="act(`/api/jobs/${j.id}/cancel`, `Cancelling ${j.name}.`)">cancel</button></td>
            </tr>
          </tbody>
        </table>
        <p v-else class="kbo-dim">No jobs.</p>

        <template v-if="can('agents.view')">
          <h2>Agents</h2>
          <p v-if="agentError" class="kb-error">{{ agentError }}</p>
          <table v-if="agents.length" class="kbo-table">
            <thead><tr><th>Agent</th><th>For</th><th>Status</th><th>Doing</th><th>Used</th><th></th></tr></thead>
            <tbody>
              <tr v-for="a in agents" :key="a.id">
                <td><code>{{ a.id }}</code><div class="kbo-s">{{ a.model }} · turn {{ a.turn }}</div></td>
                <td class="kbo-s">{{ a.purpose || (a.mine ? '' : 'external') }}</td>
                <td :class="'kbo-st-' + a.status">{{ a.status }}<div class="kbo-s">{{ ago(a.last_activity) }}</div></td>
                <td class="kbo-s">{{ a.doing }}</td><td class="kbo-s">{{ tokens(a.usage) }}</td>
                <td v-if="can('agents.control') && a.mine" class="kbo-agent-actions">
                  <button v-if="a.status === 'working'" class="kb-link kbo-link" @click="act(`/api/ops/agents/${a.id}/interrupt`, `Interrupted ${a.id}.`)">interrupt</button>
                  <button class="kb-link kbo-link" @click="act(`/api/ops/agents/${a.id}/close`, `Closed ${a.id}.`, `Close ${a.id}?`)">close</button>
                </td><td v-else></td>
              </tr>
            </tbody>
          </table>
          <p v-else-if="!agentError" class="kbo-dim">No agents.</p>
        </template>

        <h2>Requests</h2>
        <template v-if="ops.metrics.length">
          <table class="kbo-table">
            <thead><tr><th>Route</th><th>Answered</th><th>Failed</th><th>Mean</th><th>95%</th><th>Slowest</th></tr></thead>
            <tbody>
              <tr v-for="m in requests" :key="m.route"><td><code>{{ m.route }}</code></td><td>{{ m.count }}</td>
                <td :class="{ 'kb-error': m.errors }">{{ m.errors }}</td><td>{{ ms(m.mean_ms) }}</td><td>{{ ms(m.p95_ms) }}</td>
                <td>{{ ms(m.max_ms) }}</td></tr>
            </tbody>
          </table>
          <p class="kbo-dim">Since the service started. The times leave out each route's first two requests, which
            compile the code they run.</p>
          <template v-if="waits.length">
            <h3>Waiting for a change</h3>
            <p class="kbo-dim">These requests are held until something changes on the board, or for about 25 seconds:
              their time is waiting, not work.</p>
            <table class="kbo-table">
              <thead><tr><th>Route</th><th>Answered</th><th>Failed</th><th>Mean wait</th></tr></thead>
              <tbody>
                <tr v-for="m in waits" :key="m.route"><td><code>{{ m.route }}</code></td><td>{{ m.count }}</td>
                  <td :class="{ 'kb-error': m.errors }">{{ m.errors }}</td><td>{{ ms(m.mean_ms) }}</td></tr>
              </tbody>
            </table>
          </template>
        </template>
        <p v-else class="kbo-dim">Counted in shared mode.</p>
      </template>
    </KBNeedsService>
    <p v-if="error" class="kb-error">{{ error }}</p>
  </div>
</template>

<style scoped>
.kbo-use { padding: 0.6rem 0.9rem; border-radius: 10px; background: var(--vp-c-warning-soft); color: var(--vp-c-text-1); }
.kbo-use strong { color: var(--vp-c-warning-1); margin-right: 0.3rem; }
.kbo-use.quiet { background: var(--vp-c-green-soft, var(--vp-c-brand-soft)); }
.kbo-use.quiet strong { color: var(--vp-c-green-1, var(--vp-c-brand-1)); }
.kbo-running { margin: 0.5rem 0; font-size: 0.88rem; }
.kbo-idle { opacity: 0.55; }
.kbo-badge { padding: 0.05rem 0.5rem; border-radius: 999px; font-size: 0.75rem; background: var(--vp-c-default-soft); color: var(--vp-c-text-2); }
.kbo-badge.active { background: var(--vp-c-warning-soft); color: var(--vp-c-warning-1); }
.kbo-dim, .kbo-s { color: var(--vp-c-text-2); }
.kbo-s { font-size: 0.8rem; }
.kbo-note { padding: 0.4rem 0.8rem; border-radius: 8px; background: var(--vp-c-brand-soft); }
.kbo-cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(12rem, 1fr)); gap: 0.8rem; margin: 1rem 0; }
.kbo-card { padding: 0.7rem 0.9rem; border-radius: 10px; background: var(--vp-c-bg-soft); }
.kbo-k { font-size: 0.78rem; color: var(--vp-c-text-2); text-transform: uppercase; letter-spacing: 0.04em; }
.kbo-v { font-size: 1.25rem; font-weight: 600; margin: 0.15rem 0; }
.kbo-missing li { color: var(--vp-c-warning-1); }
.kbo-table { width: 100%; font-size: 0.88rem; }
.kbo-actions { display: flex; gap: 0.8rem; flex-wrap: wrap; }
.kbo-button { padding: 0.4rem 0.9rem; }
.kbo-plain { background: var(--vp-c-default-soft); color: var(--vp-c-text-1); }
.kbo-link { margin-right: 0.6rem; }
.kbo-st-running, .kbo-st-working { color: var(--vp-c-brand-1); }
.kbo-st-failed, .kbo-st-dead { color: var(--vp-c-danger-1); }
.kbo-st-cancelled { color: var(--vp-c-text-2); }
.kbo-agent-actions { white-space: nowrap; }
</style>

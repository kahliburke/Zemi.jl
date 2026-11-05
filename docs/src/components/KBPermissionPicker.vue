<!--
  Choosing permissions, by group (PERMISSION_GROUPS in src/accounts.jl): each permission by what it
  allows, its name beside it, a group's box choosing all of the group, and all or none at once.
  `available` limits the choice (a token's to its person's permissions); groups with none of them
  are left out.
-->
<script setup lang="ts">
import { computed } from 'vue'

export type PermissionGroup = { name: string; permissions: { name: string; description: string }[] }
const props = defineProps<{ groups: PermissionGroup[]; available?: string[] }>()
const chosen = defineModel<string[]>({ required: true })

const shown = computed(() => props.groups
  .map(g => ({ ...g, permissions: g.permissions.filter(p => !props.available || props.available.includes(p.name)) }))
  .filter(g => g.permissions.length))
const every = computed(() => shown.value.flatMap(g => g.permissions.map(p => p.name)))
const has = (p: string) => chosen.value.includes(p)
const count = (g: PermissionGroup) => g.permissions.filter(p => has(p.name)).length
function set(names: string[], on: boolean) {
  const rest = chosen.value.filter(p => !names.includes(p))
  chosen.value = on ? [...rest, ...names] : rest
}
const toggleGroup = (g: PermissionGroup) => set(g.permissions.map(p => p.name), count(g) < g.permissions.length)
</script>

<template>
  <div class="kbpp">
    <div class="kbpp-bar">
      <span>{{ chosen.filter(p => every.includes(p)).length }} of {{ every.length }}</span>
      <button type="button" class="kb-link" @click="set(every, true)">all</button>
      <button type="button" class="kb-link" @click="set(every, false)">none</button>
    </div>
    <fieldset v-for="g in shown" :key="g.name" class="kbpp-group">
      <legend>
        <label><input type="checkbox" :checked="count(g) === g.permissions.length"
                      :indeterminate="count(g) > 0 && count(g) < g.permissions.length" @change="toggleGroup(g)" /> {{ g.name }}</label>
      </legend>
      <label v-for="p in g.permissions" :key="p.name" class="kbpp-item">
        <input type="checkbox" :checked="has(p.name)" @change="set([p.name], !has(p.name))" />
        <span>{{ p.description }}</span> <code class="kbpp-id">{{ p.name }}</code>
      </label>
    </fieldset>
  </div>
</template>

<style scoped>
.kbpp { display: flex; flex-direction: column; gap: 0.6rem; }
.kbpp-bar { display: flex; gap: 0.8rem; align-items: baseline; font-size: 0.85rem; color: var(--vp-c-text-2); }
.kbpp-group { border: 1px solid var(--vp-c-divider); border-radius: 8px; padding: 0.3rem 0.8rem 0.6rem; margin: 0; }
.kbpp-group legend { padding: 0 0.3rem; font-weight: 600; font-size: 0.9rem; }
.kbpp-item { display: flex; gap: 0.5rem; align-items: baseline; padding: 0.15rem 0; font-size: 0.9rem; }
.kbpp-id { font-size: 0.75rem; color: var(--vp-c-text-3); background: none; padding: 0; }
</style>

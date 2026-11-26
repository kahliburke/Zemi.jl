// Ranges are also used to validate preferences saved by an earlier visit.
export const forceSliders = [
  { key: 'repulsion', label: 'Repulsion', min: 0, max: 300, step: 5, initial: 50 },
  { key: 'strength', label: 'Link strength', min: 0, max: 1, step: 0.05, initial: 0.2 },
  { key: 'distance', label: 'Link distance', min: 10, max: 250, step: 5, initial: 70 },
  { key: 'centering', label: 'Centering', min: 0, max: 1, step: 0.05, initial: 0.1 },
  { key: 'similarity', label: 'Similarity link weight', min: 0, max: 3, step: 0.1, initial: 1 },
] as const

type Settings = Record<(typeof forceSliders)[number]['key'], number>

export function forceSettings(saved: Partial<Settings> | null): Settings {
  const settings = {} as Settings
  for (const { key, min, max, initial } of forceSliders) {
    const v = saved?.[key]
    settings[key] = typeof v === 'number' && Number.isFinite(v) ? Math.max(min, Math.min(max, v)) : initial
  }
  return settings
}

export function linkStrength(settings: Settings, link: { kind: string; similarity?: number }) {
  return link.kind === 'similar' ? settings.strength * settings.similarity * (link.similarity ?? 0) : settings.strength
}

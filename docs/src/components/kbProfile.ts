// The tutoring profile: a short, optional survey of the learner's background and preferences, kept in
// this browser only (localStorage) and passed to the tutor with each question, without anything that
// identifies them, so it can pitch its explanations. Nothing of it is sent anywhere else. The
// questions are the group's (its config's `[[group.questions]]`), from the site's group.json.
import { ref } from 'vue'
import { siteJSON } from './kbApi'

export type Question = { id: string; text: string; options: string[]; many?: boolean }

export const QUESTIONS = ref<Question[]>([])
let asked: Promise<void> | null = null
export function loadQuestions(): Promise<void> {
  asked ??= (async () => {
    try { QUESTIONS.value = (await siteJSON('/group.json')).questions ?? [] }
    catch { asked = null }
  })()
  return asked
}

export type Profile = { version: number; answers: Record<string, string[]>; notes: Record<string, string>; updated: string }
type Stored = Profile | { optedOut: true }

const KEY = 'kb-tutoring-profile'
export const profile = ref<Profile | null>(null)
export const optedOut = ref(false)
// Whether the tutor's drawer shows the survey (settings opens one of its own, see KBSettings).
export const surveyOpen = ref(false)

export function loadProfile() {
  if (typeof localStorage === 'undefined') return
  loadQuestions()
  try {
    const s: Stored | null = JSON.parse(localStorage.getItem(KEY) ?? 'null')
    optedOut.value = !!s && 'optedOut' in s
    profile.value = s && !('optedOut' in s) ? s : null
  } catch { profile.value = null; optedOut.value = false }
}
export function saveProfile(p: Profile) {
  localStorage.setItem(KEY, JSON.stringify(p)); profile.value = p; optedOut.value = false
}
export function optOut() {
  localStorage.setItem(KEY, JSON.stringify({ optedOut: true })); profile.value = null; optedOut.value = true
}
export function clearProfile() {
  localStorage.removeItem(KEY); profile.value = null; optedOut.value = false
}

// The profile as the tutor reads it: anonymous, the learner's own words and choices only.
export function profileText(p: Profile | null = profile.value): string {
  if (!p) return ''
  const lines: string[] = []
  for (const q of QUESTIONS.value) {
    const a = p.answers[q.id] ?? []
    const note = (p.notes[q.id] ?? '').trim()
    if (!a.length && !note) continue
    lines.push(`- ${q.text} ${a.join('; ') || '(no choice)'}` + (note ? ` (their note: ${note})` : ''))
  }
  return lines.join('\n')
}

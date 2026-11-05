// Dates, sizes, counts and authors as the pages show them. Moments are shown in the reader's time; a
// day written as an ISO date (`2026-10-08`) is the day it names wherever the reader is.

const DAY = /^\d{4}-\d{2}-\d{2}$/
const zone = (s: string) => DAY.test(s) ? { timeZone: 'UTC' } : {}

/** A day, `8 Oct 2026` as the reader's language writes it; `none` for no date. */
export const day = (s: string | null | undefined, none = '') =>
  s ? new Date(DAY.test(s) ? `${s}T00:00:00Z` : s).toLocaleDateString(undefined, { dateStyle: 'medium', ...zone(s) }) : none

/** A day without its year, `8 Oct`. */
export const shortDay = (s: string) =>
  new Date(DAY.test(s) ? `${s}T00:00:00Z` : s).toLocaleDateString(undefined, { month: 'short', day: 'numeric', ...zone(s) })

/** A moment, its day and time; `none` for none. */
export const when = (s: string | null | undefined, none = '') =>
  s ? new Date(s).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : none

/** Today in UTC, as the papers of the day are dated. */
export const todayUtc = (now = new Date()) => now.toISOString().slice(0, 10)

/** A size in bytes, in the largest unit it has a whole one of. */
export function bytes(n: number) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  return `${i < 2 ? Math.round(n) : n.toFixed(1)} ${units[i]}`
}

/** A count with its noun: `1 paper`, `3 papers`. */
export const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`

/** The first `shown` of a paper's authors, with "et al." when it has more (`total`, where the list is cut already). */
export const byline = (authors: string[], shown = 1, total = authors.length) =>
  authors.length ? authors.slice(0, shown).join(', ') + (total > shown ? ' et al.' : '') : ''

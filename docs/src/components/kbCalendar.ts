// Months as a calendar shows them, for KBDayCalendar. Days are ISO dates (`2026-10-08`) in UTC, as
// the papers of the day are, and a month is its first seven characters (`2026-10`).

/** The month `by` months from `month`. */
export function shiftMonth(month: string, by: number): string {
  const [y, m] = month.split('-').map(Number)
  const d = new Date(Date.UTC(y, m - 1 + by, 1))
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`
}

/** The weeks of `month`, Monday first: each day's date, or null for those of the months either side. */
export function monthWeeks(month: string): (string | null)[][] {
  const [y, m] = month.split('-').map(Number)
  const length = new Date(Date.UTC(y, m, 0)).getUTCDate()
  const lead = (new Date(Date.UTC(y, m - 1, 1)).getUTCDay() + 6) % 7
  const cells: (string | null)[] = [...Array(lead).fill(null),
    ...Array.from({ length }, (_, i) => `${month}-${String(i + 1).padStart(2, '0')}`)]
  while (cells.length % 7) cells.push(null)
  return Array.from({ length: cells.length / 7 }, (_, w) => cells.slice(w * 7, w * 7 + 7))
}

/** `month` as its name and year (`October 2026`). */
export const monthName = (month: string) =>
  new Date(`${month}-01T00:00:00Z`).toLocaleString('en', { month: 'long', year: 'numeric', timeZone: 'UTC' })

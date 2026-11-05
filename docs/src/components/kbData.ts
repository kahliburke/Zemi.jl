// The site's lists written with it, which the service rewrites as they change: the papers
// (papers.json, see `paper_record`) and the papers of the day (daily.json). Read once for the pages a
// reader goes through, and again after a minute. What they give is shared, so it is read-only.
import { siteJSON } from './kbApi'

export type Paper = {
  id: string; slug: string; title: string; authors: string[]; authors_total: number; published: string
  category: string; category_title: string; summary: string; topics: string[]; posted_by: string[]; posted: string
  arrivals: { text: string; month: string }[]; processed: boolean
}
/** A paper of the day: the latest first. */
export type Day = { day: string; id: string; title: string }

export const FRESH = { ms: 60_000 }

function cached<T>(path: string): () => Promise<T> {
  let asked: Promise<T> | null = null, at = 0
  return () => {
    if (!asked || Date.now() - at > FRESH.ms) {
      at = Date.now()
      asked = siteJSON(path).catch(e => { asked = null; throw e })
    }
    return asked!
  }
}

export const loadPapers = cached<readonly Readonly<Paper>[]>('/papers.json')
export const loadDays = cached<readonly Readonly<Day>[]>('/daily.json')

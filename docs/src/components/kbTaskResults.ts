import { taskHref } from './kbLinks'
import { plainLine } from './kbUtils'

export type TaskSearchHit = {
  ref: string
  title: string
  matches: { field: string; snippet: string; event: number }[]
}

/** Keep the note's activity id in its address, including when a result is shared or reloaded. */
export function taskResults(tasks: TaskSearchHit[], query: string) {
  return tasks.flatMap(task => {
    const exact = task.ref.toLowerCase() === query.trim().toLowerCase()
    const matches = exact || !task.matches.length ? [undefined] : task.matches
    return matches.map(match => {
      const note = match?.field === 'note' ? match.event : 0
      return {
        ref: task.ref, label: task.title, detail: note ? `${task.ref} · Note ${note}` : `Task · ${task.ref}`,
        snippet: plainLine(match?.snippet ?? ''), href: taskHref(task.ref) + (note ? '/' + note : '')
      }
    })
  })
}

// Names the pages show for what the service stores as codes: the same as the service's own (the
// projects' board takes the statuses from /api/projects instead).

/** A task's status by its id, in the board's order (`STATUS` in src/tasks.jl). */
export const TASK_STATUSES: Record<string, string> = {
  proposed: 'Proposed', backlog: 'Backlog', ready: 'Ready', in_progress: 'In progress', review: 'Review', done: 'Done' }
export const statusLabel = (id: string) => TASK_STATUSES[id] ?? id

/** How relevant a judge rated a paper to the group's work, 0 to 3 (`RELEVANCE` in src/manage.jl). */
export const RELEVANCE = ['unrelated', 'peripheral', 'related', 'central'] as const

/** A person's role in a project, least first (`PROJECT_ROLES` in src/project_access.jl). */
export const PROJECT_ROLES = ['viewer', 'contributor', 'maintainer'] as const

# Projects, records and findings

!!! warning "Needs a server"
    Projects, records and findings need `zemi` or `zemi --shared`; a static copy cannot show them. The
    screenshots are of the demo served by `zemi`.

## Projects

A project has a key, `RB`, and numbered tasks, `RB-1`. A task has a Markdown plan, subtasks, a
milestone, a priority, an assignee and notes (progress, comments, questions). The board groups tasks
by status: proposed, backlog, ready, in progress, review, done.

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/board-light.png" alt="A project board">
  <img class="dark-only" src="./assets/screenshots/board-dark.png" alt="A project board">
</figure>
```

Agents use the same board through the task tools ([Agents and MCP](agents.md)):

1. An agent's plan arrives as a proposed task.
2. A person edits it if needed and approves it.
3. The agent takes it with `next_task`, reports in notes, and moves it to review.
4. Questions from agents wait on the task for a person's answer.

References with `@`: `@RB-12` (task), `@arXiv:2401.00001` (paper), `@RB-F3` (finding), `@doc-…`
(upload), `@rec-…` (record), `@code:path#name` (codebase), and `@[label](kind:target)` for any kind. In a task they
become the task's links; in a finding, its sources.

When a project has a codebase, a commit naming a task is recorded on it: on a trailer line
(`Tasks: RB-12`, or `Task:`, `Refs:`) or after `Part of`, as its work; anywhere else, as a mention.
A new commit that says `Fixes`, `Closes`, `Resolves` or `Implements RB-12` also moves the task to
review, if it is in progress and has not moved since. The first reading of a repository only records.

## Records

A record is the group's own record of its work, usually a meeting: a title, a date, the people in
it and its text, with screenshots in place and a transcript where its source has them. Records come
from sources: Markdown notes uploaded on a project's board, and plugins that
read another system, such as a tool that writes meetings up from their recordings (see
[Extensions](extensions.md)). Each record carries its source's label, saying how it was made. A record handed in again replaces its content and is read again; it
keeps its id, its projects and the findings that cite it.

A record is searched, read and cited like any document, and given to agents and the tutor, who are
told what it is: what people said, not what is established. Its summary says
what was discussed and decided, what is open, and who is to do what. It is never one of the papers:
it is not in the lists of papers, the landscape, the bibliography or the dataset.

Every record says how it was made and when, on its page, in search results and in what agents read.
A new record is seen only by those who manage documents, until one of them links it to a project on
its page or the Manage page; then the project's members see it. They may also open it to every
reader. Run for one person, every record is theirs. The Records page lists those the reader may see,
and a project's board its own. Records are never built into the site: the service shows their pages.

## Findings

A finding is a claim, a Markdown write-up, and its evidence: papers (with the quoted passage),
records, notebooks, code, results, tasks and other findings. Agents draft them; people accept, contest or
supersede them. Every version is kept. A paper's or record's page lists the findings that cite it;
a record that changes marks them for a second look.

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/finding-light.png" alt="A finding">
  <img class="dark-only" src="./assets/screenshots/finding-dark.png" alt="A finding">
</figure>
```

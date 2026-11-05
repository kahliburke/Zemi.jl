# Zemi.jl

A research group's knowledge base: papers, search, summaries, findings, studies, a tutor, and
projects whose tasks people and agents work on. See README.md.

## Keeping it general

Zemi serves any research group. Nothing in the package names a particular group, field, person or
deployment: what is particular to a group is its config (`[group]`, see `src/config.jl`) and its
content (`content_dir`, see `content_path`). Prompts take the group's field and description from the
config; examples in docs, tests and comments use neutral subjects and invented names (Ada, Rowan,
Bea).

## Planning and tasks

Work on Zemi is planned and tracked as tasks in a Zemi knowledge base's projects (find the project
with `zemi.projects(path=<working directory>)`), not in Markdown plan files.

- Plan anything beyond a step or two with `zemi.plan`. It waits on the board for approval.
- When told to work on tasks: answer the questions `zemi.next_task(<project>)` lists first
  (`task_note`, kind comment), then take the next task with `take=true`. Report with `task_note`,
  and move it to review when it is finished.
- End each commit message with a trailer naming the tasks it did, after a blank line:
  `Tasks: KB-12, KB-14`.

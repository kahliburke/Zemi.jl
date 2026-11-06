# Extensions

Records, the group's own accounts of its meetings and the like, come into Zemi through **sources**.
A source reads another system (a folder of notes, a service that writes up recordings) and hands
Zemi what it finds. Zemi has one of its own, `upload`; the rest come from packages Zemi loads as
**plugins**.

A source never writes the knowledge base itself. It is given a run, through which it hands in
records; Zemi checks each, writes it under the source's name, labels it as the source's registration
says, and keeps it apart from everything else, so a source's records can all be removed at once.

!!! warning "Install only plugins you trust"
    A plugin is code run in the service, with the service's rights. What it hands Zemi is still
    checked and labelled, but the code itself can do whatever the service can.

## A source

A source registers itself with `Zemi.record_source!`, in its package's `__init__`:

| Keyword | |
|:---|:---|
| `name` | Lower case letters, digits and dashes. Its records' ids (`rec-<name>-<key>`), its config section and its state are under it. |
| `label` | How its records were made: *Written up by a meeting service from its recordings*. Every record it hands in carries this label, whatever the record says. |
| `modes` | Where it runs: `(:local, :shared)` by default; `(:shared,)` for a source only the shared service should run. |
| `poll`, `every` | `poll(run)`, run every `every` (a period such as `Minute(30)`, or seconds). |
| `accepts`, `read` | `accepts(path)` says whether a file someone uploads is one it reads; `read(run, path)` reads it. |
| `budget` | The most one run may do: `records` written (500), `figure_bytes` of their figures (200 MB), `seconds` (1800). |
| `api` | The version of this interface it was written for: `Zemi.PLUGIN_API`. Zemi refuses a source written for another. |

A source polls, reads uploads, or both. Registering a name again replaces the source. Pass named
functions, so Revise applies edits to them while the service runs.

## An example

A plugin whose source reads a folder of Markdown notes every half hour, each file a record, skipping
the files unchanged since it last read them. The package:

```
FolderNotes/
  Project.toml
  src/FolderNotes.jl
```

```toml
name = "FolderNotes"
uuid = "5d1c2f8e-0b7a-4c39-9a51-3f2e6d4b8c10"
version = "0.1.0"

[deps]
Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
Zemi = "0e5eba47-1706-456b-9465-8f454330c072"
```

```julia
module FolderNotes

using Dates
import Zemi

function poll(run)
    folder = expanduser(Zemi.settings(run)["folder"])
    seen = Zemi.state(run)                     # each file's time when it was last read
    for name in sort(filter(endswith(".md"), readdir(folder)))
        Zemi.cancelled(run) && break
        path = joinpath(folder, name)
        changed = mtime(path)
        get(seen, name, 0.0) == changed && continue
        text = read(path, String)
        heading = match(r"^# (.+)$"m, text)
        put!(run, (; key = name,
                     title = heading === nothing ? splitext(name)[1] : heading[1],
                     date = Date(unix2datetime(changed)),
                     sections = ["Notes" => text]))
        seen[name] = changed
        Zemi.save_state!(run, seen)
    end
    Zemi.progress(run, "$(length(seen)) notes read")
end

__init__() = Zemi.record_source!("folder-notes"; label = "Read from the group's folder of meeting notes",
                                 every = Minute(30), poll, api = Zemi.PLUGIN_API)

end
```

Its settings are its section of the config:

```toml
[plugins]
env = "~/.config/zemi/plugins"
load = ["FolderNotes"]

[sources.folder-notes]
folder = "~/notes/meetings"
```

Zemi's `upload` source (src/upload_source.jl) is written the same way.

## Records

What `put!` takes, a `Zemi.Record` or a NamedTuple or Dict of its fields:

| Field | |
|:---|:---|
| `key` | The record's key in the source, which names it for good. Handed in again, the record is replaced, or skipped if unchanged. |
| `title` | |
| `date` | When it happened: a `Date`, a `DateTime`, or ISO 8601 text. |
| `people` | The names of those who took part. |
| `sections` | Its text: `heading => text` pairs, or `(; heading, text)`. Headings in the text begin parts within a section. |
| `figures` | `(; name, caption, image)`, `image` the bytes or path of a PNG, JPEG or WebP image; the text places one as `![](name)`. |
| `transcript` | `(; speaker, start, stop, text)`, times in seconds into the recording. |
| `url` | Its address in the source. |
| `projects` | The keys of the projects it belongs to. Its members see it; one in no project is seen only by those who manage documents. |
| `access` | `"projects"` (the default) or `"open"`, to every reader. |

A record that fails its checks throws from `put!`; catch it to go on to the next.

## The run

The only thing `poll` and `read` are given:

| | |
|:---|:---|
| `put!(run, record)` | Hand in a record; its id. Once the run is stopped, it throws, which ends the run. |
| `Zemi.state(run)`, `Zemi.save_state!(run, dict)` | A small JSON document kept for the source between runs. |
| `Zemi.settings(run)` | Its section of the config, `[sources.<name>]`, with the settings file's over it. |
| `Zemi.secret(run, key)` | The secret a `file:` or `env:` setting names. |
| `Zemi.progress(run, msg)` | Shown with the run's job. |
| `Zemi.cancelled(run)` | Whether to stop: the budget spent, the job cancelled, the service stopping. |
| `Zemi.upload(run)` | For an uploaded file: `(; name, date, project, by)`; `nothing` for a scheduled run. |

## Modes and scheduling

Sources run in the serving processes only: `zemi`, `zemi --shared` and `zemi dev`, each running the
sources whose modes include its own. A one-off `zemi <command>` runs none.

Each source that polls runs every `every`, one run at a time, as a job beside the others. A run that
fails is tried again after a minute, then after twice as long each time it fails again, up to six
hours (or `every`, if longer); a run that succeeds puts it back on its schedule.

A run that writes its budget's records, or its figures' bytes, or takes its seconds, is stopped:
`put!` throws, and the next run goes on from what the state says.

## Uploads

A file uploaded on a project's board goes to the first source that accepts it,
plugins before Zemi's own. The run's `upload` says who uploaded it and on which project's page;
each record it hands in is linked to that project. The `upload` source reads Markdown: one record a
file, its title the first heading, its date the one given with the upload or the file's, its
sections its headings.

## Status

The Documents page lists the sources for those who manage documents: each one's label, modes, last
run (what it added, changed and skipped, or why it failed), next run and records, kept across
restarts. A source whose records are kept but whose plugin is not loaded is shown as such, and a
plugin that failed to load is shown with its error. A source can be run now, paused and resumed.

An Admin can remove every record a source made, with everything read from them, confirming how many
first (`records.purge`). Its state goes too, and a source still registered is paused until resumed.

## Installing plugins

`[plugins] env` is a Julia environment holding the plugin packages, and `load` the ones to load.
The service puts `env` on its `LOAD_PATH` after its own environment and loads each package; one that
is missing, fails to load or registers for another interface is logged and shown on the Documents
page, and the service runs on without it. Revise follows a loaded plugin's code as it follows
Zemi's.

Make the environment with Zemi in it, then the plugins:

```sh
julia --project=~/.config/zemi/plugins -e 'using Pkg
    Pkg.develop(path = "/path/to/Zemi.jl")
    Pkg.develop(path = "/path/to/FolderNotes")'
```

A plugin runs with the Zemi and the packages the service has loaded, whatever versions its
environment holds; Zemi itself must be in the environment for the plugin's dependencies to resolve.

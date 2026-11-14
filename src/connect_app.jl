# `zemi connect` on a terminal: an app (Tachikoma) that shows the folders kept in step with one's
# library, how each stands and what moved lately, and manages them: adding and removing folders,
# setting what of each never leaves this machine, syncing now, pausing, and handing the syncing to
# the background service. It syncs itself when no other process does (see connect_service.jl);
# while the background service does, it shows the service's status and changes the folder list the
# service reads.
#
#   ↑/↓ choose a folder · a add · d remove · e skipped subfolders · s sync now · p pause · o the
#   library's page · b background · q quit

import Tachikoma as TK

@kwdef mutable struct ConnectApp <: TK.Model
    quit::Bool = false
    tick::Int = 0
    tq::TK.TaskQueue = TK.TaskQueue()
    syncer::Union{Syncer,Nothing} = nothing
    remote::Union{LibraryRemote,Nothing} = nothing   # the library, when not the config's site (tests)
    status::Dict{String,Any} = empty_status()
    config::Dict{String,Any} = Dict{String,Any}()
    selected::Int = 1
    busy::Bool = false                                # a pass of this process's runs
    next_pass::Float64 = 0.0
    who::String = ""                                  # who is signed in
    dialog::Symbol = :none                            # :site, :signing_in, :add_path, :add_name, :skips, :remove
    input::Union{TK.TextInput,Nothing} = nothing
    pending::Dict{String,Any} = Dict{String,Any}()   # what the dialog has gathered
    message::String = ""
    message_error::Bool = false
    farewell::String = ""                             # said once the app has closed
end

TK.should_quit(m::ConnectApp) = m.quit
TK.task_queue(m::ConnectApp) = m.tq

tell!(m::ConnectApp, text::AbstractString; error::Bool = false) = (m.message = String(text); m.message_error = error)

"The folders as the config names them, each with how it stands (see [`Syncer`](@ref))."
function app_folders(m::ConnectApp)
    by_name = Dict(f["name"] => f for f in m.status["folders"])
    map(get(m.config, "folders", Any[])) do f
        st = get(by_name, f["name"], nothing)
        e = Dict{String,Any}("name" => f["name"], "path" => f["path"], "skip" => get(f, "skip", String[]),
                             "state" => st === nothing ? "new" : st["state"], "files" => st === nothing ? 0 : st["files"],
                             "message" => st === nothing ? "" : st["message"], "checked" => st === nothing ? "" : st["checked"],
                             "changed" => st === nothing ? "" : st["changed"])
        get(f, "remove", "") == "library" && (e["state"] = "removing")
        e
    end
end

"Read the config and the status again; take up the syncing when no one does, and start a pass when one is due."
function refresh!(m::ConnectApp)
    m.config = load_connect_config()
    m.syncer === nothing && syncing_pid() === nothing && (m.syncer = claim_syncing())
    m.status = m.syncer === nothing ? read_connect_status() : status_copy(m.syncer)
    n = length(get(m.config, "folders", Any[]))
    m.selected = clamp(m.selected, 1, max(n, 1))
    if m.syncer !== nothing && !m.busy && !isempty(get(m.config, "site", "")) &&
       (time() >= m.next_pass || isfile(connect_request_path()))
        rm(connect_request_path(); force = true)
        m.busy = true
        s, remote = m.syncer, m.remote
        TK.spawn_task!(() -> sync_pass!(s; remote), m.tq, :pass)
    end
end

function TK.update!(m::ConnectApp, e::TK.TaskEvent)
    if e.id == :tick
        refresh!(m)
    elseif e.id == :pass
        m.busy = false
        m.next_pass = time() + CONNECT_EVERY
        e.value isa Exception && tell!(m, failure_message(e.value); error = true)
        m.syncer === nothing || (m.status = status_copy(m.syncer))
    elseif e.id == :who
        e.value isa AbstractString && (m.who = e.value)
    elseif e.id == :signed_in
        if e.value isa Exception
            m.dialog = :none
            tell!(m, "Not signed in: " * failure_message(e.value); error = true)
        else
            save_connect_auth!(e.value)
            ask_path!(m)
            tell!(m, "Signed in to $(e.value["site"])")
            spawn_who!(m)
        end
    elseif e.id == :background
        if e.value isa Exception
            tell!(m, "The background service did not start: " * failure_message(e.value); error = true)
        else
            m.farewell = "zemi connect syncs in the background, from now and at every login. `zemi connect` shows how it goes; `zemi connect --stop` stops it."
            m.quit = true
        end
    end
    return nothing
end

# ── Keys ──────────────────────────────────────────────────────────────────────────────────────────

function TK.update!(m::ConnectApp, e::TK.KeyEvent)
    m.dialog == :none || return dialog_key!(m, e)
    folders = app_folders(m)
    chosen = isempty(folders) ? nothing : folders[clamp(m.selected, 1, length(folders))]
    k, c = e.key, e.char
    if k == :up
        m.selected = max(1, m.selected - 1)
    elseif k == :down
        m.selected = min(max(length(folders), 1), m.selected + 1)
    elseif k == :escape || (k == :char && c == 'q')
        m.quit = true
    elseif k == :char && c == 'a'
        isempty(get(m.config, "site", "")) ? ask!(m, :site, "Site: ", "https://") : ask_path!(m)
    elseif k == :char && c == 'd'
        chosen === nothing ? tell!(m, "No folder to remove") : (m.dialog = :remove; m.pending = Dict{String,Any}("name" => chosen["name"]))
    elseif k == :char && c == 'e'
        if chosen === nothing
            tell!(m, "No folder to change")
        else
            m.pending = Dict{String,Any}("name" => chosen["name"])
            ask!(m, :skips, "Never sent: ", join(chosen["skip"], ", "))
        end
    elseif k == :char && c == 's'
        request_pass(); m.next_pass = 0.0
        tell!(m, "Syncing now")
    elseif k == :char && c == 'p'
        paused = get(m.config, "paused", false) === true
        set_paused!(!paused)
        tell!(m, paused ? "Syncing again" : "Paused: nothing is synced until you press p again")
    elseif k == :char && c == 'o'
        site = get(m.config, "site", "")
        isempty(site) || site == "local" || open_quietly("$site/account.html")
    elseif k == :char && c == 'b'
        to_background!(m)
    end
    return nothing
end

function ask!(m::ConnectApp, dialog::Symbol, label::AbstractString, text::AbstractString = "")
    m.dialog = dialog
    m.input = TK.TextInput(; text, label, focused = true, tick = m.tick)
end
ask_path!(m::ConnectApp) = ask!(m, :add_path, "Folder: ", "~/")

function dialog_key!(m::ConnectApp, e::TK.KeyEvent)
    m.dialog == :signing_in && return (e.key == :escape && (m.dialog = :none); nothing)
    if m.dialog == :remove
        name = m.pending["name"]
        if e.key == :char && e.char in ('s', 'r')
            try
                remove_folder!(name; from_library = e.char == 'r')
                tell!(m, e.char == 'r' ? "$name: its files are removed from the library at the next pass" : "$name is no longer synced")
            catch err
                tell!(m, failure_message(err); error = true)
            end
            m.dialog = :none
        elseif e.key == :escape
            m.dialog = :none
        end
        return nothing
    end
    if e.key == :escape
        m.dialog, m.input = :none, nothing
    elseif e.key == :enter
        submit!(m, strip(TK.text(m.input)))
    elseif e.key == :tab && m.dialog == :add_path
        TK.set_text!(m.input, complete_path(TK.text(m.input)))
    else
        TK.handle_key!(m.input, e)
    end
    return nothing
end

function submit!(m::ConnectApp, value::AbstractString)
    try
        if m.dialog == :site
            site = value == "local" ? "local" : site_address(value)
            c = load_connect_config()
            c["site"] = site
            save_connect_config!(c)
            if site == "local" || get(load_connect_auth(), "site", "") == site
                ask_path!(m)
            else
                m.dialog, m.input = :signing_in, nothing
                tell!(m, "Approve zemi connect in your browser")
                TK.spawn_task!(() -> sign_in_library(site; open_browser = open_quietly), m.tq, :signed_in)
            end
        elseif m.dialog == :add_path
            dir = abspath(expanduser(value))
            isdir(dir) || error("$value is not a folder here")
            m.pending = Dict{String,Any}("path" => dir)
            ask!(m, :add_name, "Name in the library: ", basename(rstrip(dir, '/')))
        elseif m.dialog == :add_name
            f = add_folder!(m.config["site"], m.pending["path"]; name = value)
            m.dialog, m.input = :none, nothing
            request_pass()
            tell!(m, "$(f["name"]) is added; it syncs now")
        elseif m.dialog == :skips
            set_skips!(m.pending["name"], split(value, ','))
            m.dialog, m.input = :none, nothing
            tell!(m, "$(m.pending["name"]): the subfolders not sent are set")
        end
    catch err
        tell!(m, failure_message(err); error = true)
    end
end

"`text` (a path being typed) completed as far as the folders it may name agree."
function complete_path(text::AbstractString)
    full = expanduser(text)
    dir, part = endswith(full, '/') ? (full, "") : (dirname(full), basename(full))
    isdir(dir) || return text
    names = sort([n for n in readdir(dir) if startswith(n, part) && (startswith(part, ".") || !startswith(n, ".")) && isdir(joinpath(dir, n))])
    isempty(names) && return text
    common = reduce((a, b) -> String(first.(Iterators.takewhile(p -> p[1] == p[2], zip(a, b)))), names)
    done = joinpath(dir, common) * (length(names) == 1 ? "/" : "")
    return startswith(text, "~") ? contractuser(done) : done
end

"Hand the syncing to the background service, and close."
function to_background!(m::ConnectApp)
    m.syncer === nothing || (release!(m.syncer); m.syncer = nothing)
    tell!(m, "Starting the background service")
    TK.spawn_task!(start_background, m.tq, :background)
end

"Open `url` in the browser, saying nothing on the terminal the app draws on."
open_quietly(url::AbstractString) =
    try run(pipeline(Sys.isapple() ? `open $url` : Sys.iswindows() ? `cmd /c start "" $url` : `xdg-open $url`; stdout = devnull, stderr = devnull))
    catch end

"Who the site says is signed in, for the header."
function spawn_who!(m::ConnectApp)
    site = get(m.config, "site", "")
    isempty(site) && return
    TK.spawn_task!(m.tq, :who) do
        site == "local" && return something(local_user(), "")
        auth = load_connect_auth()
        get(auth, "site", "") == site || return ""
        r = HTTP.get("$site/api/library", ["Authorization" => "Bearer " * auth["access"]]; status_exception = false, connect_timeout = 10)
        r.status == 200 || return ""
        me = JSON.parse(String(r.body))["person"]
        name = String(get(me, "name", ""))
        isempty(name) ? String(get(me, "email", "")) : name
    end
end

# ── Drawing ───────────────────────────────────────────────────────────────────────────────────────

"A time as the app shows it: the time of day today, else the day and time."
function shown_time(iso_time::AbstractString)
    isempty(iso_time) && return "—"
    t = parse_iso(iso_time) + local_offset()
    Date(t) == today() ? Dates.format(t, "HH:MM:SS") : Dates.format(t, "u d HH:MM")
end

const SPINNER = ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')

function state_style(state::AbstractString)
    state in ("in step",) ? TK.tstyle(:success) : state in ("syncing", "removing", "new") ? TK.tstyle(:accent) :
        state in ("waiting", "paused") ? TK.tstyle(:warning) : TK.tstyle(:error)
end

"Who syncs, as the header says it."
function syncing_line(m::ConnectApp)
    get(m.config, "paused", false) === true && return "paused"
    m.syncer !== nothing && return m.busy ? "syncing here $(SPINNER[m.tick ÷ 6 % length(SPINNER) + 1])" : "syncing here"
    pid = syncing_pid()
    pid === nothing && return "starting"
    return background_installed() ? "the background service syncs" : "process $pid syncs"
end

function TK.view(m::ConnectApp, f::TK.Frame)
    m.tick += 1
    buf, area = f.buffer, f.area
    site = get(m.config, "site", "")
    title = "zemi connect ── " * (isempty(site) ? "no site yet" : site) * (isempty(m.who) ? "" : " ── $(m.who)") * " ── " * syncing_line(m)
    inner = TK.render(TK.Block(; title, border_style = TK.tstyle(:border), title_style = TK.tstyle(:title, bold = true)), area, buf)
    folders = app_folders(m)
    rows = TK.split_layout(TK.Layout(TK.Vertical, [TK.Fixed(max(length(folders), 1) + 4), TK.Fill(), TK.Fixed(1), TK.Fixed(1)]), inner)
    length(rows) < 4 && return
    draw_folders(m, folders, rows[1], buf)
    draw_activity(m, rows[2], buf)
    # What was last said, else what stopped the last pass, else the chosen folder's note.
    note = isempty(folders) ? "" : (f = folders[clamp(m.selected, 1, length(folders))]; isempty(f["message"]) ? "" : "$(f["name"]): $(f["message"])")
    msg, err = !isempty(m.message) ? (m.message, m.message_error) : !isempty(m.status["error"]) ? (m.status["error"], true) :
               (note, !isempty(note) && folders[clamp(m.selected, 1, length(folders))]["state"] in ("error", "missing"))
    TK.set_string!(buf, rows[3].x + 1, rows[3].y, first(msg, max(rows[3].width - 2, 0)), err ? TK.tstyle(:error) : TK.tstyle(:text))
    keys = "↑↓ folder · a add · d remove · e skipped · s sync now · p $(get(m.config, "paused", false) === true ? "resume" : "pause") · o library · b background · q quit"
    TK.set_string!(buf, rows[4].x + 1, rows[4].y, first(keys, max(rows[4].width - 2, 0)), TK.tstyle(:text_dim))
    m.dialog == :none || draw_dialog(m, inner, buf)
    return nothing
end

function draw_folders(m::ConnectApp, folders, r, buf)
    if isempty(folders)
        TK.set_string!(buf, r.x + 1, r.y + 1, "No folders yet. Press a to add one, an Obsidian vault say.", TK.tstyle(:text_dim))
        return
    end
    header = ["Folder", "State", "Files", "Changed", "Checked", "Not sent", "Path"]
    cells = [[f["name"], f["state"] == "syncing" ? "syncing $(SPINNER[m.tick ÷ 6 % length(SPINNER) + 1])" : f["state"],
              string(f["files"]), shown_time(f["changed"]), shown_time(f["checked"]),
              isempty(f["skip"]) ? "—" : join(f["skip"], ", "), f["path"]]
             for f in folders]
    TK.render(TK.Table(header, cells; block = TK.Block(; title = "Folders"), selected = clamp(m.selected, 1, length(folders)),
                       row_styles = [state_style(f["state"]) for f in folders]), r, buf)
end

function draw_activity(m::ConnectApp, r, buf)
    inner = TK.render(TK.Block(; title = "Activity"), r, buf)
    lines = m.status["activity"]
    shown = lines[max(1, end - inner.height + 1):end]
    isempty(shown) && TK.set_string!(buf, inner.x + 1, inner.y, "Nothing moved yet.", TK.tstyle(:text_dim))
    wide = maximum((length(e["folder"]) for e in shown); init = 0)
    for (i, e) in enumerate(shown)
        style = e["what"] == "error" ? TK.tstyle(:error) : e["what"] == "waits" ? TK.tstyle(:warning) : TK.tstyle(:text)
        line = rpad(shown_time(e["at"]), 9) * rpad(e["folder"], wide + 2) * rpad(e["what"], 15) * e["path"]
        TK.set_string!(buf, inner.x + 1, inner.y + i - 1, first(line, max(inner.width - 2, 0)), style)
    end
end

const DIALOG_TITLES = Dict(:site => "The knowledge base to sync with", :signing_in => "Signing in", :add_path => "Add a folder",
                           :add_name => "Its name in your library", :skips => "Subfolders never sent", :remove => "Remove a folder")
const DIALOG_HINTS = Dict(
    :site => "Its address, as https://kb.example.org (local: the one run on this machine). Enter signs in. Esc cancels.",
    :signing_in => "Approve zemi connect in your browser. Esc stops waiting here.",
    :add_path => "A folder on this machine, an Obsidian vault say. Tab completes. Enter goes on. Esc cancels.",
    :add_name => "The folder it is in your library. Enter adds it. Esc cancels.",
    :skips => "Subfolders, separated by commas, that never leave this machine. Enter saves. Esc cancels.",
)

function draw_dialog(m::ConnectApp, area, buf)
    w, h = min(area.width - 4, 76), 7
    r = TK.center(area, w, h)
    for y in r.y:r.y+h-1, x in r.x:r.x+w-1
        TK.set_char!(buf, x, y, ' ', TK.tstyle(:text))
    end
    inner = TK.render(TK.Block(; title = DIALOG_TITLES[m.dialog], border_style = TK.tstyle(:accent), box = TK.BOX_ROUNDED), r, buf)
    if m.dialog == :remove
        name = m.pending["name"]
        TK.set_string!(buf, inner.x + 1, inner.y, "Stop syncing $name?", TK.tstyle(:text, bold = true))
        TK.set_string!(buf, inner.x + 1, inner.y + 2, "s  stop syncing it; its files stay in your library", TK.tstyle(:text))
        TK.set_string!(buf, inner.x + 1, inner.y + 3, "r  also remove its files from your library", TK.tstyle(:warning))
        TK.set_string!(buf, inner.x + 1, inner.y + 4, "Esc  keep it. The folder on this machine is left as it is.", TK.tstyle(:text_dim))
        return
    end
    m.input === nothing || (m.input.tick = m.tick; TK.render(m.input, TK.Rect(inner.x + 1, inner.y + 1, inner.width - 2, 1), buf))
    hint = DIALOG_HINTS[m.dialog]
    for (i, line) in enumerate(wrap_words(hint, inner.width - 2))
        i > 2 && break
        TK.set_string!(buf, inner.x + 1, inner.y + 2 + i, line, TK.tstyle(:text_dim))
    end
end

"`text` broken into lines of at most `width` characters, at spaces."
function wrap_words(text::AbstractString, width::Integer)
    lines, line = String[], ""
    for w in split(text)
        if isempty(line)
            line = String(w)
        elseif length(line) + 1 + length(w) <= width
            line *= " " * w
        else
            push!(lines, line); line = String(w)
        end
    end
    isempty(line) || push!(lines, line)
    return lines
end

# ── Running it ────────────────────────────────────────────────────────────────────────────────────

"""
    run_connect_app() -> Int

The app, until it is closed: it syncs while open unless another process does, and says afterwards
what syncs now.
"""
function run_connect_app()
    m = ConnectApp()
    refresh!(m)
    spawn_who!(m)
    timer = TK.spawn_timer!(m.tq, :tick, 0.5; repeat = true)
    try
        TK.app(m; fps = 20)
    finally
        TK.cancel!(timer)
        m.syncer === nothing || release!(m.syncer)
    end
    if !isempty(m.farewell)
        say(:ok, m.farewell)
    elseif syncing_pid() === nothing
        say(:info, "zemi connect stopped syncing", "`zemi connect --background` syncs from every login")
    end
    return 0
end

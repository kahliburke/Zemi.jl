# `zemi connect` on a terminal: an app (Tachikoma) that shows the folders kept in step with one's
# library, how each stands and what moved lately, and manages them: adding and removing folders,
# setting what of each never leaves this machine, syncing now, pausing, and handing the syncing to
# the background service. It syncs itself when no other process does (see connect_service.jl);
# while the background service does, it shows the service's status and changes the folder list the
# service reads.
#
#   ↑/↓ choose a folder · a add · d remove · e what of it syncs · s sync now · p pause · o the
#   library's page · b background · q quit. The mouse resizes the panes and the table's columns,
#   sorts by a column, and scrolls the activity.

import Tachikoma as TK

@kwdef mutable struct ConnectApp <: TK.Model
    quit::Bool = false
    tick::Int = 0
    tq::TK.TaskQueue = TK.TaskQueue()
    syncer::Union{Syncer,Nothing} = nothing
    remote::Union{LibraryRemote,Nothing} = nothing   # the library, when not the config's site (tests)
    status::Dict{String,Any} = empty_status()
    config::Dict{String,Any} = Dict{String,Any}()
    layout::TK.ResizableLayout = TK.ResizableLayout(TK.Vertical, [TK.Fixed(9), TK.Fill()]; min_pane_size = 5)  # the folders over the activity
    table::TK.DataTable = TK.DataTable(TK.DataColumn[]; block = TK.Block(; title = "Folders"))
    activity::TK.ScrollPane = TK.ScrollPane(Vector{TK.Span}[]; following = true, block = TK.Block(; title = "Activity"))
    activity_shown::Tuple{Int,String} = (0, "")      # the activity in the pane: how much, and the latest's time
    busy::Bool = false                                # a pass of this process's runs
    next_pass::Float64 = 0.0
    who::String = ""                                  # who is signed in
    dialog::Symbol = :none                            # :site, :signing_in, :add_path, :add_name, :choose, :remove
    chooser::Any = nothing                            # what of a folder syncs, as it is chosen (see `Chooser`)
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
    show_status!(m)
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
        m.syncer === nothing || (m.status = status_copy(m.syncer); show_status!(m))
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

# ── Keys and the mouse ────────────────────────────────────────────────────────────────────────────

function TK.update!(m::ConnectApp, e::TK.MouseEvent)
    m.dialog == :choose && return (TK.handle_mouse!(m.chooser.tree, e); nothing)
    m.dialog == :none || return nothing
    TK.handle_resize!(m.layout, e) || TK.handle_mouse!(m.table, e) || TK.handle_mouse!(m.activity, e)
    return nothing
end

"The folder chosen in the table (its row, through the table's sort), or `nothing`."
function chosen_folder(m::ConnectApp)
    folders, t = app_folders(m), m.table
    1 <= t.selected <= length(t.sort_perm) || return nothing
    i = t.sort_perm[t.selected]
    return i <= length(folders) ? folders[i] : nothing
end

const TABLE_KEYS = (:up, :down, :pageup, :pagedown, :home, :end_key, :left, :right)

function TK.update!(m::ConnectApp, e::TK.KeyEvent)
    m.dialog == :none || return dialog_key!(m, e)
    chosen = chosen_folder(m)
    k, c = e.key, e.char
    if k in TABLE_KEYS
        TK.handle_key!(m.table, e)
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
            dir = abspath(expanduser(chosen["path"]))
            isdir(dir) ? (m.chooser = Chooser(chosen["name"], dir, chosen["skip"]); m.dialog = :choose) :
                         tell!(m, "$(chosen["path"]) is not a folder here"; error = true)
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
    m.dialog == :choose && return choose_key!(m, e)
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

# ── Choosing what syncs ───────────────────────────────────────────────────────────────────────────

"""
    Chooser(name, dir, skip)

The files and folders of folder `dir` as a tree, each marked as syncing or not, for choosing what
never leaves this machine (the folder's `skip`: paths of subfolders or files, see
[`folder_files`](@ref)). A folder some of whose contents do not sync is marked as partly synced.
"""
mutable struct Chooser
    name::String
    dir::String
    skip::Set{String}
    tree::TK.TreeView
end

function Chooser(name::AbstractString, dir::AbstractString, skip)
    root = TK.TreeNode(String(name); children = tree_nodes(dir, ""), expanded = true, content = "")
    c = Chooser(String(name), String(dir), Set{String}(String.(skip)), TK.TreeView(root; selected = 1, focused = true))
    mark!(c)
    return c
end

# The entries of folder `rel` in `dir`, folders first: hidden ones are never sent and are left out.
function tree_nodes(dir::AbstractString, rel::AbstractString)
    here = isempty(rel) ? dir : joinpath(dir, split(rel, '/')...)
    names = sort([n for n in readdir(here) if !startswith(n, ".") && !islink(joinpath(here, n))];
                 by = n -> (!isdir(joinpath(here, n)), lowercase(n)))
    map(names) do n
        p = vault_path(isempty(rel) ? n : rel * "/" * n)
        isdir(joinpath(here, n)) ? TK.TreeNode(n; children = tree_nodes(dir, p), expanded = false, content = p) : TK.TreeNode(n; content = p)
    end
end

"Whether `p` is left out: it, or a folder it is in, never leaves this machine."
left_out(c::Chooser, p::AbstractString) = !isempty(p) && any(s -> in_folder(p, s), c.skip)

# Each node's mark and style: syncing ([✓]), partly ([-]: something in it does not) or not ([ ]).
function mark!(c::Chooser, node::TK.TreeNode = c.tree.root)
    p, name = node.content, replace(node.label, r"^\[.\] " => "")
    out = left_out(c, p)
    partly = !out && any(s -> s != p && (isempty(p) || in_folder(s, p)), c.skip)
    node.label = (out ? "[ ] " : partly ? "[-] " : "[✓] ") * name
    node.style = out ? TK.tstyle(:text_dim) : partly ? TK.tstyle(:warning) : TK.tstyle(:text)
    foreach(n -> mark!(c, n), node.children)
    node === c.tree.root && TK._invalidate_flat!(c.tree)
end

"Switch the chosen file or folder between syncing and not; `nothing`, or why it cannot be."
function toggle!(c::Chooser)
    node = TK.selected_node(c.tree)
    node === nothing && return nothing
    p = node.content
    isempty(p) && return "The folder itself syncs: remove it to stop"
    if p in c.skip
        delete!(c.skip, p)
    elseif left_out(c, p)
        return "$(first(s for s in c.skip if in_folder(p, s))) does not sync: switch it on first"
    else
        filter!(s -> !in_folder(s, p), c.skip)          # what was left out inside it is now left out with it
        push!(c.skip, p)
    end
    mark!(c)
    return nothing
end

function choose_key!(m::ConnectApp, e::TK.KeyEvent)
    c = m.chooser
    if e.key == :escape
        m.dialog, m.chooser = :none, nothing
    elseif e.key == :enter
        try
            set_skips!(c.name, sort!(collect(c.skip)))
            tell!(m, isempty(c.skip) ? "$(c.name): everything syncs" : "$(c.name): $(length(c.skip)) left on this machine")
        catch err
            tell!(m, failure_message(err); error = true)
        end
        m.dialog, m.chooser = :none, nothing
    elseif e.key == :char && e.char == ' '
        why = toggle!(c)
        why === nothing || tell!(m, why; error = true)
    else
        TK.handle_key!(c.tree, e)
    end
    return nothing
end

function draw_chooser(c::Chooser, inner, buf)
    rows = TK.split_layout(TK.Layout(TK.Vertical, [TK.Fill(), TK.Fixed(1)]), inner)
    length(rows) < 2 && return
    c.tree.tick = nothing
    TK.render(c.tree, rows[1], buf)
    TK.render(TK.Paragraph("space syncs or not · → ← open and close · Enter saves · Esc cancels"; style = TK.tstyle(:text_dim)), rows[2], buf)
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

"The table's columns for `folders`."
function folder_columns(m::ConnectApp, folders)
    spin = SPINNER[m.tick ÷ 6 % length(SPINNER) + 1]
    state(f) = TK.Span(f["state"] == "syncing" ? "syncing $spin" : f["state"], state_style(f["state"]))
    return [TK.DataColumn("Folder", [f["name"] for f in folders]),
            TK.DataColumn("State", [state(f) for f in folders]),
            TK.DataColumn("Files", [f["files"] for f in folders]; align = TK.col_right),
            TK.DataColumn("Changed", [shown_time(f["changed"]) for f in folders]),
            TK.DataColumn("Checked", [shown_time(f["checked"]) for f in folders]),
            TK.DataColumn("Not sent", [isempty(f["skip"]) ? "—" : join(f["skip"], ", ") for f in folders]),
            TK.DataColumn("Path", [f["path"] for f in folders])]
end

"Put the status in the table and the activity pane, keeping the table's sort, choice and column widths."
function show_status!(m::ConnectApp)
    folders, t = app_folders(m), m.table
    t.columns = folder_columns(m, folders)
    n = length(folders)
    t.sort_perm = t.sort_col == 0 || t.sort_dir == TK.sort_none ? collect(1:n) :
                  sortperm([(v = t.columns[t.sort_col].values[i]; v isa TK.Span ? v.content : string(v)) for i in 1:n];
                           rev = t.sort_dir == TK.sort_desc)
    t.selected = n == 0 ? 0 : clamp(max(t.selected, 1), 1, n)
    acts = m.status["activity"]
    shown = (length(acts), isempty(acts) ? "" : acts[end]["at"])
    shown == m.activity_shown && return
    m.activity_shown = shown
    wide = maximum((length(e["folder"]) for e in acts); init = 0)
    TK.set_content!(m.activity, isempty(acts) ? [[TK.Span("Nothing moved yet.", TK.tstyle(:text_dim))]] :
                                                [activity_spans(e, wide) for e in acts])
end

function activity_spans(e, wide::Integer)
    what = e["what"] == "error" ? TK.tstyle(:error) : e["what"] == "waits" ? TK.tstyle(:warning) : TK.tstyle(:success)
    return [TK.Span(rpad(shown_time(e["at"]), 10), TK.tstyle(:text_dim)), TK.Span(rpad(e["folder"], wide + 2), TK.tstyle(:accent)),
            TK.Span(rpad(e["what"], 15), what), TK.Span(e["path"], TK.tstyle(:text))]
end

function TK.view(m::ConnectApp, f::TK.Frame)
    m.tick += 1
    buf, area = f.buffer, f.area
    site = get(m.config, "site", "")
    title = "zemi connect ── " * (isempty(site) ? "no site yet" : site) * (isempty(m.who) ? "" : " ── $(m.who)") * " ── " * syncing_line(m)
    inner = TK.render(TK.Block(; title = first(title, max(area.width - 6, 0)), border_style = TK.tstyle(:border),
                               title_style = TK.tstyle(:title, bold = true)), area, buf)
    rows = TK.split_layout(TK.Layout(TK.Vertical, [TK.Fill(), TK.Fixed(1), TK.Fixed(1)]), inner)
    length(rows) < 3 && return
    panes = TK.split_layout(m.layout, rows[1])
    if length(panes) == 2
        if isempty(m.table.sort_perm)
            r = TK.render(TK.Block(; title = "Folders"), panes[1], buf)
            TK.render(TK.Paragraph("No folders yet. Press a to add one, an Obsidian vault say."; style = TK.tstyle(:text_dim)), r, buf)
        else
            m.table.tick = m.tick
            TK.render(m.table, panes[1], buf)
        end
        m.activity.tick = m.tick
        TK.render(m.activity, panes[2], buf)
        TK.render_resize_handles!(buf, m.layout)
    end
    # What was last said, else what stopped the last pass, else the chosen folder's note.
    c = chosen_folder(m)
    note = c === nothing || isempty(c["message"]) ? "" : "$(c["name"]): $(c["message"])"
    msg, err = !isempty(m.message) ? (m.message, m.message_error) : !isempty(m.status["error"]) ? (m.status["error"], true) :
               (note, c !== nothing && c["state"] in ("error", "missing"))
    TK.render(TK.Paragraph(msg; style = err ? TK.tstyle(:error) : TK.tstyle(:text)), rows[2], buf)
    paused = get(m.config, "paused", false) === true
    keys = "a add · d remove · e what syncs · s sync now · p $(paused ? "resume" : "pause") · o library · b background · q quit"
    TK.render(TK.StatusBar(; left = [TK.Span(" " * keys, TK.tstyle(:text_dim))]), rows[3], buf)
    m.dialog == :none || draw_dialog(m, inner, buf)
    return nothing
end

const DIALOG_TITLES = Dict(:site => "The knowledge base to sync with", :signing_in => "Signing in", :add_path => "Add a folder",
                           :add_name => "Its name in your library", :choose => "What syncs", :remove => "Remove a folder")
const DIALOG_HINTS = Dict(
    :site => "Its address, as https://kb.example.org (local: the one run on this machine). Enter signs in. Esc cancels.",
    :signing_in => "Approve zemi connect in your browser. Esc stops waiting here.",
    :add_path => "A folder on this machine, an Obsidian vault say. Tab completes. Enter goes on. Esc cancels.",
    :add_name => "The folder it is in your library. Enter adds it. Esc cancels.",
)

function draw_dialog(m::ConnectApp, area, buf)
    w, h = m.dialog == :choose ? (min(area.width - 2, 90), area.height - 2) : (min(area.width - 2, 76), min(area.height - 2, 8))
    (w < 20 || h < 5) && return
    r = TK.center(area, w, h)
    for y in r.y:TK.bottom(r), x in r.x:TK.right(r)
        TK.set_char!(buf, x, y, ' ', TK.tstyle(:text))
    end
    inner = TK.render(TK.Block(; title = DIALOG_TITLES[m.dialog], border_style = TK.tstyle(:accent), box = TK.BOX_ROUNDED), r, buf)
    m.dialog == :choose && return draw_chooser(m.chooser, inner, buf)
    line(i, text, style) = i < inner.height && TK.render(TK.Paragraph(text; style), TK.Rect(inner.x + 1, inner.y + i, inner.width - 2, 1), buf)
    if m.dialog == :remove
        name = m.pending["name"]
        line(0, "Stop syncing $name?", TK.tstyle(:text, bold = true))
        line(2, "s    stop syncing it; its files stay in your library", TK.tstyle(:text))
        line(3, "r    also remove its files from your library", TK.tstyle(:warning))
        line(4, "Esc  keep it. The folder on this machine is left as it is.", TK.tstyle(:text_dim))
        return
    end
    m.input === nothing || (m.input.tick = m.tick; TK.render(m.input, TK.Rect(inner.x + 1, inner.y + 1, inner.width - 2, 1), buf))
    inner.height > 3 && TK.render(TK.Paragraph(DIALOG_HINTS[m.dialog]; style = TK.tstyle(:text_dim), wrap = TK.word_wrap),
                                  TK.Rect(inner.x + 1, inner.y + 3, inner.width - 2, inner.height - 3), buf)
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

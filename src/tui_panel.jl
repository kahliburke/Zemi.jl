# Zemi's panel in Kaimon's Extensions tab ([u] on the extension; see kaimon.toml). It runs in
# Kaimon's process: what it shows comes from the extension, pushed every two seconds
# (`Zemi.hosted_status`, see hosted.jl), and what it does runs there through `ctx.eval`.
#
#   ↑/↓ choose a setting · Enter changes it (a choice or a switch flips; a value is typed, Enter
#   saves, ↑/↓ leaves it as it was) · o opens the site · b builds it again · r restarts with the
#   settings changed · Esc closes the panel.

using Tachikoma

mutable struct ZemiPanel
    ctx::Any
    status::Dict{String,Any}
    selected::Int
    editing::Any                 # the setting's text being typed, or nothing
    message::String
    changed::Bool                # a setting changed since the last restart
    busy::Bool
end

init(ctx) = ZemiPanel(ctx, Dict{String,Any}(), 1, nothing, "", false, false)

function update!(p::ZemiPanel, ctx)
    ps = get(ctx._cache, :panel_state, nothing)
    ps === nothing || (s = get(ps, "status", nothing)) === nothing || (p.status = s)
end

settings(p) = get(p.status, "settings", Any[])

# Run `code` in the extension, off the frame; `done(value)` with what it returned, or the message
# says what went wrong.
function remote!(p::ZemiPanel, code::String, what::String; done = v -> nothing)
    p.busy && return
    p.busy = true
    p.message = what * "…"
    @async try
        r = p.ctx.eval(code)
        err = get(r, :exception, nothing)
        if err !== nothing && !isempty(string(err))
            p.message = "Failed: " * first(replace(string(err), r"\s+" => " "), 300)
        elseif !isempty(get(r, :stderr, ""))
            p.message = first(replace(r.stderr, r"\s+" => " "), 300)
        else
            p.message = ""
            done(get(r, :value_repr, ""))
        end
    catch e
        p.message = "Failed: " * sprint(showerror, e)
    finally
        p.busy = false
    end
end

function save!(p::ZemiPanel, key::String, value)
    remote!(p, "Zemi.set_machine_setting!($(repr(key)), $(repr(value))); nothing", "Saving";
            done = _ -> (p.changed = true; p.message = "Saved: [r] restarts Zemi with it"))
end

function restart!(p::ZemiPanel)
    remote!(p, "Zemi.restart!(); nothing", "Restarting"; done = _ -> (p.changed = false; p.message = "Restarting"))
end

function handle_key!(p::ZemiPanel, evt::Tachikoma.KeyEvent)::Bool
    s = settings(p)
    if p.editing !== nothing
        if evt.key == :enter
            key = s[p.selected]["key"]
            text = strip(Tachikoma.text(p.editing))
            p.editing = nothing
            save!(p, key, text)
        elseif evt.key in (:up, :down)
            p.editing = nothing
        else
            Tachikoma.handle_key!(p.editing, evt)
        end
        return true
    end
    if evt.key == :up
        p.selected = max(1, p.selected - 1)
    elseif evt.key == :down
        p.selected = min(max(length(s), 1), p.selected + 1)
    elseif evt.key == :enter && !isempty(s)
        x = s[p.selected]
        if x["kind"] == "bool"
            save!(p, x["key"], !x["value"])
        elseif x["kind"] == "choice"
            cs = x["choices"]
            i = something(findfirst(==(x["value"]), cs), 0)
            save!(p, x["key"], cs[mod1(i + 1, length(cs))])
        else
            p.editing = Tachikoma.TextInput(text = string(x["value"]), label = "", focused = true, tick = p.ctx.tick)
        end
    elseif evt.key == :char && evt.char == 'o'
        remote!(p, "Zemi.open_hosted()", "Opening"; done = v -> (p.message = "Opened $(strip(v, '"'))"))
    elseif evt.key == :char && evt.char == 'b'
        remote!(p, "Zemi.rebuild!()", "Asking for a build"; done = _ -> (p.message = "The site builds again in a moment"))
    elseif evt.key == :char && evt.char == 'r'
        restart!(p)
    else
        return false
    end
    return true
end

const STATE_STYLE = Dict("running" => :success, "starting" => :warning, "stopping" => :warning, "failed" => :error, "stopped" => :text_dim)

function view(p::ZemiPanel, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    keys = " ↑↓ choose · Enter change · [o]pen · [b]uild · [r]estart · Esc close "
    inner = Tachikoma.render(Tachikoma.Block(title = " Zemi ", title_right = keys, border_style = Tachikoma.tstyle(:border_focus)), area, buf)
    x, y, w = inner.x, inner.y, inner.width
    line!(text, style = :text; dx = 0) = (y <= Tachikoma.bottom(inner) && Tachikoma.set_string!(buf, x + dx, y, first(text, max(w - dx, 0)), Tachikoma.tstyle(style)); y += 1)
    st = p.status
    if isempty(st)
        line!("Waiting for Zemi to report…", :text_dim)
        return
    end
    state = get(st, "state", "")
    url = get(st, "url", "")
    line!("● " * state * (isempty(url) ? "" : " · $(get(st, "mode", "")) · $url"), get(STATE_STYLE, state, :text))
    err = get(st, "error", "")
    isempty(err) || line!(err, :error)
    get(st, "building", false) ? line!("The site is building", :warning) :
        line!("Site: " * (isempty(get(st, "built", "")) ? "not built yet" : "built $(st["built"])"), :text_dim)
    line!("Config: $(get(st, "config", ""))  ·  panel's settings: $(basename(get(st, "settings_file", "")))", :text_dim)
    y += 1
    line!(p.changed ? "Settings  (changed: [r] restarts Zemi with them)" : "Settings", p.changed ? :warning : :accent)
    s = settings(p)
    for (i, item) in enumerate(s)
        y > Tachikoma.bottom(inner) && break
        on = i == p.selected
        v = item["kind"] == "bool" ? (item["value"] ? "on" : "off") : string(item["value"])
        Tachikoma.set_string!(buf, x, y, on ? "›" : " ", Tachikoma.tstyle(:accent))
        Tachikoma.set_string!(buf, x + 2, y, rpad(item["label"], 18), Tachikoma.tstyle(on ? :accent : :text))
        if on && p.editing !== nothing
            Tachikoma.render(p.editing, Tachikoma.Rect(x + 21, y, max(w - 21, 1), 1), buf)
        else
            Tachikoma.set_string!(buf, x + 21, y, first(isempty(v) ? "—" : v, max(w - 21, 0)), Tachikoma.tstyle(on ? :text : :text_dim))
        end
        y += 1
    end
    y += 1
    if !isempty(s) && p.selected <= length(s)
        line!(s[p.selected]["help"], :text_dim)
    end
    isempty(p.message) || line!(p.message, startswith(p.message, "Failed") ? :error : :accent)
end

cleanup!(p::ZemiPanel, ctx) = nothing

# The guide's picture of `zemi connect`'s app (guide/src/assets/connect-app.png): the app drawn as it
# shows two folders in step and the files it moved, its cells drawn in a monospaced font at twice
# the pixels: `julia demo/connect_app.jl`. It makes an environment of its own, with the font
# packages Tachikoma draws images with.

using Pkg
Pkg.activate(; temp = true, io = devnull)
Pkg.develop(path = dirname(@__DIR__); io = devnull)
Pkg.add(["Tachikoma", "FreeTypeAbstraction", "ColorTypes"]; io = devnull)

using Zemi, Dates, FreeTypeAbstraction, ColorTypes
import Tachikoma as TK
const K = Zemi

const OUT = joinpath(dirname(@__DIR__), "guide", "src", "assets", "connect-app.png")
const W, H = 100, 19

"The app's screen at a quarter to six, as Rowan's machine keeps their field notes and papers in step."
function connect_screen()
    base = DateTime(2026, 11, 14, 17, 42) - K.local_offset()
    at(minutes) = K.iso(base - Minute(minutes))
    folder(name, path, files, changed) = Dict{String,Any}("name" => name, "path" => path, "state" => "in step", "files" => files,
                                                          "message" => "", "checked" => at(0), "changed" => at(changed))
    m = K.ConnectApp()
    m.config = Dict{String,Any}("site" => "https://kb.example.org", "folders" => Any[
        Dict{String,Any}("name" => "Field notes", "path" => "~/Documents/Obsidian/Field notes", "skip" => ["Private"]),
        Dict{String,Any}("name" => "Papers", "path" => "~/Documents/Papers", "skip" => String[])])
    st = K.empty_status()
    st["site"] = "https://kb.example.org"
    st["folders"] = Any[folder("Field notes", "~/Documents/Obsidian/Field notes", 214, 3), folder("Papers", "~/Documents/Papers", 37, 60 * 26)]
    st["activity"] = Any[Dict{String,Any}("at" => at(t), "folder" => f, "what" => w, "path" => p) for (t, f, w, p) in [
        (41, "Papers", "sent", "Larval settlement on ridged tiles.pdf"),
        (12, "Field notes", "received", "Sites/North channel.md"),
        (9, "Field notes", "sent", "Methods/Scoring turf.md"),
        (3, "Field notes", "sent", "Daily/2026-11-14.md")]]
    m.status = st
    m.syncer = K.Syncer(nothing, st, ReentrantLock(), e -> nothing)       # synced here, as the header says
    m.who = "Rowan (rowan@example.org)"
    K.show_status!(m)
    tb = TK.TestBackend(W, H)
    TK.view(m, TK.Frame(tb.buf, TK.Rect(1, 1, W, H), TK.GraphicsRegion[], TK.PixelSnapshot[]))
    return copy(tb.buf.content)
end

"A monospaced font here, the first of those a terminal is likely to use."
function mono_font()
    fonts = TK.discover_mono_fonts()
    for name in ["MesloLGS Nerd Font Mono", "MesloLGM Nerd Font Mono", "JetBrains Mono", "Menlo", "DejaVu Sans Mono"]
        key = lowercase(replace(name, " " => ""))
        i = findfirst(f -> occursin(key, lowercase(replace(f.name, " " => ""))), fonts)
        i === nothing || return fonts[i].path
    end
    i = findfirst(f -> !isempty(f.path), fonts)
    i === nothing ? error("No monospaced font found") : fonts[i].path
end

TK.enable_gif()
# One frame: a still PNG.
Base.invokelatest(TK.export_apng_from_snapshots, OUT, W, H, [connect_screen()], [0.0];
                  font_path = mono_font(), cell_w = 20, cell_h = 40, font_size = 32)
K.PNGFiles.save(OUT, K.PNGFiles.load(OUT))                              # compressed, which the export is not
println(OUT)

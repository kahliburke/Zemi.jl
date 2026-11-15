# The guide's picture of `zemi connect`'s app (guide/src/assets/connect-app.svg): the app drawn as it
# shows two folders in step and the files it moved, written as an SVG of the terminal's screen.
# `julia --project=. demo/connect_app.jl`.

using Zemi, Dates
import Tachikoma as TK
const K = Zemi

const OUT = joinpath(dirname(@__DIR__), "guide", "src", "assets", "connect-app.svg")
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

# One frame, always shown, with a margin around the screen.
TK.export_svg(OUT, W, H, [connect_screen()], [0.0])
svg = read(OUT, String)
w, h = 8W, 16H
svg = replace(svg, "<g visibility=\"hidden\">" => "<g>", r"\n\s*<animate attributeName=\"visibility\"[^\n]*" => "",
              "width=\"$w\" height=\"$h\" viewBox=\"0 0 $w $h\"" => "width=\"$(w + 32)\" height=\"$(h + 32)\" viewBox=\"-16 -16 $(w + 32) $(h + 32)\"",
              "<rect width=\"$w\" height=\"$h\" fill=\"#" => "<rect x=\"-16\" y=\"-16\" width=\"$(w + 32)\" height=\"$(h + 32)\" rx=\"10\" fill=\"#")
write(OUT, svg)
println(OUT)

# What the zemi app says in a terminal: a headline marked and in bold, its lines indented under it,
# and the addresses, commands and paths in colour. Plain text where the output is not a terminal (a
# log, a pipe) or `NO_COLOR` is set.

"`io` with colour where it is a terminal and `NO_COLOR` is not set."
term(io::IO = stderr) = IOContext(io, :color => get(io, :color, false) && isempty(get(ENV, "NO_COLOR", "")))

const MARKS = Dict(:ok => ("✓", :green), :info => ("●", :cyan), :warn => ("!", :yellow), :error => ("✗", :red))

"A headline: its mark (`:ok`, `:info`, `:warn` or `:error`) in its colour, and the text in bold."
function headline(io::IO, kind::Symbol, text::AbstractString)
    mark, color = MARKS[kind]
    printstyled(io, mark, " "; color, bold = true)
    printstyled(io, text, "\n"; bold = true)
end

"""
A line under the headline. Parts in backquotes are shown in colour, without the quotes: a command, an
address or a path to act on.
"""
function say_line(io::IO, text::AbstractString = "")
    isempty(text) && return println(io)
    print(io, "  ")
    for (i, part) in enumerate(split(text, '`'))
        iseven(i) ? printstyled(io, part; color = :cyan) : print(io, part)
    end
    println(io)
end

"A labelled value under the headline, the labels lined up, the value in colour, with a note after it."
function say_field(io::IO, label::AbstractString, value::AbstractString, note::AbstractString = "")
    print(io, "  ", rpad(label, 12))
    printstyled(io, value; color = :cyan)
    isempty(note) || printstyled(io, "   ", note; color = :light_black)
    println(io)
end

"A message: a headline and its lines (`\"\"` for a blank one, a pair for a labelled value), to stderr."
function say(kind::Symbol, title::AbstractString, lines...; io::IO = stderr)
    t = term(io)
    headline(t, kind, title)
    for l in lines
        l isa Tuple ? say_field(t, l...) : say_line(t, l)
    end
    return nothing
end

# Text escaped for what the site's pages are made of: Markdown, raw HTML, YAML front matter and
# fenced code.

# Text from arXiv and the LLM goes into Markdown that Documenter parses and VitePress compiles as a
# Vue template, so the characters either of them would act on are escaped. Mathematics is kept as
# math: `$ … $`, `$$ … $$` (as abstracts write it), `\( … \)` and `\[ … \]` (as LLMs write it) all
# become inline math, unescaped.
const MATH_SPAN = r"\$\$.+?\$\$|\$[^$\n]+?\$"s
# With `code`, `code spans` are kept as code too: for text an LLM wrote about code, where a backtick
# marks a name. Not for abstracts, which quote `like this' as LaTeX does.
const CODE_SPAN = r"`[^`\n]+`"

function md_escape(s::AbstractString; code::Bool = false)
    # A list item with another bullet is a list item still: only `-` survives the escaping.
    s = replace(s, r"(?m)^(\s*)[*+](?=\s)" => s"\1-")
    code || return no_braces_paired(md_escape_prose(s))
    io = IOBuffer()
    last = 1
    for m in eachmatch(CODE_SPAN, s)
        print(io, md_escape_prose(s[last:prevind(s, m.offset)]))
        print(io, replace(m.match, "{{" => "{ {", "}}" => "} }"))
        last = m.offset + ncodeunits(m.match)
    end
    print(io, md_escape_prose(s[last:end]))
    return no_braces_paired(String(take!(io)))
end

# Escaped a piece at a time, text can still end with one brace and the next piece start with another:
# decoded, the two are Vue's `{{`. So any pair left in the whole, as characters or references, is split.
no_braces_paired(s::AbstractString) =
    replace(s, r"(\{|&#123;)(?=\{|&#123;)" => s"\1 ", r"(\}|&#125;)(?=\}|&#125;)" => s"\1 ")

function md_escape_prose(s::AbstractString)
    s = replace(s, r"\\\((.+?)\\\)"s => s"$\1$", r"\\\[(.+?)\\\]"s => s"$$\1$$")
    io = IOBuffer()
    last = 1
    for m in eachmatch(MATH_SPAN, s)
        print(io, escape_text(s[last:prevind(s, m.offset)]))
        # Double backticks are Julia Markdown's own inline math, so no `$` is left for it to pair up
        # differently (abstracts also use `$` for dollars).
        math = strip(strip(m.match, '$'))
        print(io, isempty(math) ? escape_text(m.match) : "``" * replace(math, "{{" => "{ {", "}}" => "} }") * "``")
        last = m.offset + ncodeunits(m.match)
    end
    print(io, escape_text(s[last:end]))
    return String(take!(io))
end

# Characters Markdown would act on, as HTML character references. Backslash escapes do not survive:
# Documenter parses them away and writes the bare character back into the Markdown VitePress reads.
const MD_ENTITIES = Dict('\\' => "&#92;", '`' => "&#96;", '*' => "&#42;", '_' => "&#95;", '[' => "&#91;",
                         ']' => "&#93;", '<' => "&lt;", '>' => "&gt;", '#' => "&#35;", '|' => "&#124;",
                         '$' => "&#36;", '{' => "&#123;", '}' => "&#125;")

# `{{` would still reach the page as Vue interpolation once the references are decoded, so it is split.
# A line starting with `=` would open a tab inside a `:::` block or underline a heading, and one
# starting with `:::` would close the block, so those characters are escaped at the start of a line.
escape_text(s::AbstractString) =
    replace(join(get(MD_ENTITIES, c, string(c)) for c in replace(s, "{{" => "{ {", "}}" => "} }")),
            r"^(\s*)="m => s"\1&#61;", r"^(\s*):"m => s"\1&#58;")

# Text going into raw HTML: escaped, with braces as references so Vue sees no interpolation.
html_escape(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;", "{" => "&#123;", "}" => "&#125;")

"A YAML string, quoted, for a page's front matter."
yaml_string(s::AbstractString) = JSON.json(String(s))

"""
A fenced code block long enough that no run of backticks in `code` closes it. The docs build writes
it out again with [`plain_code`](@ref), which keeps it that long.
"""
function fenced(code::AbstractString, language::AbstractString)
    longest = maximum((length(m.match) for m in eachmatch(r"`+", code)); init = 0)
    fence = "`"^max(3, longest + 1)
    return "$fence$language\n$code\n$fence\n"
end

"""
    plain_code(io, language, code)

A code block written as Markdown, its fence longer than any run of backticks in `code`, wherever the
run is. Julia's own writer (`Markdown.plain`) counts only runs at the start of a line, so a line
indented by a few spaces could close the block, and what follows it would reach the page as HTML.
The docs build writes code blocks with this (see docs/make.jl).
"""
function plain_code(io::IO, language::AbstractString, code::AbstractString)
    n = max(3, maximum((length(m.match) for m in eachmatch(r"`+", code)); init = 0) + 1)
    println(io, "`"^n, language)
    println(io, code)
    println(io, "`"^n)
end

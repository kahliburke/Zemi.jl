# A plugin for the tests: one source, `zz-folder`, that reads each Markdown file in the folder its
# settings name (`[sources.zz-folder] folder`) as a record, keyed by the file's name.
module ZemiTestPlugin

__precompile__(false)                   # the tests load it from its source, uncompiled

import Zemi

function poll_folder(run)
    folder = Zemi.settings(run)["folder"]
    for f in sort(filter(endswith(".md"), readdir(folder)))
        text = read(joinpath(folder, f), String)
        m = match(r"^# (.+)$"m, text)
        title = m === nothing ? f : String(m[1])
        put!(run, (; key = f, title, date = "2026-10-02", sections = ["Notes" => text]))
    end
    Zemi.save_state!(run, Dict("read" => length(readdir(folder))))
end

function __init__()
    Zemi.record_source!("zz-folder"; label = "Read from a folder of notes", every = 3600, poll = poll_folder,
                        api = Zemi.PLUGIN_API)
end

end

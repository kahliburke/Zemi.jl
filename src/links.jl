# Links made the same on every system. Windows lets a person without admin rights link a folder by
# its absolute path (a junction) and hard-link a file, but not make a symbolic link to a file.

"""
    link_file(from, to)

Put the file `from` at `to` without copying it where the system allows: a symbolic link, else a hard
link (on the same volume), else a copy.
"""
function link_file(from::AbstractString, to::AbstractString)
    from = abspath(from)
    try
        return symlink(from, to)
    catch e
        e isa Base.IOError || rethrow()
    end
    try
        return hardlink(from, to)
    catch e
        e isa Base.IOError || rethrow()
    end
    cp(from, to)
    return nothing
end

"""
    link_dir(from, to)

Link the folder `from` at `to`, by its absolute path, which on Windows makes a junction anyone may
make.
"""
link_dir(from::AbstractString, to::AbstractString) = symlink(abspath(from), to; dir_target = true)

"Where the link `path` leads, without the separator Windows ends a junction's target with."
link_target(path::AbstractString) = rstrip(readlink(path), ('/', '\\'))

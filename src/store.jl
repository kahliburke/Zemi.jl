"""
    KB

An open knowledge base: its configuration and its SQLite database. SQLite holds everything except
the vectors (papers, where they were mentioned, parse output, chunk text, the keyword index, and a
record of what has been embedded in which layer), so the database can always rebuild the vector
store. Access to the connection is serialized through `lock`, because tool calls arrive on
separate tasks.
"""
mutable struct KB
    config::Config
    db::SQLite.DB
    lock::ReentrantLock
end

# MIGRATIONS[v] takes the database from version v-1 to v; the schema version is their number. A
# database records how many it has applied, so new migrations go at the end, never between others.
const MIGRATIONS = Vector{Vector{String}}()

# Migrations defined before those numbered below them, waiting for them (files define migrations in
# the order they are loaded, which need not be the migrations' order).
const EARLY_MIGRATIONS = Dict{Int,Vector{String}}()

"""
    migration!(v, statements)

Define migration `v`. Defining one again replaces it, so Revise evaluating an edited migration in a
running service does not add it twice. One defined before those below it waits for them; a
database is not migrated while any are missing (see [`migrate!`](@ref)).
"""
function migration!(v::Integer, statements::AbstractVector{<:AbstractString})
    v >= 1 || error("Migrations are numbered from 1: $v")
    statements = String.(statements)
    if v <= length(MIGRATIONS)
        MIGRATIONS[v] = statements
    elseif v == length(MIGRATIONS) + 1
        push!(MIGRATIONS, statements)
        while haskey(EARLY_MIGRATIONS, length(MIGRATIONS) + 1)
            push!(MIGRATIONS, pop!(EARLY_MIGRATIONS, length(MIGRATIONS) + 1))
        end
    else
        EARLY_MIGRATIONS[v] = statements
    end
    return v
end

"""
    open_kb(config = load_config()) -> KB

Open (creating if needed) the knowledge base database under `config.data_dir`, and point the
knowledge base's Qdrant client at its Qdrant (see [`qdrant_endpoint`](@ref)). A knowledge base with no papers is seeded from
`config.base_set`.
"""
function open_kb(config::Config = load_config())
    validate(config)
    mkpath(config.data_dir)
    mkpath(pdf_dir(config))
    kb = KB(config, SQLite.DB(db_path(config)), ReentrantLock())
    # The service, the site's page writer and its builds write to one database from processes of their
    # own; a long write (reading a codebase's whole history, say) holds the others for seconds.
    for pragma in ("journal_mode = WAL", "foreign_keys = ON", "busy_timeout = 60000")
        execute!(kb, "PRAGMA $pragma")
    end
    migrate!(kb)
    rekey_pdf_summaries!(kb)
    if !isempty(config.base_set) && isfile(config.base_set) && scalar(kb, "SELECT count(*) FROM papers") == 0
        @info "Seeding the new knowledge base from $(config.base_set)" papers = seed!(kb, config.base_set)
    end
    Qdrant.use!(() -> qdrant_endpoint(config))
    return kb
end

Base.close(kb::KB) = lock(() -> SQLite.close(kb.db), kb.lock)

function Base.show(io::IO, kb::KB)
    print(io, "KB(", db_path(kb.config), ")")
end

const _KB = Ref{Union{KB,Nothing}}(nothing)
const _KB_LOCK = ReentrantLock()

"""
    kb() -> KB

The process-wide knowledge base, opened on first use with the config file's settings. Tools and
notebooks share it.
"""
function kb()
    lock(_KB_LOCK) do
        _KB[] === nothing && (_KB[] = open_kb())
        _KB[]
    end
end

function shutdown()
    lock(_KB_LOCK) do
        _KB[] === nothing || close(_KB[])
        _KB[] = nothing
    end
end

"""
    query(kb, sql, params = ()) -> Vector{NamedTuple}

Run a SELECT and materialize its rows.
"""
query(kb::KB, sql::AbstractString, params = ()) =
    lock(() -> Tables.rowtable(DBInterface.execute(kb.db, sql, params)), kb.lock)

"""
    execute!(kb, sql, params = ())

Run a statement for its effect. The cursor is closed straight away, since a statement that returns
rows (like some PRAGMAs) otherwise stays in progress and blocks the next transaction.
"""
function execute!(kb::KB, sql::AbstractString, params = ())
    lock(kb.lock) do
        DBInterface.close!(DBInterface.execute(kb.db, sql, params))
    end
    return nothing
end

"""
    transaction(f, kb)

Run `f()` inside a single SQLite transaction, holding the connection lock throughout.
"""
transaction(f, kb::KB) = lock(() -> SQLite.transaction(f, kb.db), kb.lock)

"The placeholders of `n` values in SQL, for `IN (…)`: `?, ?, ?`."
in_marks(n::Integer) = join(fill("?", n), ", ")

function scalar(kb::KB, sql::AbstractString, params = ())
    rows = query(kb, sql, params)
    isempty(rows) ? missing : first(values(first(rows)))
end

"The schema version this code writes: the number of migrations."
schema_version() = length(MIGRATIONS)

"Bring the knowledge base this process opened (see [`kb`](@ref)), if it has, up to the code's schema."
migrate_open!() = (k = _KB[]; k === nothing || migrate!(k); nothing)

function migrate!(kb::KB)
    isempty(EARLY_MIGRATIONS) || error("Migration $(length(MIGRATIONS) + 1) is missing, before $(join(sort!(collect(keys(EARLY_MIGRATIONS))), ", "))")
    latest = schema_version()
    transaction(kb) do
        has_kv = !isempty(query(kb, "SELECT name FROM sqlite_master WHERE name = 'kv'"))
        version = has_kv ? parse(Int, coalesce(scalar(kb, "SELECT value FROM kv WHERE key = 'schema_version'"), "0")) : 0
        version > latest && error("Database schema v$version is newer than this code (v$latest)")
        for v in version+1:latest
            foreach(sql -> execute!(kb, sql), MIGRATIONS[v])
        end
        if version < latest
            execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('schema_version', ?)", (string(latest),))
        end
    end
    return kb
end

paper_id(kb::KB, doc_id::AbstractString) =
    scalar(kb, "SELECT id FROM papers WHERE doc_id = ?", (doc_id,))

function paper_row(kb::KB, doc_id::AbstractString)
    rows = query(kb, "SELECT * FROM papers WHERE doc_id = ?", (doc_id,))
    isempty(rows) && not_found("No paper $doc_id in the knowledge base")
    return first(rows)
end

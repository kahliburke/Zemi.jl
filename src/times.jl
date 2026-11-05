# Times as the knowledge base keeps and sends them: ISO 8601 in UTC to the second, ending `Z`
# (`2026-10-04T13:49:17Z`), so that they sort as text in the order they happened.

const ISO_FORMAT = dateformat"yyyy-mm-ddTHH:MM:SS"

"A UTC time as the knowledge base keeps it (`2026-10-04T13:49:17Z`); a number is Unix seconds."
iso(t::DateTime) = Dates.format(t, ISO_FORMAT) * "Z"
iso(t::Real) = iso(unix2datetime(floor(t)))

"Now, as [`iso`](@ref) writes it."
now_iso() = iso(now(UTC))

"The time `d` ago, as [`iso`](@ref) writes it."
iso_ago(d::Period) = iso(now(UTC) - d)

"The time `d` from now, as [`iso`](@ref) writes it."
iso_in(d::Period) = iso(now(UTC) + d)

"""
    parse_iso(s) -> DateTime

A time written in ISO 8601 (`2026-10-04T14:03:11-07:00`; ending `Z`, or with no zone, it is UTC),
in UTC. Fractions of a second are dropped.
"""
function parse_iso(s::AbstractString)
    m = match(r"^\s*(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?(?:Z|([+-])(\d\d):?(\d\d))?\s*$", s)
    m === nothing && error("Not an ISO 8601 time: $s")
    t = DateTime(m[1])
    m[2] === nothing && return t
    # Local time is UTC plus the offset.
    return t - (m[2] == "+" ? 1 : -1) * Minute(60parse(Int, m[3]) + parse(Int, m[4]))
end

"Seconds since a time [`parse_iso`](@ref) reads."
seconds_since(s::AbstractString) = datetime2unix(now(UTC)) - datetime2unix(parse_iso(s))

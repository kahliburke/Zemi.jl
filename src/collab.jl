# Writing a document together: where the browsers of the people editing it find each other. A
# WebSocket at `/api/collab` carries the handshake of their direct connections (y-webrtc's signaling:
# subscribe, publish, ping) and relays the document's updates between browsers that cannot connect
# directly, on topics under the document's room. A browser comes in with a ticket its Slate hub asked
# for on its behalf, so no key reaches the page. A ticket admits to one room, and whoever it was made
# for must still reach the room's project each time it is used.

"A room's name: the project's key and the document's id, `KEY/doc-id`."
collab_room(project::AbstractString, document::AbstractString) = uppercase(strip(project)) * "/" * strip(document)

const COLLAB_DOCUMENT = r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"

"How long a ticket admits its browser, reconnecting included."
const COLLAB_TICKET_HOURS = 12

"The largest message a browser may send."
const COLLAB_MAX_FRAME = 1 << 20

struct CollabTicket
    caller::Caller
    room::String
    project::String
    expires::DateTime
end

mutable struct CollabPeer
    const ws::HTTP.WebSockets.WebSocket
    const room::String
    const who::String
    const since::String
    const topics::Set{String}
    const sending::ReentrantLock
end

const COLLAB_TICKETS = Dict{String,CollabTicket}()
"Each topic's subscribers."
const COLLAB_TOPICS = Dict{String,Set{CollabPeer}}()
const COLLAB_LOCK = ReentrantLock()

"""
    collab_ticket!(kb, caller, project, document) -> NamedTuple

A ticket for `caller` to the room of `document` in `project`, which they must reach as a
contributor: `(; ticket, room, path, expires, name, rooms)`, `path` the WebSocket to open with
`?ticket=`, `name` theirs, for the others in the room to see, and `rooms` the project's rooms with
someone in them (see [`collab_rooms`](@ref)), so a copy whose document id differs is noticed.
"""
function collab_ticket!(kb::KB, caller::Caller, project::AbstractString, document::AbstractString)
    key = need_project!(kb, caller, project, CONTRIBUTE)
    doc = strip(document)
    occursin(COLLAB_DOCUMENT, doc) || error("A document's id is letters, digits and . _ : -, up to 128")
    room = collab_room(key, doc)
    ticket = bytes2hex(rand(SECRET_RNG, UInt8, 24))
    expires = now(UTC) + Hour(COLLAB_TICKET_HOURS)
    lock(COLLAB_LOCK) do
        filter!(((_, t),) -> t.expires > now(UTC), COLLAB_TICKETS)
        COLLAB_TICKETS[ticket] = CollabTicket(caller, room, key, expires)
    end
    return (; ticket, room, path = "/api/collab", expires = iso(expires), name = caller_name(caller), rooms = collab_rooms(key))
end

"The ticket `ticket` names, if it is current and its caller still reaches its project as a contributor."
function collab_admit(kb::KB, ticket::AbstractString)
    t = lock(() -> get(COLLAB_TICKETS, ticket, nothing), COLLAB_LOCK)
    (t === nothing || t.expires <= now(UTC)) && return nothing
    project_access(kb, t.caller, t.project) >= CONTRIBUTE || return nothing
    return t
end

"Whether `topic` is one of room `room`'s: the room itself (y-webrtc's), or `room#anything` (the relay's)."
collab_topic_ok(room::AbstractString, topic) = topic isa AbstractString && (topic == room || startswith(topic, room * "#"))

function collab_send(p::CollabPeer, msg::AbstractString)
    try
        lock(() -> HTTP.WebSockets.send(p.ws, msg), p.sending)
    catch
        # A peer gone: its own loop ends and unsubscribes it.
    end
end

function collab_unsubscribe!(p::CollabPeer, topic::AbstractString)
    s = get(COLLAB_TOPICS, topic, nothing)
    s === nothing && return
    delete!(s, p)
    isempty(s) && delete!(COLLAB_TOPICS, topic)
    delete!(p.topics, topic)
end

"""
    collab_message!(p, raw)

Act on one message from peer `p`, as y-webrtc's signaling server does: `subscribe` and
`unsubscribe` to the room's topics, `publish` to a topic it is subscribed to (sent on to its other
subscribers, with `clients`, how many there are), and `ping`. Anything else is ignored.
"""
function collab_message!(p::CollabPeer, raw)
    m = try JSON.parse(raw isa AbstractString ? raw : String(copy(raw))) catch; nothing end
    m isa AbstractDict || return
    kind = get(m, "type", "")
    if kind == "subscribe" || kind == "unsubscribe"
        topics = get(m, "topics", nothing)
        topics isa AbstractVector || return
        lock(COLLAB_LOCK) do
            for t in topics
                collab_topic_ok(p.room, t) || continue
                if kind == "subscribe"
                    push!(get!(Set{CollabPeer}, COLLAB_TOPICS, t), p)
                    push!(p.topics, t)
                else
                    collab_unsubscribe!(p, t)
                end
            end
        end
    elseif kind == "publish"
        topic = get(m, "topic", nothing)
        others = lock(COLLAB_LOCK) do
            topic isa AbstractString && topic in p.topics || return CollabPeer[]
            [q for q in COLLAB_TOPICS[topic] if q !== p]
        end
        isempty(others) && return
        m["clients"] = length(others) + 1
        msg = JSON.json(m)
        foreach(q -> collab_send(q, msg), others)
    elseif kind == "ping"
        collab_send(p, """{"type":"pong"}""")
    end
end

"""
    collab_socket(kb, stream)

Answer a WebSocket to `/api/collab?ticket=…`: refused (403) without a current ticket, else a peer of
the ticket's room until it closes.
"""
function collab_socket(kb::KB, stream::HTTP.Stream)
    params = HTTP.queryparams(HTTP.URI(stream.message.target))
    t = collab_admit(kb, get(params, "ticket", ""))
    if t === nothing
        HTTP.setstatus(stream, 403)
        HTTP.startwrite(stream)
        write(stream, "No current ticket for this document")
        return
    end
    # From any page: the notebook's is its hub's, another origin than this, and the ticket is what admits it.
    HTTP.WebSockets.upgrade(stream; maxframesize = COLLAB_MAX_FRAME, check_origin = (_...) -> true) do ws
        p = CollabPeer(ws, t.room, caller_name(t.caller), now_iso(), Set{String}(), ReentrantLock())
        try
            for raw in ws
                collab_message!(p, raw)
            end
        catch e
            e isa HTTP.WebSockets.WebSocketError || @warn "A collaboration socket failed" room = t.room exception = e
        finally
            lock(COLLAB_LOCK) do
                foreach(topic -> collab_unsubscribe!(p, topic), collect(p.topics))
            end
        end
    end
end

"""
    collab_rooms(project) -> Vector{NamedTuple}

The rooms of `project` with someone in them now: `(; room, document, people)`, `people` each
`(; name, since)`, the earliest first.
"""
function collab_rooms(project::AbstractString)
    key = uppercase(strip(project))
    peers = lock(COLLAB_LOCK) do
        unique(q for (topic, s) in COLLAB_TOPICS if startswith(topic, key * "/") for q in s)
    end
    rooms = Dict{String,Vector{CollabPeer}}()
    foreach(q -> push!(get!(Vector{CollabPeer}, rooms, q.room), q), peers)
    return [(; room, document = String(split(room, '/'; limit = 2)[2]),
              people = [(; name = q.who, since = q.since) for q in sort(ps; by = q -> q.since)])
            for (room, ps) in sort!(collect(rooms); by = first)]
end

"""
    service_handler(kb, respond) -> stream handler

The service's handler: a WebSocket to `/api/collab` answered by [`collab_socket`](@ref), every other
request by `respond(req)`.
"""
function service_handler(kb::KB, respond)
    plain = HTTP.streamhandler(respond)
    return function (stream::HTTP.Stream)
        target = stream.message.target
        collab = HTTP.WebSockets.isupgrade(stream.message) && HTTP.URI(target).path == "/api/collab"
        collab ? Base.invokelatest(collab_socket, kb, stream) : plain(stream)
    end
end

route!("POST", "/api/projects/:key/collab/ticket"; need = "tasks.edit", project = CONTRIBUTE) do c
    collab_ticket!(c.kb, c.caller, c[:key], String(get(json_body(c), "document", "")))
end

route!("GET", "/api/projects/:key/collab"; need = "tasks.view", project = VIEW) do c
    (; rooms = collab_rooms(c[:key]))
end

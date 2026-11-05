"""
    LockedDict{K,V}()

A `Dict` for state several threads share (caches, what is being made): each access holds its lock.
`get!(f, d, k)` computes a missing value outside it, so a slow look-up holds up no other, and keeps
the value stored first when two compute it at once.
"""
struct LockedDict{K,V}
    dict::Dict{K,V}
    lock::ReentrantLock
end
LockedDict{K,V}() where {K,V} = LockedDict{K,V}(Dict{K,V}(), ReentrantLock())

Base.get(d::LockedDict, k, default) = @lock d.lock get(d.dict, k, default)
Base.haskey(d::LockedDict, k) = @lock d.lock haskey(d.dict, k)
Base.setindex!(d::LockedDict, v, k) = (@lock d.lock d.dict[k] = v; d)
Base.delete!(d::LockedDict, k) = (@lock d.lock delete!(d.dict, k); d)
Base.empty!(d::LockedDict) = (@lock d.lock empty!(d.dict); d)
Base.length(d::LockedDict) = @lock d.lock length(d.dict)

function Base.get!(f, d::LockedDict{K,V}, k) where {K,V}
    have = get(d, k, nothing)
    have === nothing || return have
    v = convert(V, f())
    return @lock d.lock get!(d.dict, k, v)
end

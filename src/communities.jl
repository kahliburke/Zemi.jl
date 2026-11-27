# The clusters documents fall into by meaning: the communities of the graph that joins each document to
# those nearest it, found by Leiden (Traag, Waltman and van Eck, 2019) as modularity at a resolution
# picks them. Their number and sizes are what the library has, not set beforehand, and each is
# connected. Started from an earlier clustering, the clusters keep their documents as the library
# changes, and so their names (see `name_clusters!`).

import Graphs, LeidenClustering
using SparseArrays: sparse

"How many of its nearest each document is joined to: fewer in a small library, so its topics come apart."
community_neighbours(n::Integer) = clamp(round(Int, sqrt(n)), 5, 15)

"""
    communities(X; near = nothing, resolution = 1.0, from = nothing, seed = 1, least) -> (assign, centres)

The clusters of the unit columns of `X`: each column's cluster, numbered by size, largest first, and
each cluster's centre, its unit mean direction. The graph joins each column to its
[`community_neighbours`](@ref) nearest by cosine similarity, weighted by it: from `near` (each
column's nearest, nearest first, as [`nearest_columns`](@ref) gives them) where they are found
already. `resolution` above 1 makes more and smaller clusters, below 1 fewer and larger. `from` is
an earlier cluster for each column (0 for one that had none), which the search starts from. A cluster
of fewer than `least` columns joins the larger one whose centre is nearest.
"""
function communities(X::AbstractMatrix; near = nothing, resolution::Real = 1.0, from = nothing, seed::Integer = 1,
                     least::Integer = max(3, size(X, 2) ÷ 200))
    n = size(X, 2)
    n < 3 && return ones(Int, n), unit_columns(reshape(vec(sum(X; dims = 2)), :, 1))
    k = community_neighbours(n)
    near = near === nothing ? nearest_columns(X, k) : [first(ns, k) for ns in near]
    weight = Dict{Tuple{Int,Int},Float64}()
    for (i, ns) in enumerate(near), (j, s) in ns
        i == j && continue
        e = minmax(i, j)
        weight[e] = max(get(weight, e, 0.0), s, 1e-6)                 # alike or not, still joined
    end
    g = Graphs.SimpleGraph(n)
    I, J, V = Int[], Int[], Float64[]
    for ((a, b), s) in weight
        Graphs.add_edge!(g, a, b)
        push!(I, a, b); push!(J, b, a); push!(V, s, s)
    end
    assign = LeidenClustering.leiden_clustering(g; weights = sparse(I, J, V, n, n), resolution, n_iterations = -1,
                                                seed, initial_membership = community_start(from, n)).membership
    return number_by_size(X, fold_small_communities(X, assign, least))
end

# An earlier clustering to start from, one positive id per column: those that had none each start alone.
function community_start(from, n)
    (from === nothing || length(from) != n || all(iszero, from)) && return nothing
    out = collect(Int, from)
    next = maximum(out)
    for i in eachindex(out)
        out[i] > 0 || (out[i] = next += 1)
    end
    return out
end

# Clusters of fewer than `least` columns joined to the larger cluster whose centre is nearest each column.
function fold_small_communities(X, assign, least)
    sizes = Dict(c => count(==(c), assign) for c in unique(assign))
    big = [c for (c, s) in sizes if s >= least]
    (isempty(big) || length(big) == length(sizes)) && return assign
    C = unit_columns(reduce(hcat, [vec(sum(X[:, assign .== c]; dims = 2)) for c in big]))
    return [sizes[a] >= least ? a : big[argmax(C' * view(X, :, i))] for (i, a) in enumerate(assign)]
end

# Clusters numbered 1… by size, largest first, with their centres.
function number_by_size(X, assign)
    ids = sort!(unique(assign); by = c -> (-count(==(c), assign), c))
    number = Dict(c => j for (j, c) in enumerate(ids))
    out = [number[a] for a in assign]
    centres = unit_columns(reduce(hcat, [vec(sum(X[:, out .== j]; dims = 2)) for j in eachindex(ids)]))
    return out, centres
end

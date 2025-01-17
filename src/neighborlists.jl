export InPlaceNeighborList
export update!
export neighborlist, neighborlist!

#
# Wrapper of the list of neighbors, that allows in-place updating of the lists
#
mutable struct NeighborList{T}
    n::Int
    list::Vector{Tuple{Int,Int,T}}
end

import Base: push!, empty!, resize!, copy
empty!(x::NeighborList) = x.n = 0
function push!(x::NeighborList, pair)
    x.n += 1
    if x.n > length(x.list)
        push!(x.list, pair)
    else
        x.list[x.n] = pair
    end
    return x
end
function resize!(x::NeighborList, n::Int)
    x.n = n
    resize!(x.list, n)
    return x
end
copy(x::NeighborList{T}) where {T} = NeighborList{T}(x.n, copy(x.list))
copy(x::Tuple{Int,Int,T}) where {T} = (x[1], x[2], x[3])

@testitem "NeighborList operations" begin
    using CellListMap
    nb = CellListMap.NeighborList(0, Tuple{Int,Int,Float64}[])
    @test length(nb.list) == 0
    push!(nb, (0, 0, 0.0))
    @test (nb.n, length(nb.list)) == (1, 1)
    empty!(nb)
    @test (nb.n, length(nb.list)) == (0, 1)
    resize!(nb, 5)
    @test (nb.n, length(nb.list), nb.n) == (5, 5, 5)
    nb2 = copy(nb)
    @test (nb.n, nb.list) == (nb2.n, nb2.list)
end

# Function adds pair to the list
function push_pair!(i, j, d2, list::NeighborList)
    d = sqrt(d2)
    push!(list, (i, j, d))
    return list
end

# We have to define our own reduce function here (for the parallel version)
# this reduction can be dum assynchronously on a preallocated array
function reduce_lists(list::NeighborList{T}, list_threaded::Vector{<:NeighborList{T}}) where {T}
    ranges = cumsum(nb.n for nb in list_threaded)
    npairs = ranges[end]
    list = resize!(list, npairs)
    @sync for it in eachindex(list_threaded)
        lt = list_threaded[it]
        range = ranges[it]-lt.n+1:ranges[it]
        Threads.@spawn list.list[range] .= @view(lt.list[1:lt.n])
    end
    return list
end

@testitem "Neighborlist push/reduce" begin
    using CellListMap
    nb1 = CellListMap.NeighborList(2, [(0, 0, 0.0), (1, 1, 1.0)])
    CellListMap.push_pair!(3, 3, 9.0, nb1)
    @test (nb1.n, nb1.list[3]) == (3, (3, 3, 3.0))
    nb2 = [copy(nb1), CellListMap.NeighborList(1, [(4, 4, 4.0)])]
    CellListMap.reduce_lists(nb1, nb2)
    @test nb1.n == 4
    @test nb1.list == [(0, 0, 0.0), (1, 1, 1.0), (3, 3, 3.0), (4, 4, 4.0)]
end

"""

$(TYPEDEF)

$(INTERNAL)

Structure that containst the system information for neighborlist computations. All fields are internal.

## Extended help

$(TYPEDFIELDS)

"""
mutable struct InPlaceNeighborList{B,C,A,NB<:NeighborList}
    box::B
    cl::C
    aux::A
    nb::NB
    nb_threaded::Vector{NB}
    parallel::Bool
    show_progress::Bool
end

"""
    InPlaceNeighborList(;
        x::AbstractVecOrMat,
        y::Union{AbstractVecOrMat,Nothing}=nothing,
        cutoff::T,
        unitcell::Union{AbstractVecOrMat,Nothing}=nothing,
        parallel::Bool=true,
        show_progress::Bool=false,
    ) where {T}

Function that initializes the `InPlaceNeighborList` structure, to be used for in-place
computation of neighbor lists.

- If only `x` is provided, the neighbor list of the set is computed. 
- If `x` and `y` are provided, the neighbor list between the sets is computed.
- If `unitcell` is provided, periodic boundary conditions will be used. The `unitcell` can
  be a vector of Orthorhombic box sides, or an actual unitcell matrix for general cells. 
- If `unicell` is not provide (value `nothing`), no periodic boundary conditions will
  be considered. 

## Examples

Here the neighborlist structure is constructed for the first time, and used
to compute the neighbor lists with the mutating `neighborlist!` function:

```julia-repl
julia> using CellListMap, StaticArrays

julia> x = rand(SVector{3,Float64}, 10^4);

julia> system = InPlaceNeighborList(x=x, cutoff=0.1, unitcell=[1,1,1]) 
InPlaceNeighborList with types: 
CellList{3, Float64}
Box{OrthorhombicCell, 3, Float64, Float64, 9}
Current list buffer size: 0

julia> neighborlist!(system)
210034-element Vector{Tuple{Int64, Int64, Float64}}:
 (1, 357, 0.09922225615002134)
 (1, 488, 0.043487074695938925)
 (1, 2209, 0.017779967072139684)
 ⋮
 (9596, 1653, 0.0897570322108541)
 (9596, 7927, 0.0898266280344037)
```

The coordinates of the system, its unitcell, or the cutoff can be changed with
the `update!` function. If the number of pairs of the list does not change 
significantly, the new calculation is minimally allocating, or non-allocating 
at all, in particular if the computation is run without parallelization:
    
If the structure is used repeatedly for similar systems, the allocations will
vanish, except for minor allocations used in the threading computation (if a 
non-parallel computation is executed, the allocations will vanish completely):

```julia-repl
julia> x = rand(SVector{3,Float64}, 10^4);

julia> system = InPlaceNeighborList(x=x, cutoff=0.1, unitcell=[1,1,1]);

julia> @time neighborlist!(system);
  0.008004 seconds (228 allocations: 16.728 MiB)

julia> update!(system, rand(SVector{3,Float64}, 10^4); cutoff = 0.1, unitcell = [1,1,1]);

julia> @time neighborlist!(system);
  0.024811 seconds (167 allocations: 7.887 MiB)

julia> update!(system, rand(SVector{3,Float64}, 10^4); cutoff = 0.1, unitcell = [1,1,1]);

julia> @time neighborlist!(system);
  0.005213 seconds (164 allocations: 1.439 MiB)

julia> update!(system, rand(SVector{3,Float64}, 10^4); cutoff = 0.1, unitcell = [1,1,1]);

julia> @time neighborlist!(system);
  0.005276 seconds (162 allocations: 15.359 KiB)

```

"""
function InPlaceNeighborList(;
    x::AbstractVecOrMat,
    y::Union{AbstractVecOrMat,Nothing}=nothing,
    cutoff::T,
    unitcell::Union{AbstractVecOrMat,Nothing}=nothing,
    parallel::Bool=true,
    show_progress::Bool=false,
    autoswap=true,
    nbatches=(0, 0)
) where {T}
    if isnothing(y)
        if isnothing(unitcell)
            unitcell = limits(x)
        end
        box = Box(unitcell, cutoff)
        cl = CellList(x, box, parallel=parallel, nbatches=nbatches)
        aux = AuxThreaded(cl)
    else
        if isnothing(unitcell)
            unitcell = limits(x, y)
        end
        box = Box(unitcell, cutoff)
        cl = CellList(x, y, box, autoswap=autoswap, parallel=parallel, nbatches=nbatches)
        aux = AuxThreaded(cl)
    end
    nb = NeighborList{T}(0, Vector{Tuple{Int,Int,T}}[])
    nb_threaded = [copy(nb) for _ in 1:CellListMap.nbatches(cl)]
    return InPlaceNeighborList(box, cl, aux, nb, nb_threaded, parallel, show_progress)
end

"""
    update!(system::InPlaceNeighborList, x::AbstractVecOrMat; cutoff=nothing, unitcell=nothing)
    update!(system::InPlaceNeighborList, x::AbstractVecOrMat, y::AbstractVecOrMat; cutoff=nothing, unitcell=nothing)

Updates a `InPlaceNeighborList` system, by updating the coordinates, cutoff, and unitcell.

## Examples

### For self-pairs computations

```julia-repl
julia> x = rand(SVector{3,Float64}, 10^3);

julia> system = InPlaceNeighborList(x=x; cutoff=0.1)
InPlaceNeighborList with types: 
CellList{3, Float64}
Box{NonPeriodicCell, 3, Float64, Float64, 9}
Current list buffer size: 0

julia> neighborlist!(system);

julia> new_x = rand(SVector{3,Float64}, 10^3);

julia> update!(system, new_x; cutoff = 0.05)
InPlaceNeighborList with types: 
CellList{3, Float64}
Box{NonPeriodicCell, 3, Float64, Float64, 9}
Current list buffer size: 1826

julia> neighborlist!(system)
224-element Vector{Tuple{Int64, Int64, Float64}}:
 (25, 486, 0.03897345036790646)
 ⋮
 (723, 533, 0.04795768478723409)
 (868, 920, 0.042087156715720137)
```

"""
function update!(
    system::InPlaceNeighborList{<:Box{UnitCellType},C},
    x::AbstractVecOrMat;
    cutoff=nothing, unitcell=nothing
) where {UnitCellType,C<:CellList}
    if UnitCellType == NonPeriodicCell
        isnothing(unitcell) || throw(ArgumentError("Cannot set unitcell for NonPeriodicCell."))
        system.box = update_box(system.box; unitcell=limits(x), cutoff=cutoff)
    else
        system.box = update_box(system.box; unitcell=unitcell, cutoff=cutoff)
    end
    system.cl = UpdateCellList!(x, system.box, system.cl, system.aux, parallel=system.parallel)
    return system
end

#
# update system for cross-computations
#
function update!(
    system::InPlaceNeighborList{<:Box{UnitCellType},C},
    x::AbstractVecOrMat,
    y::AbstractVecOrMat;
    cutoff=nothing, unitcell=nothing
) where {UnitCellType,C<:CellListPair}
    if UnitCellType == NonPeriodicCell
        isnothing(unitcell) || throw(ArgumentError("Cannot set unitcell for NonPeriodicCell."))
        system.box = update_box(system.box; unitcell=limits(x, y), cutoff=cutoff)
    else
        system.box = update_box(system.box; unitcell=unitcell, cutoff=cutoff)
    end
    system.cl = UpdateCellList!(x, y, system.box, system.cl, system.aux; parallel=system.parallel)
    return system
end

@testitem "InPlaceNeighborLists Updates" begin
    using CellListMap
    using StaticArrays
    using LinearAlgebra: diag
    import CellListMap: _sides_from_limits

    # Non-periodic systems
    x = rand(SVector{3,Float64}, 10^3)
    system = InPlaceNeighborList(x=x, cutoff=0.1)
    @test diag(system.box.input_unit_cell.matrix) == _sides_from_limits(limits(x), 0.1)
    x = rand(SVector{3,Float64}, 10^3)
    update!(system, x)
    @test system.box.cutoff == 0.1
    update!(system, x; cutoff=0.05)
    @test system.box.cutoff == 0.05
    @test diag(system.box.input_unit_cell.matrix) == _sides_from_limits(limits(x),0.05)

    x = rand(SVector{3,Float64}, 10^3)
    y = rand(SVector{3,Float64}, 10^3)
    system = InPlaceNeighborList(x=x, y=y, cutoff=0.1)
    @test diag(system.box.input_unit_cell.matrix) ≈ _sides_from_limits(limits(x, y), 0.1)
    x = rand(SVector{3,Float64}, 10^3)
    y = rand(SVector{3,Float64}, 10^3)
    update!(system, x, y)
    @test system.box.cutoff == 0.1
    update!(system, x, y; cutoff=0.05)
    @test system.box.cutoff == 0.05
    @test diag(system.box.input_unit_cell.matrix) ≈ _sides_from_limits(limits(x, y), 0.05)

    # Orthorhombic systems
    x = rand(SVector{3,Float64}, 10^3)
    system = InPlaceNeighborList(x=x, cutoff=0.1, unitcell=[1, 1, 1])
    update!(system, x)
    @test system.box.cutoff == 0.1
    update!(system, x; cutoff=0.05)
    @test system.box.cutoff == 0.05
    update!(system, x; cutoff=0.05, unitcell=[2, 2, 2])
    @test (system.box.cutoff, system.box.input_unit_cell.matrix) == (0.05, [2 0 0; 0 2 0; 0 0 2])

    system = InPlaceNeighborList(x=x, y=y, cutoff=0.1, unitcell=[1, 1, 1])
    update!(system, x, y)
    @test system.box.cutoff == 0.1
    update!(system, x, y; cutoff=0.05)
    @test system.box.cutoff == 0.05
    update!(system, x, y; cutoff=0.05, unitcell=[2, 2, 2])
    @test (system.box.cutoff, system.box.input_unit_cell.matrix) == (0.05, [2 0 0; 0 2 0; 0 0 2])

    # Triclinic systems
    x = rand(SVector{3,Float64}, 10^3)
    system = InPlaceNeighborList(x=x, cutoff=0.1, unitcell=[1 0 0; 0 1 0; 0 0 1])
    update!(system, x)
    @test system.box.cutoff == 0.1
    update!(system, x; cutoff=0.05)
    @test system.box.cutoff == 0.05
    update!(system, x; cutoff=0.05, unitcell=[2 0 0; 0 2 0; 0 0 2])
    @test (system.box.cutoff, system.box.input_unit_cell.matrix) == (0.05, [2 0 0; 0 2 0; 0 0 2])

    system = InPlaceNeighborList(x=x, y=y, cutoff=0.1, unitcell=[1 0 0; 0 1 0; 0 0 1])
    update!(system, x, y)
    @test system.box.cutoff == 0.1
    update!(system, x, y; cutoff=0.05)
    @test system.box.cutoff == 0.05
    update!(system, x, y; cutoff=0.05, unitcell=[2 0 0; 0 2 0; 0 0 2])
    @test (system.box.cutoff, system.box.input_unit_cell.matrix) == (0.05, [2 0 0; 0 2 0; 0 0 2])

end

function Base.show(io::IO, ::MIME"text/plain", system::InPlaceNeighborList)
    _print(io, "InPlaceNeighborList with types: \n")
    _print(io, typeof(system.cl), "\n")
    _print(io, typeof(system.box), "\n")
    _print(io, "Current list buffer size: $(length(system.nb.list))")
end

function neighborlist!(system::InPlaceNeighborList)
    # Empty lists and auxiliary threaded arrays
    empty!(system.nb)
    for i in eachindex(system.nb_threaded)
        empty!(system.nb_threaded[i])
    end
    # Compute the neighbor lists
    map_pairwise!(
        (x, y, i, j, d2, nb) -> push_pair!(i, j, d2, nb),
        system.nb, system.box, system.cl,
        reduce=reduce_lists,
        parallel=system.parallel,
        output_threaded=system.nb_threaded,
        show_progress=system.show_progress
    )
    return system.nb.list
end

@testitem "InPlaceNeighborList vs. NearestNeighbors" begin

    using CellListMap
    using CellListMap.TestingNeighborLists
    using NearestNeighbors

    for N in [2, 3]

        x = rand(N, 500)
        r = 0.1
        nb = nl_NN(BallTree, inrange, x, x, r)
        system = InPlaceNeighborList(x=x, cutoff=r)
        cl = neighborlist!(system)
        @test is_unique(cl; self=true)
        @test compare_nb_lists(cl, nb, x, r)[1]
        # Test system updating for self-lists
        r = 0.05
        new_x = rand(N, 450)
        nb = nl_NN(BallTree, inrange, new_x, new_x, r)
        update!(system, new_x; cutoff=r)
        cl = neighborlist!(system)
        @test is_unique(cl; self=true)
        @test compare_nb_lists(cl, nb, x, r)[1]

        # Test system updating for cross-lists
        x = rand(N, 500)
        y = rand(N, 1000)
        r = 0.1
        nb = nl_NN(BallTree, inrange, x, y, r)
        system = InPlaceNeighborList(x=x, y=y, cutoff=r)
        cl = neighborlist!(system)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]
        r = 0.05
        new_x = rand(N, 500)
        new_y = rand(N, 831)
        nb = nl_NN(BallTree, inrange, new_x, new_y, r)
        update!(system, new_x, new_y; cutoff=r)
        cl = neighborlist!(system)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]

    end

end

@testitem "Allocations" begin
    using CellListMap
    using StaticArrays
    using BenchmarkTools

    #
    # Single set of particles
    #

    # Periodic systems
    x = rand(SVector{3,Float64}, 10^3)
    system = InPlaceNeighborList(x=x, cutoff=0.1, unitcell=[1, 1, 1], parallel=false)
    neighborlist!(system)
    x = rand(SVector{3,Float64}, 10^3)
    allocs = @ballocated update!($system, $x) evals = 1 samples = 1
    @test allocs == 0
    allocs = @ballocated update!($system, $x; cutoff=0.2) evals = 1 samples = 1
    @test allocs == 0
    allocs = @ballocated neighborlist!($system) evals = 1 samples = 1
    @test allocs == 0

    # Non-Periodic systems
    x = rand(SVector{3,Float64}, 10^3)
    system = InPlaceNeighborList(x=x, cutoff=0.1, parallel=false)
    neighborlist!(system)
    x = rand(SVector{3,Float64}, 10^3)
    allocs = @ballocated update!($system, $x) evals = 1 samples = 1
    @test allocs == 0
    allocs = @ballocated update!($system, $x; cutoff=0.2) evals = 1 samples = 1
    @test allocs == 0
    allocs = @ballocated neighborlist!($system) evals = 1 samples = 1
    @test allocs == 0

    #
    # Two sets of particles
    #

    # Periodic systems
    y = rand(SVector{3,Float64}, 10^3)
    system = InPlaceNeighborList(x=x, y=y, cutoff=0.1, unitcell=[1, 1, 1], parallel=false)
    neighborlist!(system)
    x = rand(SVector{3,Float64}, 10^3)
    y = rand(SVector{3,Float64}, 10^3)
    allocs = @ballocated neighborlist!($system) evals = 1 samples = 1
    @test allocs == 0
    allocs = @ballocated update!($system, $x, $y) evals = 1 samples = 1
    @test allocs == 0
    allocs = @ballocated update!($system, $x, $y; cutoff=0.2) evals = 1 samples = 1
    @test allocs == 0

    # Non-Periodic systems
    y = rand(SVector{3,Float64}, 10^3)
    system = InPlaceNeighborList(x=x, y=y, cutoff=0.1, parallel=false)
    neighborlist!(system)
    x = rand(SVector{3,Float64}, 10^3)
    y = rand(SVector{3,Float64}, 10^3)
    allocs = @ballocated neighborlist!($system) evals = 1 samples = 1
    @test allocs == 0
    allocs = @ballocated update!($system, $x, $y) evals = 1 samples = 1
    @test allocs == 0
    allocs = @ballocated update!($system, $x, $y; cutoff=0.2) evals = 1 samples = 1
    @test allocs == 0

end

"""
    neighborlist(x, cutoff; unitcell=nothing, parallel=true, show_progress=false)

Computes the list of pairs of particles in `x` which are closer to each other than `cutoff`.
If the keyword parameter `unitcell` is provided (as a vector of sides or a general unit cell
matrix, periodic boundary conditions are considered). 

## Example
```julia-repl
julia> using CellListMap

julia> x = [ rand(3) for i in 1:10_000 ];

julia> neighborlist(x,0.05)
24848-element Vector{Tuple{Int64, Int64, Float64}}:
 (1, 1055, 0.022977369806392412)
 (1, 5086, 0.026650609138167428)
 ⋮
 (9989, 3379, 0.0467653507446483)
 (9989, 5935, 0.02432728985151653)

```

"""
function neighborlist(
    x, cutoff;
    unitcell=nothing,
    parallel=true,
    show_progress=false,
    nbatches=(0, 0)
)
    system = InPlaceNeighborList(;
        x=x,
        cutoff=cutoff,
        unitcell=unitcell,
        parallel=parallel,
        show_progress=show_progress,
        nbatches=nbatches
    )
    return neighborlist!(system)
end

"""
    neighborlist(
        x, y, cutoff; 
        unitcell=nothing, 
        parallel=true, 
        show_progress=false, 
        autoswap=true,
        nbatches=(0,0)
    )

Computes the list of pairs of particles of `x` which are closer than `r` to
the particles of `y`. The `autoswap` option will swap `x` and `y` to try to optimize
the cost of the construction of the cell list. 

## Example
```julia-repl
julia> x = [ rand(3) for i in 1:10_000 ];

julia> y = [ rand(3) for i in 1:1_000 ];

julia> CellListMap.neighborlist(x,y,0.05)
5006-element Vector{Tuple{Int64, Int64, Float64}}:
 (1, 269, 0.04770884036497686)
 (25, 892, 0.03850515231540869)
 ⋮
 (9952, 749, 0.048875643578313456)
 (9984, 620, 0.04101242499363183)

```

"""
function neighborlist(
    x, y, cutoff;
    unitcell=nothing,
    parallel=true,
    show_progress=false,
    autoswap=true,
    nbatches=(0, 0)
)
    system = InPlaceNeighborList(
        x=x,
        y=y,
        cutoff=cutoff,
        unitcell=unitcell,
        parallel=parallel,
        show_progress=show_progress,
        autoswap=autoswap,
        nbatches=nbatches
    )
    return neighborlist!(system)
end

@testitem "Neighborlist - pathological" begin
    using CellListMap
    using CellListMap.TestingNeighborLists
    using StaticArrays

    @test neighborlist([[0.0, 0.0, 1.0], [0.0, 0.0, 10.0], [0.0, 0.0, 7.0]], 2.0) == Tuple{Int64,Int64,Float64}[]
    @test neighborlist([[0.0, 0.0, 1.0], [0.0, 0.0, 10.0]], 2.0) == Tuple{Int64,Int64,Float64}[]
    @test neighborlist([[0.0, 1.0], [0.0, 10.0]], 2.0) == Tuple{Int64,Int64,Float64}[]
    @test neighborlist([[0.0, 1.0]], 2.0) == Tuple{Int64,Int64,Float64}[]
    @test neighborlist([[0.0, 0.0]], 2.0) == Tuple{Int64,Int64,Float64}[]
    @test neighborlist([[0.0, 0.0, 0.0]], 2.0) == Tuple{Int64,Int64,Float64}[]
    @test neighborlist([[0.0, 0.0]], 1.0; unitcell=[2.0, 2.0] .+ nextfloat(1.0)) == Tuple{Int64,Int64,Float64}[]
    @test neighborlist([[0.0, 0.0], [0.0, 1.0]], 1.0; unitcell=[2.0, 2.0] .+ nextfloat(1.0)) in ([(1, 2, 1.0)],[(2, 1, 1.0)])
    @test neighborlist([[0.0, 0.0], [0.0, 1.0]], prevfloat(1.0); unitcell=[2.0, 2.0]) == Tuple{Int64,Int64,Float64}[]
    @test neighborlist([[0.0, 0.0], [0.0, 1.0] .+ nextfloat(1.0)], prevfloat(1.0); unitcell=[2.0, 2.0]) in ([(1, 2, 0.9999999999999998)],[(2, 1, 0.9999999999999998)])

    # Some pathological cases related to bug 84
    l = SVector{3, Float32}[[0.0, 0.0, 0.0], [0.154, 1.136, -1.827], [-1.16, 1.868, 4.519], [-0.089, 2.07, 4.463],  [0.462, -0.512, 5.473]]
    nl = neighborlist(l, 7.0) 
    @test is_unique(nl; self=true)
    lr = Ref(x_rotation(π/2)) .* l
    nr = neighborlist(l, 7.0) 
    @test is_unique(nr; self=true)
    lr = Ref(y_rotation(π/2)) .* l
    nr = neighborlist(l, 7.0) 
    @test is_unique(nr; self=true)
    lr = Ref(z_rotation(π/2)) .* l
    nr = neighborlist(l, 7.0) 
    @test is_unique(nr; self=true)
    lr = Ref(z_rotation(π/2) * y_rotation(π/2)) .* l
    nr = neighborlist(l, 7.0) 
    @test is_unique(nr; self=true)
    lr = Ref(z_rotation(π/2) * x_rotation(π/2)) .* l
    nr = neighborlist(l, 7.0) 
    @test is_unique(nr; self=true)
    lr = Ref(y_rotation(π/2) * x_rotation(π/2)) .* l
    nr = neighborlist(l, 7.0) 
    @test is_unique(nr; self=true)

    # in 2D
    rotation(x) = @SMatrix[ cos(x) sin(x); -sin(x) cos(x)]

    l = SVector{2, Float32}[[0.0, 0.0], [0.0, -2.0], [-0.1, 5.0],  [0.0, 5.5]]
    nl = neighborlist(l, 7.0) 
    @test is_unique(nl; self=true)
    lr = Ref(rotation(π/2)) .* l
    nr = neighborlist(l, 7.0) 
    @test is_unique(nr; self=true)

    l = SVector{2, Float32}[[0.0, 0.0], [-0.1, 5.0]]
    nl = neighborlist(l, 7.0; unitcell=[14.01, 14.51])
    @test length(nl) == 1
    l = Ref(rotation(π/2)) .* l
    nr = neighborlist(l, 7.0) 
    @test is_unique(nr; self=true)

    l = SVector{2, Float64}[[0.0, 0.0], [-1, 0.0]]
    unitcell = [14.01, 14.02]
    nl = neighborlist(l, 5.0; unitcell=unitcell)
    @test length(nl) == 1
    l = Ref(rotation(π/2)) .* l
    nr = neighborlist(l, 7.0) 
    @test is_unique(nr; self=true)

    unitcell=[1.0,1.0]
    for x in [nextfloat(0.1),prevfloat(0.9)]
        local l, nl, lr
        l = [[0.0,0.0],[x,0.0]] 
        nl = neighborlist(l, 0.1; unitcell=unitcell)
        @test length(nl) == 0
        lr = Ref(rotation(π/2)) .* l
        nl = neighborlist(l, 0.1; unitcell=unitcell)
        @test length(nl) == 0
    end
    for x in [-0.1,0.1,0.9]
        local l, nl, lr
        l = [[0.0,0.0],[x,0.0]] 
        nl = neighborlist(l, 0.1; unitcell=unitcell)
        @test length(nl) == 1
        lr = Ref(rotation(π/2)) .* l
        nl = neighborlist(l, 0.1; unitcell=unitcell)
        @test length(nl) == 1
    end

end

@testitem "Neighborlist with units" begin
    using CellListMap
    using Unitful
    using StaticArrays

    positions = [SVector(0.1, 0.0, 0.0), SVector(0.11, 0.01, 0.01) ]u"nm"
    cutoff = 0.1u"nm"
    nb = neighborlist(positions, cutoff)
    @test unit(nb[1][3]) == u"nm"

    # and with boundary coordinates (to test the fix for upper boundary shifts)
    l = [SVector(0.0, 0.0)u"nm", SVector(-1, 0.0)u"nm"]
    unitcell = [14.01, 14.02]u"nm"
    nl = neighborlist(l, 7.0u"nm")
    @test length(nl) == 1
    @test nl[1][3] ≈ 1.0u"nm"

end

@testitem "Compare with NearestNeighbors" begin

    using CellListMap
    using CellListMap.TestingNeighborLists
    using StaticArrays
    using NearestNeighbors

    r = 0.1

    for N in [2, 3]

        #
        # Using vectors as input
        #

        # With y smaller than x
        x = [rand(SVector{N,Float64}) for _ in 1:500]
        y = [rand(SVector{N,Float64}) for _ in 1:250]

        nb = nl_NN(BallTree, inrange, x, x, r)
        cl = CellListMap.neighborlist(x, r)
        @test is_unique(cl; self=true)
        @test compare_nb_lists(cl, nb, x, r)[1]

        nb = nl_NN(BallTree, inrange, x, y, r)
        cl = CellListMap.neighborlist(x, y, r, autoswap=false)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]
        cl = CellListMap.neighborlist(x, y, r, autoswap=true)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]

        # with x smaller than y
        x = [rand(SVector{N,Float64}) for _ in 1:500]
        y = [rand(SVector{N,Float64}) for _ in 1:1000]
        nb = nl_NN(BallTree, inrange, x, y, r)
        cl = CellListMap.neighborlist(x, y, r, autoswap=false)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]
        cl = CellListMap.neighborlist(x, y, r, autoswap=true)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]

        # Using matrices as input
        x = rand(N, 1000)
        y = rand(N, 500)

        nb = nl_NN(BallTree, inrange, x, x, r)
        cl = CellListMap.neighborlist(x, r)
        @test is_unique(cl; self=true)
        @test compare_nb_lists(cl, nb, x, r)[1]

        nb = nl_NN(BallTree, inrange, x, y, r)
        cl = CellListMap.neighborlist(x, y, r, autoswap=false)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]
        cl = CellListMap.neighborlist(x, y, r, autoswap=true)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]

        # with x smaller than y
        x = rand(N, 500)
        y = rand(N, 1000)
        nb = nl_NN(BallTree, inrange, x, y, r)
        cl = CellListMap.neighborlist(x, y, r, autoswap=false)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]
        cl = CellListMap.neighborlist(x, y, r, autoswap=true)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]

        # Check random coordinates to test the limits more thoroughly
        check_random_NN = true
        for i in 1:500
            x = rand(SVector{N,Float64}, 100)
            y = rand(SVector{N,Float64}, 50)
            nb = nl_NN(BallTree, inrange, x, y, r)
            cl = CellListMap.neighborlist(x, y, r, autoswap=false)
            @test is_unique(cl; self=false)
            check_random_NN = compare_nb_lists(cl, nb, x, y, r)[1]
        end
        @test check_random_NN

        # with different types
        x = rand(Float32, N, 500)
        y = rand(Float32, N, 1000)
        nb = nl_NN(BallTree, inrange, x, y, r)
        cl = CellListMap.neighborlist(x, y, r, autoswap=false)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]
        cl = CellListMap.neighborlist(x, y, r, autoswap=true)
        @test is_unique(cl; self=false)
        @test compare_nb_lists(cl, nb, x, y, r)[1]

    end

end


#
# some auxiliary functions for testing neighbor lists
#
module TestingNeighborLists

using LinearAlgebra: norm
using StaticArrays

export nl_NN
export compare_nb_lists
export is_unique
export x_rotation, y_rotation, z_rotation, random_rotation

function nl_NN(BallTree, inrange, x, y, r)
    balltree = BallTree(y)
    return inrange(balltree, x, r, true)
end

# for nb lists in a single set
function compare_nb_lists(list_CL, list_NN, x, r::AbstractFloat)
    for (i, j_list) in pairs(list_NN)
        for j in j_list
            if i == j # inrange will return self-pairs
                continue
            end
            ij_pairs = findall(p -> ((i,j) == (p[1],p[2])) || ((i,j) == (p[2],p[1])), list_CL)
            if length(ij_pairs) > 1
                println("Non-unique pair: ", join((i, j, ij_pairs)," "))
                return false, x, r
            end
            if length(ij_pairs) == 0
                if !(norm(x[i] - x[j]) / r ≈ 1)
                    println("Pair not found: ", join((i, j, ij_pairs, norm(x[i]-x[j]))," "))
                    return false, x, r
                else
                    println("Warning: pair not found with d = r: ", join((i, j, norm(x[i]-x[j])), " "))
                end
            end
        end
    end
    return true, nothing, nothing
end

# for nb lists in a single set
function compare_nb_lists(list_CL, list_NN, x, y, r::AbstractFloat)
    for (i, j_list) in pairs(list_NN)
        for j in j_list
            ij_pairs = findall(p -> (i,j) == (p[1],p[2]), list_CL)
            if length(ij_pairs) > 1
                println("Non-unique pair: ", join((i, j, j_list, list_CL[ij_pairs]), " "))
                return false, x, y, r
            end
            if length(ij_pairs) == 0
                if !(norm(x[i] - y[j]) / r ≈ 1)
                    println("Pair not found: ", join((i, j, ij_pairs, norm(x[i]-y[j])), " "))
                    return false, x, y, r
                else
                    println("Warning: pair not found with d = r: ", i, j, norm(x[i]-y[j]))
                end
            end
        end
    end
    return true, nothing, nothing, nothing
end
            
is_unique(list; self::Bool) = self ? is_unique_self(list) : is_unique_cross(list)
is_unique_cross(list) = length(list) == length(unique(p -> (p[1],p[2]), list))
is_unique_self(list) = length(list) == length(unique(p -> p[1] < p[2] ? (p[1],p[2]) : (p[2],p[1]), list))

# Functions that define rotations along each axis, given the angle in 3D
x_rotation(x) = @SMatrix[1 0 0; 0 cos(x) -sin(x); 0 sin(x) cos(x)]
y_rotation(x) = @SMatrix[cos(x) 0 sin(x); 0 1 0; -sin(x) 0 cos(x)]
z_rotation(x) = @SMatrix[cos(x) -sin(x) 0; sin(x) cos(x) 0; 0 0 1]
random_rotation() = z_rotation(2π*rand()) * y_rotation(2π*rand()) * x_rotation(2π*rand())

end # module TestingNeighborLists

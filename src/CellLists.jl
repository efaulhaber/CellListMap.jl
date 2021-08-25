#
# This file contains all structre types and functions necessary for building
# the CellList and CellListPair structures.
#

"""

$(TYPEDEF)

$(TYPEDFIELDS)

Copies particle coordinates and associated index, to build contiguous particle lists
in memory when building the cell lists. This strategy duplicates the particle coordinates
data, but is probably worth the effort.

"""
struct ParticleWithIndex{N,T}
    index::Int
    coordinates::SVector{N,T}
    real::Bool
end
Base.zero(::Type{ParticleWithIndex{N,T}}) where {N,T} =
    ParticleWithIndex{N,T}(0,zeros(SVector{N,T}),false)

"""

```
set_nt(cl) = max(1,min(cl.n_real_particles÷500,nthreads()))
```

Don't use all threads to build cell lists if the number of particles
per thread is smaller than 500.

"""
set_nt(cl) = max(1,min(cl.n_real_particles÷500,nthreads()))

"""

$(TYPEDEF)

$(TYPEDFIELDS)

This structure contains the cell linear index and the information 
about if this cell is in the border of the box (such that its 
neighbouring cells need to be wrapped) 

"""
Base.@kwdef struct Cell{N,T}
    linear_index::Int = 0
    cartesian_index::CartesianIndex{N} = CartesianIndex{N}(ntuple(i->0,N))
    center::SVector{N,T} = zeros(SVector{N,T})
    contains_real::Bool = false
    n_particles::Int = 0
    particles::Vector{ParticleWithIndex{N,T}} = Vector{ParticleWithIndex{N,T}}(undef,0)
end
function Cell{N,T}(cartesian_index::CartesianIndex,box::Box) where {N,T}
    return Cell{N,T}(
        linear_index=cell_linear_index(box.nc,cartesian_index),
        cartesian_index=cartesian_index,
        center=cell_center(cartesian_index,box)
    )
end

"""

$(TYPEDEF)

$(TYPEDFIELDS)

Auxiliary structure to contain projected particles.

"""
Base.@kwdef struct ProjectedParticle{N,T}
    index::Int = 0
    xproj::T = zero(T)
    coordinates::SVector{N,T} = zeros(SVector{N,T})
    real::Bool = false
end

"""

$(TYPEDEF)

$(TYPEDFIELDS)

Structure that contains the cell lists information.

"""
Base.@kwdef struct CellList{N,T}
    " Number of real particles. "
    n_real_particles::Int = 0
    " Number of cells. "
    number_of_cells::Int = 0
    " *mutable* number of particles in the computing box. "
    n_particles::Int = 0
    " *mutable* number of cells with real particles. "
    n_cells_with_real_particles::Int = 0
    " *mutable* number of cells with particles, real or images. "
    n_cells_with_particles::Int = 0
    " Auxiliary array that contains the indexes in list of the cells with particles, real or images. "
    cell_indices::Vector{Int} = zeros(Int,number_of_cells)
    " Auxiliary array that contains the indexes in the cells with real particles. "
    cell_indices_real::Vector{Int} = zeros(Int,0)
    " Vector containing cell lists of cells with particles. "
    cells::Vector{Cell{N,T}} = Cell{N,T}[]
    " Auxiliar array to store projected particles. "
    projected_particles::Vector{Vector{ProjectedParticle{N,T}}} = 
        [ Vector{ProjectedParticle{N,T}}(undef,0) for _ in 1:nthreads() ]
end
function Base.show(io::IO,::MIME"text/plain",cl::CellList)
    println(io,typeof(cl))
    println(io,"  $(cl.n_real_particles) real particles.")
    println(io,"  $(cl.n_cells_with_real_particles) cells with real particles.")
    print(io,"  $(cl.n_particles) particles in computing box, including images.")
end

"""

$(TYPEDEF)

$(TYPEDFIELDS)

Structure that will cointain the cell lists of two independent sets of
particles for cross-computation of interactions

"""
@with_kw struct CellListPair{V,N,T}
    ref::V
    target::CellList{N,T}
    swap::Bool
end      
function Base.show(io::IO,::MIME"text/plain",cl::CellListPair)
    print(io,typeof(cl),"\n")
    print(io,"   $(length(cl.ref)) particles in the reference vector.\n")
    print(io,"   $(cl.target.n_cells_with_real_particles) cells with real particles of target vector.")
end
  
"""

$(TYPEDEF)

$(TYPEDEF)

Auxiliary structure to carry threaded lists and ranges of particles to 
be considered by each thread on parallel construction. 

"""
@with_kw struct AuxThreaded{N,T}
    idxs::Vector{UnitRange{Int}} = Vector{UnitRange{Int}}(undef,0)
    lists::Vector{CellList{N,T}} = Vector{CellList{N,T}}(undef,0)
end
function Base.show(io::IO,::MIME"text/plain",aux::AuxThreaded)
    println(io,typeof(aux))
    print(io," Auxiliary arrays for nthreads = ", length(aux.lists)) 
end

"""

```
AuxThreaded(cl::CellList{N,T}) where {N,T}
```

Constructor for the `AuxThreaded` type, to be passed to `UpdateCellList!` for in-place 
update of cell lists. 

## Example
```julia-repl
julia> box = Box([250,250,250],10);

julia> x = [ 250*rand(3) for _ in 1:100_000 ];

julia> cl = CellList(x,box);

julia> aux = CellListMap.AuxThreaded(cl)
CellListMap.AuxThreaded{3, Float64}
 Auxiliary arrays for nthreads = 8

julia> cl = UpdateCellList!(x,box,cl,aux)
CellList{3, Float64}
  100000 real particles.
  31190 cells with real particles.
  1134378 particles in computing box, including images.

```
"""
function AuxThreaded(cl::CellList{N,T}) where {N,T}
    aux = AuxThreaded{N,T}()
    init_aux_threaded!(aux,cl)
    return aux
end

"""

```
AuxThreaded(cl::CellListPair{N,T}) where {N,T}
```

Constructor for the `AuxThreaded` type for lists of disjoint particle sets, 
to be passed to `UpdateCellList!` for in-place update of cell lists. 

## Example
```julia-repl
julia> box = Box([250,250,250],10);

julia> x = [ 250*rand(3) for i in 1:50_000 ];

julia> y = [ 250*rand(3) for i in 1:10_000 ];

julia> cl = CellList(x,y,box);

julia> aux = CellListMap.AuxThreaded(cl)
CellListMap.AuxThreaded{3, Float64}
 Auxiliary arrays for nthreads = 8

julia> cl = UpdateCellList!(x,box,cl,aux)
CellList{3, Float64}
  100000 real particles.
  31190 cells with real particles.
  1134378 particles in computing box, including images.

```
"""
function AuxThreaded(cl_pair::CellListPair{V,N,T}) where {V,N,T}
    aux = AuxThreaded{N,T}()
    init_aux_threaded!(aux,cl_pair.target)
    return aux
end

"""

```
init_aux_threaded!(aux::AuxThreaded,cl::CellList)
```

Given an `AuxThreaded` object initialized with zero-length arrays,
push `ntrheads` copies of `cl` into `aux.lists` and resize `aux.idxs`
to the number of threads.  

"""
function init_aux_threaded!(aux::AuxThreaded,cl::CellList)
   nt = set_nt(cl)
   push!(aux.lists,cl)
   for it in 2:nt
       push!(aux.lists,deepcopy(cl))
   end
   # Indices of the atoms that will be added by each thread
   nrem = cl.n_real_particles%nt
   nperthread = (cl.n_real_particles-nrem)÷nt
   first = 1
   for it in 1:nt
       nx = nperthread
       if it <= nrem
           nx += 1
       end
       push!(aux.idxs,first:(first-1)+nx)
       first += nx
   end
   return aux
end

"""

```
CellList(
    x::AbstractVector{AbstractVector},
    box::Box{UnitCellType,N,T};
    parallel::Bool=true
) where {UnitCellType,N,T} 
```

Function that will initialize a `CellList` structure from scracth, given a vector
or particle coordinates (a vector of vectors, typically of static vectors) 
and a `Box`, which contain the size ofthe system, cutoff, etc.  

### Example

```julia-repl
julia> box = Box([250,250,250],10);

julia> x = [ 250*rand(SVector{3,Float64}) for i in 1:100000 ];

julia> cl = CellList(x,box)
CellList{3, Float64}
  100000 real particles.
  15600 cells with real particles.
  126276 particles in computing box, including images.

```

"""
function CellList(
    x::AbstractVector{<:AbstractVector},
    box::Box{UnitCellType,N,T};
    parallel::Bool=true
) where {UnitCellType,N,T} 
    cl = CellList{N,T}(
        n_real_particles=length(x),
        number_of_cells=prod(box.nc)
    )
    return UpdateCellList!(x,box,cl,parallel=parallel)
end

"""

```
reset!(cl::CellList{N,T},box) where{N,T}
```

Restes a cell list, by setting everything to zero, but retaining
the allocated `particles` and `projected_particles` vectors. The 
`n_real_particles` number is also preserved, because it is used for
construction of auxiliary arrays for threading, and nothing else.

"""
function reset!(cl::CellList{N,T},box) where{N,T}
    number_of_cells = prod(box.nc) 
    if number_of_cells > length(cl.cells) 
        resize!(cl.cell_indices,number_of_cells)
        @. cl.cell_indices = 0
        @. cl.cell_indices_real = 0
    end
    for i in 1:cl.n_cells_with_particles
        cl.cells[i] = Cell{N,T}(
            n_particles=0,
            contains_real=false,
            particles=cl.cells[i].particles
        )
    end
    cl = CellList{N,T}(
        n_real_particles = cl.n_real_particles, 
        n_particles = 0,
        number_of_cells = number_of_cells,
        n_cells_with_real_particles = 0,
        n_cells_with_particles = 0,
        cell_indices = cl.cell_indices,
        cell_indices_real = cl.cell_indices_real,
        cells=cl.cells,
        projected_particles = cl.projected_particles
    )
    return cl
end

"""

```
CellList(
    x::AbstractVector{<:AbstractVector},
    y::AbstractVector{<:AbstractVector},
    box::Box{UnitCellType,N,T};
    parallel::Bool=true,
    autoswap::Bool=true
) where {UnitCellType,N,T} 
```

Function that will initialize a `CellListPair` structure from scracth, given two vectors
of particle coordinates and a `Box`, which contain the size of the system, cutoff, etc.
By default, the cell list will be constructed for smallest vector, but this is not always
the optimal choice. Using `autoswap=false` the cell list is constructed for the second (`y`)

### Example

```julia-repl
julia> box = Box([250,250,250],10);

julia> x = [ 250*rand(SVector{3,Float64}) for i in 1:1000 ];

julia> y = [ 250*rand(SVector{3,Float64}) for i in 1:10000 ];

julia> cl = CellList(x,y,box)
CellListMap.CellListPair{Vector{SVector{3, Float64}}, 3, Float64}
   10000 particles in the reference vector.
   961 cells with real particles of target vector.

julia> cl = CellList(x,y,box,autoswap=false)
CellListMap.CellListPair{Vector{SVector{3, Float64}}, 3, Float64}
   1000 particles in the reference vector.
   7389 cells with real particles of target vector.

```

"""
function CellList(
    x::AbstractVector{<:AbstractVector},
    y::AbstractVector{<:AbstractVector},
    box::Box{UnitCellType,N,T};
    parallel::Bool=true,
    autoswap=true
) where {UnitCellType,N,T} 
    if length(x) >= length(y) || !autoswap
        ref = [ SVector{N,T}(ntuple(i->el[i],N)...) for el in x ]
        target = CellList(y,box,parallel=parallel)
        swap = false
    else
        ref = [ SVector{N,T}(ntuple(i->el[i],N)...) for el in y ]
        target = CellList(x,box,parallel=parallel)
        swap = true
    end
    cl_pair = CellListPair(ref=ref,target=target,swap=swap)
    return cl_pair
end

"""

```
UpdateCellList!(
    x::AbstractVector{<:AbstractVector},
    box::Box,
    cl:CellList{N,T},
    parallel=true
) where {N,T}
```

Function that will update a previously allocated `CellList` structure, given new 
updated particle positions. This function will allocate new threaded auxiliary
arrays in parallel calculations. To preallocate these auxiliary arrays, use
the `UpdateCellList!(x,box,cl,aux)` method instead. 

## Example

```julia-repl
julia> box = Box([250,250,250],10);

julia> x = [ 250*rand(SVector{3,Float64}) for i in 1:1000 ];

julia> cl = CellList(x,box);

julia> box = Box([260,260,260],10);

julia> x = [ 260*rand(SVector{3,Float64}) for i in 1:1000 ];

julia> cl = UpdateCellList!(x,box,cl); # update lists

```

"""
function UpdateCellList!(
    x::AbstractVector{<:AbstractVector},
    box::Box,
    cl::CellList{N,T};
    parallel::Bool=true
) where {N,T}
    aux = AuxThreaded{N,T}()
    if parallel && nthreads() > 1
        init_aux_threaded!(aux,cl)
    end
    return UpdateCellList!(x,box,cl,aux,parallel=parallel)
end

"""

```
function UpdateCellList!(
    x::AbstractVector{<:AbstractVector},
    box::Box,
    cl::CellList{N,T},
    aux::AuxThreaded{N,T};
    parallel::Bool=true
) where {N,T}
```

Function that updates the cell list `cl` new coordinates `x` and possibly a new
box `box`, and receives a preallocated `aux` structure of auxiliary vectors for
threaded cell list construction. Given a preallocated `aux` vector, allocations in
this function should be minimal, only associated with the spawning threads, or
to expansion of the cell lists if the number of cells or number of particles 
increased. 

### Example

```julia-repl
julia> box = Box([250,250,250],10);

julia> x = [ 250*rand(SVector{3,Float64}) for i in 1:100000 ];

julia> cl = CellList(x,box);

julia> aux = CellListMap.AuxThreaded(cl)
CellListMap.AuxThreaded{3, Float64}
 Auxiliary arrays for nthreads = 8

julia> x = [ 250*rand(SVector{3,Float64}) for i in 1:100000 ];

julia> UpdateCellList!(x,box,cl,aux)
CellList{3, Float64}
  100000 real particles.
  15599 cells with real particles.
  125699 particles in computing box, including images.

```

To illustrate the expected ammount of allocations, which are a consequence
of thread spawning only:

```julia-repl
julia> using BenchmarkTools

julia> @btime UpdateCellList!(\$x,\$box,\$cl,\$aux)
  16.384 ms (41 allocations: 3.88 KiB)
CellList{3, Float64}
  100000 real particles.
  15599 cells with real particles.
  125699 particles in computing box, including images.

julia> @btime UpdateCellList!(\$x,\$box,\$cl,\$aux,parallel=false)
  20.882 ms (0 allocations: 0 bytes)
CellList{3, Float64}
  100000 real particles.
  15603 cells with real particles.
  125896 particles in computing box, including images.

```

"""
function UpdateCellList!(
    x::AbstractVector{<:AbstractVector},
    box::Box,
    cl::CellList{N,T},
    aux::AuxThreaded{N,T};
    parallel::Bool=true
) where {N,T}

    # Add particles to cell list
    nt = set_nt(cl)
    if !parallel || nt < 2
        cl = reset!(cl,box)
        cl = add_particles!(x,box,0,cl)
    else
        # Cell lists to be built by each thread
        @threads for it in 1:nt
             aux.lists[it] = reset!(aux.lists[it],box)
             xt = @view(x[aux.idxs[it]])  
             aux.lists[it] = add_particles!(xt,box,aux.idxs[it][1]-1,aux.lists[it])
        end
        # Merge threaded cell lists
        cl = aux.lists[1]
        for it in 2:nt
            cl = merge_cell_lists!(cl,aux.lists[it])
        end
    end
  
    # allocate, or update the auxiliary projected_particles arrays
    maxnp = 0
    for i in 1:cl.n_cells_with_particles
        maxnp = max(maxnp,cl.cells[i].n_particles)
    end
    if maxnp > length(cl.projected_particles[1])
        for i in 1:nthreads()
            resize!(cl.projected_particles[i],maxnp)
        end
    end

    return cl
end

"""

```
add_particles!(x,box,ishift,cl::CellList{N,T}) where {N,T}
```

Add all particles in vector `x` to the cell list `cl`. `ishift` is the shift in particle
index, meaning that particle `i` of vector `x` corresponds to the particle with original
index `i+ishift`. The shift is used to construct cell lists from fractions of the original
set of particles in parallel list construction.  

"""
function add_particles!(x,box,ishift,cl::CellList{N,T}) where {N,T}
    for ip in eachindex(x)
        xp = x[ip] 
        p = SVector{N,T}(ntuple(i->xp[i],N)) # in case the input was not static
        p = wrap_to_first(p,box)
        cl = add_particle_to_celllist!(ishift+ip,p,box,cl) # add real particle
        cl = replicate_particle!(ishift+ip,p,box,cl) # add virtual particles to border cells
    end
    return cl
end

"""

```
merge_cell_lists!(cl::CellList,aux::CellList)
```

Merges an auxiliary `aux` cell list to `cl`, and returns the modified `cl`. Used to
merge cell lists computed in parallel threads.

"""
function merge_cell_lists!(cl::CellList,aux::CellList)
    # Accumulate number of particles
    @set! cl.n_particles += aux.n_particles
    for icell in 1:aux.n_cells_with_particles
        cell = aux.cells[icell]
        linear_index = cell.linear_index
        # If cell was yet not initialized in merge, push it to the list
        if cl.cell_indices[linear_index] == 0
            @set! cl.n_cells_with_particles += 1
            if length(cl.cells) >= cl.n_cells_with_particles
                cl.cells[cl.n_cells_with_particles] = cell 
            else
                push!(cl.cells,cell)
            end
            cl.cell_indices[linear_index] = cl.n_cells_with_particles
            if cell.contains_real
                @set! cl.n_cells_with_real_particles += 1
                if cl.n_cells_with_real_particles > length(cl.cell_indices_real)
                    push!(cl.cell_indices_real,cl.cell_indices[linear_index])
                else
                    cl.cell_indices_real[cl.n_cells_with_real_particles] = cl.cell_indices[linear_index] 
                end
            end
        # Append particles to initialized cells
        else
            cell_index = cl.cell_indices[linear_index]
            prevcell = cl.cells[cell_index] 
            n_particles_old = prevcell.n_particles
            @set! prevcell.n_particles += cell.n_particles
            if prevcell.n_particles > length(prevcell.particles)
                resize!(prevcell.particles,prevcell.n_particles)
            end
            for ip in 1:cell.n_particles
                prevcell.particles[n_particles_old+ip] = cell.particles[ip]
            end
            cl.cells[cell_index] = prevcell
            if (!cl.cells[cl.cell_indices[linear_index]].contains_real) && cell.contains_real 
                cl_cell = cl.cells[cl.cell_indices[linear_index]]
                @set! cl_cell.contains_real = true
                cl.cells[cl.cell_indices[linear_index]] = cl_cell
                @set! cl.n_cells_with_real_particles += 1
                if cl.n_cells_with_real_particles > length(cl.cell_indices_real)
                    push!(cl.cell_indices_real,cl.cell_indices[linear_index])
                else
                    cl.cell_indices_real[cl.n_cells_with_real_particles] = cl.cell_indices[linear_index]
                end
            end
        end
    end
    return cl
end

"""

```
add_particle_to_celllist!(
    ip,
    x::SVector{N,T},
    box,
    cl::CellList{N,T};
    real_particle::Bool=true
) where {N,T}
```

Adds one particle to the cell lists, updating all necessary arrays.

"""
function add_particle_to_celllist!(
    ip,
    x::SVector{N,T},
    box,
    cl::CellList{N,T};
    real_particle::Bool=true
) where {N,T}
    @unpack n_particles,
            n_cells_with_real_particles,
            n_cells_with_particles,
            cell_indices,
            cell_indices_real,
            cells = cl

    # Cell of this particle
    n_particles += 1 
    cartesian_index = particle_cell(x,box)
    linear_index = cell_linear_index(box.nc,cartesian_index)

    #
    # Check if this is the first particle of this cell
    #
    if cell_indices[linear_index] == 0
        n_cells_with_particles += 1
        cell_indices[linear_index] = n_cells_with_particles
        if n_cells_with_particles > length(cells)
            cell = Cell{N,T}(cartesian_index,box)
        else
            cell = cells[n_cells_with_particles]
            @set! cell.linear_index = linear_index
            @set! cell.cartesian_index = cartesian_index
            @set! cell.center = cell_center(cell.cartesian_index,box)
            @set! cell.contains_real = false
        end
        @set! cell.n_particles = 1
    else
        cell = cells[cell_indices[linear_index]]
        @set! cell.n_particles += 1
    end
    #
    # Cells with real particles are annotated to be run over
    #
    if real_particle && (!cell.contains_real)
        @set! cell.contains_real = true
        n_cells_with_real_particles += 1
        if n_cells_with_real_particles > length(cell_indices_real)
            push!(cell_indices_real,cell_indices[linear_index])
        else
            cell_indices_real[n_cells_with_real_particles] = cell_indices[linear_index] 
        end
    end

    #
    # Add particle to cell list
    #
    p = ParticleWithIndex(ip,x,real_particle) 
    if cell.n_particles > length(cell.particles)
        push!(cell.particles,p)
    else
        cell.particles[cell.n_particles] = p
    end

    #
    # Update (imutable) cell in list
    #
    @set! cl.n_particles = n_particles
    @set! cl.cell_indices = cell_indices
    @set! cl.cell_indices_real = cell_indices_real
    @set! cl.n_cells_with_particles = n_cells_with_particles
    @set! cl.n_cells_with_real_particles = n_cells_with_real_particles
    if n_cells_with_particles > length(cl.cells)
        push!(cl.cells,cell)
    else
        cl.cells[cell_indices[linear_index]] = cell
    end

    return cl
end

"""

```
UpdateCellList!(
  x::AbstractVector{<:AbstractVector},
  y::AbstractVector{<:AbstractVector},
  box::Box{UnitCellType,N,T},
  cl:CellListPair,
  parallel=true
) where {UnitCellType,N,T}
```

Function that will update a previously allocated `CellListPair` structure, given 
new updated particle positions, for example. This method will allocate new 
`aux` threaded auxiliary arrays. For a non-allocating version, see the 
`UpdateCellList!(x,y,box,cl,aux)` method.

```julia-repl
julia> box = Box([250,250,250],10);

julia> x = [ 250*rand(SVector{3,Float64}) for i in 1:1000 ];

julia> y = [ 250*rand(SVector{3,Float64}) for i in 1:10000 ];

julia> cl = CellList(x,y,box);

julia> cl = UpdateCellList!(x,y,box,cl); # update lists

```

"""
function UpdateCellList!(
    x::AbstractVector{<:AbstractVector},
    y::AbstractVector{<:AbstractVector},
    box::Box{UnitCellType,N,T},
    cl_pair::CellListPair;
    parallel::Bool=true
) where {UnitCellType,N,T}
    aux = AuxThreaded{N,T}()
    if parallel && nthreads() > 1
        init_aux_threaded!(aux,cl_pair.target)
    end
    return UpdateCellList!(x,y,box,cl_pair,aux,parallel=parallel)
end

"""

```
function UpdateCellList!(
    x::AbstractVector{<:AbstractVector},
    y::AbstractVector{<:AbstractVector},
    box::Box{UnitCellType,N,T},
    cl_pair::CellListPair,
    aux::AuxThreaded{N,T};
    parallel::Bool=true
) where {UnitCellType,N,T}
```

This function will update the `cl_pair` structure that contains the cell lists
for disjoint sets of particles. It receives the preallocated `aux` structure to
avoid reallocating auxiliary arrays necessary for the threaded construct of the
lists. 

### Example

```julia-repl
julia> box = Box([250,250,250],10);

julia> x = [ 250*rand(3) for i in 1:50_000 ];

julia> y = [ 250*rand(3) for i in 1:10_000 ];

julia> cl = CellList(x,y,box)
CellListMap.CellListPair{Vector{SVector{3, Float64}}, 3, Float64}
   50000 particles in the reference vector.
   7381 cells with real particles of target vector.

julia> aux = CellListMap.AuxThreaded(cl)
CellListMap.AuxThreaded{3, Float64}
 Auxiliary arrays for nthreads = 8

julia> x = [ 250*rand(3) for i in 1:50_000 ];

julia> y = [ 250*rand(3) for i in 1:10_000 ];

julia> cl = UpdateCellList!(x,y,box,cl,aux)
CellList{3, Float64}
  10000 real particles.
  7358 cells with real particles.
  12591 particles in computing box, including images.

```
To illustrate the expected ammount of allocations, which are a consequence
of thread spawning only:

```julia-repl
julia> using BenchmarkTools

julia> @btime UpdateCellList!(\$x,\$y,\$box,\$cl,\$aux)
  715.661 μs (41 allocations: 3.88 KiB)
CellListMap.CellListPair{Vector{SVector{3, Float64}}, 3, Float64}
   50000 particles in the reference vector.
   7414 cells with real particles of target vector.
   
julia> @btime UpdateCellList!(\$x,\$y,\$box,\$cl,\$aux,parallel=false)
   13.042 ms (0 allocations: 0 bytes)
 CellListMap.CellListPair{Vector{SVector{3, Float64}}, 3, Float64}
    50000 particles in the reference vector.
    15031 cells with real particles of target vector.
 
```

"""
function UpdateCellList!(
    x::AbstractVector{<:AbstractVector},
    y::AbstractVector{<:AbstractVector},
    box::Box{UnitCellType,N,T},
    cl_pair::CellListPair,
    aux::AuxThreaded{N,T};
    parallel::Bool=true
) where {UnitCellType,N,T}
    if !cl_pair.swap 
        target = UpdateCellList!(x,box,cl_pair.target,aux,parallel=parallel)
    else
        target = UpdateCellList!(y,box,cl_pair.target,aux,parallel=parallel)
    end
    cl_pair = CellListPair(ref=cl_pair.ref,target=target,swap=cl_pair.swap)
    return cl_pair
end

"""

```
particles_per_cell(cl::CellList,box::Box)
```

Returns the average number of particles per computing cell.

"""
particles_per_cell(cl::CellList,box::Box) = cl.ncp[1] / prod(box.nc)


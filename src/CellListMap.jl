module CellListMap

using Base.Threads
using Parameters
using StaticArrays
using DocStringExtensions

export CellLists, CellLists!, Box
export map_pairwise!

"""

$(TYPEDEF)

Structure that contains some data required to compute the linked cells. To
be initialized with the box size and cutoff. 

## Example

```julia-repl
julia> sides = [250,250,250];

julia> cutoff = 10.;

julia> box = Box(sides,cutoff)

julia> box = Box(sides,cutoff)
Box{3}
  sides: SVector{3, Int64}
  nc: SVector{3, Int64}
  l: SVector{3, Float64}
  cutoff: Float64 10.0
  cutoff_sq: Float64 100.0

```

"""
Base.@kwdef struct Box{N,T}
  sides::SVector{N,T}
  nc::SVector{N,Int}
  cell_side::SVector{N,T}
  cutoff::T
  cutoff_sq::T
end
function Box(sides::AbstractVector, cutoff, T::DataType)
  N = length(sides)
  nc = SVector{N,Int}(max.(1,trunc.(Int,sides/cutoff)))
  l = SVector{N,T}(sides ./ nc)
  return Box{N,T}(SVector{N,T}(sides),nc,l,cutoff,cutoff^2)
end
Box(sides::AbstractVector,cutoff;T::DataType=Float64) =
  Box(sides,cutoff,T)

"""

$(TYPEDEF)

Copies particle coordinates and associated index, to build contiguous atom lists
in memory when building the cell lists. This strategy duplicates the atomic coordinates
data, but is probably worth the effort.

"""
struct AtomWithIndex{N,T}
  index::Int
  coordinates::SVector{N,T}
end

"""

$(TYPEDEF)

Structure that contains the cell lists information.

"""
Base.@kwdef struct CellLists{N,T}
  ncwp::Vector{Int} # One-element vector to contain the mutable number of cells with particles
  cwp::Vector{Int} # Indexes of the unique cells With Particles
  ncp::Vector{Int} # Number of cell particles
  fp::Vector{AtomWithIndex{N,T}} # First particle of cell 
  np::Vector{AtomWithIndex{N,T}} # Next particle of cell
end

# Structure that will cointain the cell lists of two independent sets of
# atoms for cross-computation of interactions
struct CellListsPair{N,T}
  small::CellLists{N,T}
  large::CellLIsts{N,T}
end
  

"""

```
CellLists(x::AbstractVector{SVector{N,T}},box::Box{N}) where {N,T}
```

Function that will initialize a `CellLists` structure from scracth, given a vector
or particle coordinates (as `SVector`s) and a `Box`, which contain the size ofthe
system, cutoff, etc.  

"""
function CellLists(x::AbstractVector{SVector{N,T}},box::Box{N}) where {N,T} 
  number_of_particles = length(x)
  number_of_cells = prod(box.nc)
  ncwp = zeros(Int,1)
  cwp = zeros(Int,number_of_cells)
  ncp = zeros(Int,number_of_cells)
  fp = fill(AtomWithIndex{N,T}(0,SVector{N,T}(ntuple(i->zero(T),N))),number_of_cells)
  np = fill(AtomWithIndex{N,T}(0,SVector{N,T}(ntuple(i->zero(T),N))),number_of_particles)
  cl = CellLists{N,T}(ncwp,cwp,ncp,fp,np)
  return CellLists!(x,box,cl)
end

"""

```
CellLists(x::AbstractVector{SVector{N,T}},y::AbstractVector{SVector{N,T}},box::Box{N}) where {N,T}
```

Function that will initialize a `CellListsPair` structure from scracth, given two vectors
of particle coordinates and a `Box`, which contain the size ofthe
system, cutoff, etc.  

"""
function CellLists(
  x::AbstractVector{SVector{N,T}},
  y::AbstractVector{SVector{N,T}},
  box::Box{N}
) where {N,T} 

  x_cl = CellLists(x,box)
  y_cl = CellLists(y,box)

  if length(x) <= length(y)
    cl_pair = CellListsPair{N,T}(x_cl,y_cl)
  else
    cl_pair = CellListsPair{N,T}(y_cl,x_cl)
  end

  return cl_pair
end

"""

```
CellLists!(x::AbstractVector{SVector{N,T}},box::Box{N},cl:CellLists{N,T}) where {N,T}
```

Function that will update a previously allocated `CellList` structure, given new updated
particle positions, for example.

"""
function CellLists!(x::AbstractVector{SVector{N,T}},box::Box{N},cl::CellLists{N,T}) where {N,T}
  @unpack ncwp, cwp, ncp, fp, np = cl
  ncwp[1] = 0
  fill!(cwp,0)
  fill!(ncp,0)
  fill!(fp,AtomWithIndex{N,T}(0,SVector{N,T}(ntuple(i->zero(T),N))))
  fill!(np,AtomWithIndex{N,T}(0,SVector{N,T}(ntuple(i->zero(T),N)))) 

  # Initialize cell, firstatom and nexatom
  for (ip,xip) in pairs(x)
    p = AtomWithIndex(ip,xip)
    icell_cartesian = particle_cell(xip,box)
    icell = cell_linear_index(box.nc,icell_cartesian)
    if fp[icell].index == 0
      ncwp[1] += 1
      cwp[ncwp[1]] = icell
      ncp[icell] = 1
    else
      ncp[icell] += 1
    end
    np[ip] = fp[icell]
    fp[icell] = p
  end

  return cl
end

"""

```
CellLists!(x::AbstractVector{SVector{N,T}},y::AbstractVector{SVector{N,T}},box::Box{N},cl:CellLists{N,T}) where {N,T}
```

Function that will update a previously allocated `CellList2` structure, given new updated
particle positions, for example.

"""
function CellLists!(
  x::AbstractVector{SVector{N,T}},
  y::AbstractVector{SVector{N,T}},
  box::Box{N},cl::CellLists{N,T},
  cl_pair::CellListPair{N,T},
) where {N,T}

  if length(x) <= length(y)
    CellLists!(x,box,cl_pair.small)
    CellLists!(y,box,cl_pair.large)
  else
    CellLists!(x,box,cl_pair.large)
    CellLists!(y,box,cl_pair.small)
  end

  return cl_pair
end
"""

```
distance_sq(x,y)
```

Function to compute squared Euclidean distances between two n-dimensional vectors.

"""
@inline function distance_sq(x::AbstractVector{T}, y::AbstractVector{T}) where T
  @assert length(x) == length(y)
  d = zero(T)
  @inbounds for i in eachindex(x)
    d += (x[i]-y[i])^2
  end
  return d
end

"""

```
distance(x,y)
```

Function to compute Euclidean distances between two n-dimensional vectors.

"""
@inline distance(x::AbstractVector{T}, y::AbstractVector{T}) where T =
  sqrt(distance_sq(x,y))

"""

```
particle_cell(x::AbstractVector{T}, box::Box{N}) where N
```

Returns the coordinates of the cell to which a particle belongs, given its coordinates
and the sides of the periodic box (for arbitrary dimension N).

"""
function particle_cell(x::AbstractVector, box::Box{N}) where N
  # Wrap to origin
  xwrapped = wrapone(x,box.sides)
  cell = SVector{N,Int}(
    ntuple(i -> floor(Int,(xwrapped[i]+box.sides[i]/2)/box.cell_side[i])+1, N)
  )
  return cell
end
"""

```
cell_cartesian_indices(nc::SVector{N,Int}, i1D) where {N}
```

Given the linear index of the cell in the cell list, returns the cartesian indexes
of the cell (for arbitrary dimension N).


"""
cell_cartesian_indices(nc::SVector{N,Int}, i1D) where {N} = 
  CartesianIndices(ntuple(i -> nc[i],N))[i1D]

"""
```
icell1D(nc::SVector{N,Int}, indexes) where N
```
Returns the index of the cell, in the 1D representation, from its cartesian coordinates. 

"""
cell_linear_index(nc::SVector{N,Int}, indexes) where N =
  LinearIndices(ntuple(i -> nc[i],N))[ntuple(i->indexes[i],N)...]

"""

```
function wrap!(x::AbstractVector, sides::AbstractVector, center::AbstractVector)
```

Functions that wrap the coordinates They modify the coordinates of the input vector.  
Wrap to a given center of coordinates

"""
function wrap!(x::AbstractVector, sides::AbstractVector, center::AbstractVector)
  for i in eachindex(x)
    x[i] = wrapone(x[i],sides,center)
  end
  return nothing
end

@inline function wrapone(x::AbstractVector, sides::AbstractVector, center::AbstractVector)
  s = @. (x-center)%sides
  s = @. wrapx(s,sides) + center
  return s
end

@inline function wrapx(x,s)
  if x > s/2
    x = x - s
  elseif x < -s/2
    x = x + s
  end
  return x
end

"""

```
wrap!(x::AbstractVector, sides::AbstractVector)
```

Wrap to origin (slightly cheaper).

"""
function wrap!(x::AbstractVector, sides::AbstractVector)
  for i in eachindex(x)
    x[i] = wrapone(x[i],sides)
  end
  return nothing
end

@inline function wrapone(x::AbstractVector, sides::AbstractVector)
  s = @. x%sides
  s = @. wrapx(s,sides)
  return s
end

"""

```
wrap_cell(nc::SVector{N,Int}, indexes) where N
```

Given the dimension `N` of the system, return the periodic cell which correspondst to
it, if the cell is outside the main box.

"""
@inline function wrap_cell(nc::SVector{N,Int}, indexes) where N
  cell_indexes = ntuple(N) do i
    ind = indexes[i]
    if ind < 1
      ind = nc[i] + ind
    elseif ind > nc[i]
      ind = ind - nc[i]
    end
    return ind
  end
  return cell_indexes
end

"""

```
map_pairwise!(f::Function,output,x::AbstractVector,box::Box,lc::LinkedLists)
```

This function will run over every pair of particles which are closer than `box.cutoff` and compute
the Euclidean distance between the particles, considering the periodic boundary conditions given
in the `Box` structure. If the distance is smaller than the cutoff, a function `f` of the coordinates
of the two particles will be computed. 

The function `f` receives six arguments as input: 
```
f(x,y,i,j,d2,output)
```
Which are the coordinates of one particle, the coordinates of the second particle, the index of the first particle, the index of the second particle, the squared distance between them, and the `output` variable. It has also to return the same `output` variable. Thus, `f` may or not mutate `output`, but in either case it must return it. With that, it is possible to compute an average property of the distance of the particles or, for example, build a histogram. The squared distance `d2` is computed internally for comparison with the `cutoff`, and is passed to the `f` because many times it is used for the desired computation. 

## Example

Computing the mean difference in `x` position between random particles, remembering the number of pairs of `n` particles is `n(n-1)/2`. The function does not use the indices or the distance, such that we remove them from the parameters by using a closure.

```julia-repl
julia> n = 100_000;

julia> box = Box([250,250,250],10);

julia> x = [ box.sides .* rand(SVector{3,Float64}) for i in 1:n ];

julia> cl = CellLists(x,box);

julia> f(x,y,sum_dx) = sum_dx + x[1] - y[1] 

julia> normalization = N / (N*(N-1)/2) # (number of particles) / (number of pairs)

julia> avg_dx = normalization * map_parwise!((x,y,i,j,d2,sum_dx) -> f(x,y,sum_dx), 0.0, x, box, cl)

```

Computing the histogram of the distances between particles (considering the same particles as in the above example). Again,
the function does not use the indices, but uses the distance, which are removed from the function call using a closure:

```
julia> function build_histogram!(x,y,d2,hist)
         d = sqrt(d2)
         ibin = floor(Int,d) + 1
         hist[ibin] += 1
         return hist
       end;

julia> hist = zeros(Int,10);

julia> normalization = N / (N*(N-1)/2) # (number of particles) / (number of pairs)

julia> hist = normalization * map_pairwise!((x,y,i,j,d2,hist) -> build_histogram!(x,y,d2,hist),hist,x,box,cl)

```

In this test we compute the "gravitational potential", pretending that each particle
has a different mass. In this case, the closure is used to pass the masses to the
function that computes the potential.

```julia
# masses
mass = rand(N)

# Function to be evalulated for each pair: build distance histogram
function potential(x,y,i,j,d2,u,mass)
  d = sqrt(d2)
  u = u - 9.8*mass[i]*mass[j]/d
  return u
end

# Run pairwise computation
u = map_pairwise!((x,y,i,j,d2,u) -> potential(x,y,i,j,d2,u,mass),0.0,x,box,cl)
```

The example above can be run with `CellLists.test3()`.


"""
function map_pairwise!(
  f::Function, output, 
  x::AbstractVector,
  box::Box, cl::CellLists;
  # Parallelization options
  parallel::Bool=true,
  output_threaded=(parallel ? [ deepcopy(output) for i in 1:nthreads() ] : nothing),
  reduce::Function=reduce
)
  if parallel && nthreads() > 1
    output = map_pairwise_parallel_self!(
      (x,y,i,j,d2,output)->f(x,y,i,j,d2,output),
      output,x,box,cl;
      output_threaded=output_threaded,
      reduce=reduce
    )
  else
    output = map_pairwise_serial_self!(
      (x,y,i,j,d2,output)->f(x,y,i,j,d2,output),
      output,x,box,cl
    )
  end
  return output
end

function map_pairwise_serial_self!(
  f::Function, output, 
  x::AbstractVector,
  box::Box, cl::CellLists
)
  for icell in 1:cl.ncwp[1]
    output = inner_loop!(
      (x,y,i,j,d2,output)->f(x,y,i,j,d2,output),
      box,icell,cl,output
    ) 
  end 
  return output
end

function map_pairwise_parallel_self!(
  f::Function, output, 
  x::AbstractVector,
  box::Box, cl::CellLists;
  output_threaded=output_threaded,
  reduce::Function=reduce
)

  # loop over cells that contain particles
  @threads for icell in 1:cl.ncwp[1]
    it = threadid()
    output_threaded[it] = inner_loop!(
      (x,y,i,j,d2,output)->f(x,y,i,j,d2,output),
      box,icell,cl,output_threaded[it]
    ) 
  end 

  output = reduce(output,output_threaded)
  return output
end

function inner_loop!(f,box,icell,cl,output)
  @unpack sides, nc, cutoff_sq = box
  ic = cl.cwp[icell]
  ic_cartesian = cell_cartesian_indices(nc,ic)

  # loop over list of non-repeated particles of cell ic
  pᵢ = cl.fp[ic]
  for incp in 1:cl.ncp[ic]-1
    i = pᵢ.index
    xpᵢ = pᵢ.coordinates
    pⱼ = cl.np[pᵢ.index] 
    for jncp in incp+1:cl.ncp[ic]
      j = pⱼ.index
      xpⱼ = wrapone(pⱼ.coordinates,sides,xpᵢ)
      d2 = distance_sq(xpᵢ,xpⱼ)
      if d2 <= cutoff_sq
        output = f(xpᵢ,xpⱼ,i,j,d2,output)
      end
      pⱼ = cl.np[pⱼ.index]
    end
    pᵢ = cl.np[pᵢ.index]
  end

  # cells that share faces
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex((+1, 0, 0)))
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex(( 0,+1, 0)))
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex(( 0, 0,+1)))

  # Interactions of cells that share axes
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex((+1,+1, 0)))
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex((+1, 0,+1)))
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex((+1,-1, 0)))
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex((+1, 0,-1)))
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex(( 0,+1,+1)))
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex(( 0,+1,-1)))

  # Interactions of cells that share vertices
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex((+1,+1,+1)))
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex((+1,+1,-1)))
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex((+1,-1,+1)))
  output = cell_output!(f,box,ic,cl,output,ic_cartesian+CartesianIndex((+1,-1,-1)))

  return output
end

function cell_output!(f,box,ic,cl,output,jc_cartesian)
  @unpack sides, nc, cutoff_sq = box
  jc_cartesian_wrapped = wrap_cell(nc,jc_cartesian)
  jc = cell_linear_index(nc,jc_cartesian_wrapped)

  # loop over list of non-repeated particles of cell ic
  pᵢ = cl.fp[ic]
  for _ in 1:cl.ncp[ic]
    i = pᵢ.index
    xpᵢ = pᵢ.coordinates
    pⱼ = cl.fp[jc]
    for _ in 1:cl.ncp[jc]
      j = pⱼ.index
      xpⱼ = wrapone(pⱼ.coordinates,sides,xpᵢ)
      d2 = distance_sq(xpᵢ,xpⱼ)
      if d2 <= cutoff_sq
        output = f(xpᵢ,xpⱼ,i,j,d2,output)
      end
      pⱼ = cl.np[pⱼ.index]
    end
    pᵢ = cl.np[pᵢ.index]
  end

  return output
end

#
# Functions to reduce the output of common options (vectors of numbers 
# and vectors of vectors)
#
reduce(output::Number, output_threaded::Vector{<:Number}) = sum(output_threaded)
function reduce(output::AbstractVector, output_threaded::AbstractVector{<:AbstractVector}) 
  for i in 1:nthreads()
    @. output += output_threaded[i]
  end
  return output
end

#
# Function that uses the naive algorithm, for testing
#
function map_naive!(f,output,x,box)
  @unpack sides, cutoff_sq = box
  for i in 1:length(x)-1
    xᵢ = x[i]
    for j in i+1:length(x)
      xⱼ = wrapone(x[j],sides,xᵢ)
      d2 = distance_sq(xᵢ,xⱼ) 
      if d2 <= cutoff_sq
        output = f(xᵢ,xⱼ,i,j,d2,output)
      end
    end
  end
  return output
end

#
# Function that uses the naive algorithm, for testing
#
function map_naive_two!(f,output,x,y,box)
  @unpack sides, cutoff_sq = box
  for i in 1:length(x)
    xᵢ = x[i]
    for j in 1:length(y)
      yⱼ = wrapone(y[j],sides,xᵢ)
      d2 = distance_sq(xᵢ,yⱼ) 
      if d2 <= cutoff_sq
        output = f(xᵢ,yⱼ,i,j,d2,output)
      end
    end
  end
  return output
end

#
# Test examples
#
include("./examples.jl")

end # module



#
# Functions to deal with large and dense system, avoiding the maximum number
# of unnecessary loop iterations over non-interacting particles
#

"""

```
UpdateCellList!(
    x::AbstractVector{SVector{N,T}},
    box::Box,cl:CellList{LargeDenseSystem,N,T},
    parallel=true
) where {N,T}
```

Function that will update a previously allocated `CellList` structure, given new updated particle 
positions of large and dense systems.

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
  x::AbstractVector{SVector{N,T}},
  box::Box,
  cl::CellList{LargeDenseSystem,N,T};
  parallel::Bool=true
) where {N,T}
  @unpack cwp, fp, np, npcell = cl

  number_of_cells = prod(box.nc)
  if number_of_cells > length(cwp) 
    number_of_cells = ceil(Int,1.1*number_of_cells) # some margin in case of box size variations
    resize!(cwp,number_of_cells)
    resize!(fp,number_of_cells)
    resize!(npcell,number_of_cells)
  end

  cl.ncwp[1] = 0
  if parallel
    @threads for i in eachindex(cwp)
      cwp[i] = zero(Cell{N,T})
      fp[i] = zero(AtomWithIndex{N,T})
      npcell[i] = 0
    end
    @threads for i in eachindex(np)
      np[i] = zero(AtomWithIndex{N,T})
    end
  else
    fill!(cwp,zero(Cell{N,T}))
    fill!(fp,zero(AtomWithIndex{N,T}))
    fill!(np,zero(AtomWithIndex{N,T}))
    fill!(npcell,0)
  end

  #
  # The following part cannot be *easily* paralelized, because 
  # there is concurrency on the construction of the cell lists
  #

  #
  # Add virtual particles to edge cells
  #
  for (ip,particle) in pairs(x)
    p = wrap_to_first(particle,box.unit_cell)
    cl = replicate_particle!(ip,p,box,cl)
  end
  #
  # Add true particles, such that the first particle of each cell is
  # always a true particle
  #
  for (ip,particle) in pairs(x)
    p = wrap_to_first(particle,box.unit_cell)
    cl = add_particle_to_celllist!(ip,p,box,cl) 
  end

  return cl
end

"""

Set one index of a cell list

"""
function add_particle_to_celllist!(
  ip,
  x::SVector{N,T},
  box,
  cl::CellList{LargeDenseSystem,N,T};
  real_particle::Bool=true
) where {N,T}
  @unpack cell_size = box
  @unpack ncp, ncwp, cwp, fp, np, npcell = cl
  ncp[1] += 1
  icell_cartesian = particle_cell(x,box)
  icell = cell_linear_index(box.nc,icell_cartesian)
  # Cells starting with real particles are annotated to be run over
  if fp[icell].index == 0
    npcell[icell] = 1
    if real_particle 
      ncwp[1] += 1
      cwp[ncwp[1]] = Cell{N,T}(icell,icell_cartesian,cell_center(icell_cartesian,cell_size))
    end
  else
    npcell[icell] += 1
  end
  if ncp[1] > length(np) 
    old_length = length(np)
    resize!(np,ceil(Int,1.2*old_length))
    for i in old_length+1:length(np)
      np[i] = zero(AtomWithIndex{N,T}) 
    end
  end
  np[ncp[1]] = fp[icell]
  fp[icell] = AtomWithIndex(ncp[1],ip,x) 
  return cl
end

#
# Serial version for self-pairwise computations
#
function map_pairwise_serial!(
  f::F, output, box::Box, cl::CellList{LargeDenseSystem,N,T}; 
  show_progress::Bool=false
) where {F,N,T}
  show_progress && (p = Progress(cl.ncwp[1],dt=1))
  for icell in 1:cl.ncwp[1]
    output = inner_loop!(f,box,icell,cl,output) 
    show_progress && next!(p)
  end
  return output
end

#
# Parallel version for self-pairwise computations
#
function map_pairwise_parallel!(
  f::F1, output, box::Box, cl::CellList{LargeDenseSystem,N,T};
  output_threaded=output_threaded,
  reduce::F2=reduce,
  show_progress::Bool=false
) where {F1,F2,N,T}
  show_progress && (p = Progress(cl.ncwp[1],dt=1))
  @threads for it in 1:nthreads() 
    for icell in splitter(it,cl.ncwp[1])
      output_threaded[it] = inner_loop!(f,box,icell,cl,output_threaded[it]) 
      show_progress && next!(p)
    end
  end 
  output = reduce(output,output_threaded)
  return output
end

function inner_loop!(
  f,box,icell,
  cl::CellList{LargeDenseSystem,N,T},
  output
) where {N,T}
  @unpack cutoff_sq = box
  cell = cl.cwp[icell]

  # loop over list of non-repeated particles of cell ic
  pᵢ = cl.fp[cell.icell]
  i = pᵢ.index
  while i > 0
    xpᵢ = pᵢ.coordinates
    pⱼ = cl.np[i] 
    j = pⱼ.index
    while j > 0
      xpⱼ = pⱼ.coordinates
      d2 = norm_sqr(xpᵢ - xpⱼ)
      if d2 <= cutoff_sq
        i_orig = pᵢ.index_original
        j_orig = pⱼ.index_original
        output = f(xpᵢ,xpⱼ,i_orig,j_orig,d2,output)
      end
      pⱼ = cl.np[pⱼ.index]
      j = pⱼ.index
    end
    pᵢ = cl.np[pᵢ.index]
    i = pᵢ.index
  end

  for jcell in neighbour_cells(box)
    output = cell_output!(f,box,cell,cl,output,cell.cartesian+jcell)
  end

  return output
end

#
# loops over the particles of a neighbour cell
#
function cell_output!(
  f,
  box,
  icell,
  cl::CellList{LargeDenseSystem,N,T},
  output,
  jc_cartesian
) where {N,T}
  @unpack projected_particles = cl
  @unpack nc, cutoff, cutoff_sq, cell_size = box
  jc = cell_linear_index(nc,jc_cartesian)

  # Vector connecting cell centers
  Δc = cell_center(jc_cartesian,cell_size) - icell.center 

  # Copy coordinates of particles of icell jcell into continuous array,
  # and project them into the vector connecting cell centers
  pⱼ = cl.fp[jc]
  npcell = cl.npcell[jc]
  j = pⱼ.index
  for jp in 1:npcell
    j_orig = pⱼ.index_original
    xpⱼ = pⱼ.coordinates
    xproj = dot(xpⱼ - icell.center,Δc)
    projected_particles[jp] = ProjectedParticle(j_orig,xproj,xpⱼ) 
    pⱼ = cl.np[j]
    j = pⱼ.index
  end
  pp = @view(projected_particles[1:npcell])

  # Sort particles according to projection norm
  sort!(pp, by=el->el.xproj,alg=InsertionSort)

  # Loop over particles of cell icell
  pᵢ = cl.fp[icell.icell]
  i = pᵢ.index
  while i > 0
    xpᵢ = pᵢ.coordinates
    xproj = dot(xpᵢ-icell.center,Δc)
    j = 1
    while j <= npcell && xproj - pp[j].xproj <= cutoff
      xpⱼ = pp[j].coordinates
      d2 = norm_sqr(xpᵢ - xpⱼ)
      if d2 <= cutoff_sq
        i_orig = pᵢ.index_original
        j_orig = pp[j].index_original
        output = f(xpᵢ,xpⱼ,i_orig,j_orig,d2,output)
      end
      j += 1
    end
    pᵢ = cl.np[i]
    i = pᵢ.index
  end

  return output
end

#
# Serial version for cross-interaction computations
#
function map_pairwise_serial!(
  f::F, output, box::Box, 
  cl::CellListPair{LargeDenseSystem,N,T}; 
  show_progress=show_progress
) where {F,N,T}
  show_progress && (p = Progress(length(cl.small),dt=1))
  for i in eachindex(cl.small)
    output = inner_loop!(f,output,i,box,cl)
    show_progress && next!(p)
  end
  return output
end

#
# Parallel version for cross-interaction computations
#
function map_pairwise_parallel!(
  f::F1, output, box::Box, 
  cl::CellListPair{LargeDenseSystem,N,T};
  output_threaded=output_threaded,
  reduce::F2=reduce,
  show_progress=show_progress
) where {F1,F2,N,T}
  show_progress && (p = Progress(length(cl.small),dt=1))
  @threads for it in 1:nthreads()
    for i in splitter(it,length(cl.small))
      output_threaded[it] = inner_loop!(f,output_threaded[it],i,box,cl) 
      show_progress && next!(p)
    end
  end 
  output = reduce(output,output_threaded)
  return output
end

#
# Inner loop of cross-interaction computations
#
function inner_loop!(
  f,output,i,box,
  cl::CellListPair{LargeDenseSystem,N,T}
) where {N,T}
  @unpack unit_cell, nc, cutoff_sq = box
  xpᵢ = wrap_to_first(cl.small[i],unit_cell)
  ic = particle_cell(xpᵢ,box)
  for neighbour_cell in neighbour_cells_all(box)
    jc = cell_linear_index(nc,neighbour_cell+ic)
    pⱼ = cl.large.fp[jc]
    j = pⱼ.index
    # loop over particles of cell jc
    while j > 0
      xpⱼ = pⱼ.coordinates
      d2 = norm_sqr(xpᵢ - xpⱼ)
      if d2 <= cutoff_sq
        j_orig = pⱼ.index_original 
        output = f(xpᵢ,xpⱼ,i,j_orig,d2,output)
      end
      pⱼ = cl.large.np[j]
      j = pⱼ.index
    end                                   
  end
  return output
end

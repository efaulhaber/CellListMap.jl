# Ecosystem integration

- [Agents.jl](@ref)
- [Unitful and units](@ref)
- [Automatic differentiation](@ref)
- [Measurements](@ref)

## Agents.jl

[Agents.jl](https://juliadynamics.github.io/Agents.jl) provides a comprehensive framework for simulation, analysis and visualization of agent-based systems. `CellListMap` can be used to accelerate these simulations, and the integration of the packages is rather simple, particularly using the `PeriodicSystems` interface. A [complete integration example](https://juliadynamics.github.io/Agents.jl/dev/examples/celllistmap/) can be obtained in the `Agents` documentation (currently at the development branch). 

The example will produce the following animation:

```@raw html
<video width="auto" controls autoplay loop>
<source src="https://juliadynamics.github.io/Agents.jl/dev/examples/celllistmap.mp4" type="video/mp4">
</video>
```

## Unitful and units

The functions of CellListMap.jl support the propagation of generic (isbits) types, and thus units and thus automatic differentiation and the use of `Unitful`. A set of working examples can be found in the [generic_types.jl](https://github.com/m3g/CellListMap.jl/blob/main/src/examples/generic_types.jl) file.

We start illustrating the support for unit propagation. We need to define all involved quantities in the same units:

### Using the PeriodicSystems interface

The only requirement is to attach proper units to all quantities (positions, cutoff, unitcell, and output variables).
Here we compute the square of the distances of the particles within the cutoff:
```julia-repl
julia> using CellListMap.PeriodicSystems, Unitful, StaticArrays

julia> system = PeriodicSystem(
           positions = rand(SVector{3,Float64}, 1000)u"nm",
           cutoff = 0.1u"nm",
           unitcell = [1.0,1.0,1.0]u"nm",
           output = 0.0u"nm^2",
           output_name = :sum_sqr
       );

julia> map_pairwise((x,y,i,j,d2,out) -> out += d2, system)
12.467455105066907 nm^2
```

### Units in neighbor lists

`CellListMap.neighborlist` propagates units correctly:

```julia-repl
julia> import CellListMap

julia> positions = rand(SVector{3,Float64}, 1000)u"nm";

julia> cutoff = 0.1u"nm";

julia> CellListMap.neighborlist(positions, cutoff)
1842-element Vector{Tuple{Int64, Int64, Quantity{Float64, 𝐋, Unitful.FreeUnits{(nm,), 𝐋, nothing}}}}:
 (1, 89, 0.09181950064928723 nm)
 (1, 820, 0.0862244300739942 nm)
 ⋮
 (998, 782, 0.07772327062692863 nm)
```

## Automatic differentiation

Allowing automatic differentiation follows the same principles, meaning that we only need to allow the propagation of dual types through the computation by proper initialization of the input data. However, it is easier to work with the low level interface, which accepts matrices as the input for positions and a more fine control of the types of the variables. Matrices are easier input types for auto diff packages.

The variables are each component of each vector, thus the easiest way to represent the points such that automatic differentiation packages understand is by creating a matrix:

```julia-repl
julia> x = rand(3,1000)
3×1000 Matrix{Float64}:
 0.186744  0.328719  0.874102  0.503535   …  0.328161  0.0895699  0.917338
 0.176157  0.972954  0.80729   0.624724      0.655268  0.470754   0.327578
 0.648482  0.537362  0.599624  0.0688776     0.92333   0.497984   0.208924
```

The key here is allow all the types of the parameters to follow the type propagation of the elements of `x` inside the differentiation routine. The function we define to compute the derivative is, then:

```julia-repl
julia> function sum_sqr(x,sides,cutoff)
           cutoff = eltype(x)(cutoff)
           sides = eltype(x).(sides)
           box = Box(sides,cutoff)
           cl = CellList(x,box)
           sum_sqr = zero(eltype(x))
           sum_sqr = map_pairwise!(
               (x,y,i,j,d2,sum_sqr) -> sum_sqr += d2,
               sum_sqr, box, cl
           )
           return sum_sqr
       end
sum_sqr (generic function with 1 method)
```

Note that we allow `cutoff`  and `sides`  to be converted to the same type of the input `x`  of the function. For a simple call to the function this is inconsequential:

```julia-repl
julia> cutoff = 0.1; sides = [1,1,1];

julia> sum_sqr(x,sides,cutoff)
12.897650398753228
```

but the conversion is required to allow the differentiation to take place:

```julia-repl
julia> ForwardDiff.gradient(x -> sum_sqr(x,sides,cutoff),x)
3×1000 Matrix{Float64}:
 -0.132567   0.029865  -0.101301  …   0.249267    0.0486424  -0.0400487
  0.122421   0.207495  -0.184366     -0.201648   -0.105031    0.218342
  0.0856502  0.288924   0.122445     -0.0147022  -0.103314   -0.0862264
```

## Measurements

Propagating uncertainties through the `Measurements`  and other similar packages requires a different strategy, because within `CellListMap` only `isbits` types can be used, which is not the case of the type `Measurement` type. 

In cases like this, it is better to bypass all the internals of `CellListMap`  and provide the data to the function that computes pairwise properties directly as a closure. For example:

A vector of particles with uncertainties in their coordinates can be created with: 
```julia-repl
julia> using StaticArrays 

julia> x_input = [ SVector{3}(measurement(rand(),0.01*rand()) for i in 1:3) for j in 1:1000 ]
1000-element Vector{SVector{3, Measurement{Float64}}}:
 [0.1658 ± 0.003, 0.9951 ± 0.0054, 0.5067 ± 0.0035]
 [0.2295 ± 0.0074, 0.2987 ± 0.0021, 0.42828 ± 0.00099]
 ⋮
 [0.1362 ± 0.0034, 0.2219 ± 0.0048, 0.2119 ± 0.0072]
 [0.2521 ± 0.0038, 0.4988 ± 0.00013, 0.856046 ± 4.3e-5]
```

The variables within the `CellListMap` functions will be stripped from the uncertainties. We do:

```julia-repl
julia> unitcell = [1,1,1]

julia> cutoff = 0.1; box = Box(unitcell,cutoff);

julia> x_strip = [ getproperty.(v,:val) for v in x_input ]
1000-element Vector{SVector{3, Float64}}:
 [0.08441931492362276, 0.9911530546181084, 0.07408559584648788]
 [0.12084764467339837, 0.8284551316333133, 0.9021906852432111]
 ⋮
 [0.2418752113326077, 0.4429225751775432, 0.13576355747772784]
 [0.24440380524702654, 0.07148275176890073, 0.26722687487212315]
```

The cell list is built with the stripped values:

```julia-repl
julia> cl = CellList(x_strip,box)
CellList{3, Float64}
  1000 real particles.
  637 cells with real particles.
  1695 particles in computing box, including images.
```

The result is initialized with the proper type,

```julia-repl
julia> result = measurement(0.,0.)
0.0 ± 0.0
```

and the mapping is performed with the stripped coordinates, but passing the values with uncertainties to the mapped function, which will perform the computation on the pairs with those values:

```julia-repl
julia> using LinearAlgebra: norm_sqr

julia> result = map_pairwise!(
           (xᵢ,xⱼ,i,j,d2,sum_sqr) -> begin
               x1 = x_input[i]
               x2 = CellListMap.wrap_relative_to(x_input[j],x1,unitcell)
               sum_sqr += norm_sqr(x2-x1)
               return sum_sqr
           end, 
           result, box, cl
       )
13.14 ± 0.061
```

In the function above, the `xᵢ` and `xⱼ` coordinates, which correspond to the coordinates in `x_input[i]` and `x_input[j]`, but already wrapped relative to each other, are ignored, because they don't carry the uncertainties. We use only the indexes `i` and `j` to recompute the relative position of the particles according to the periodic boundary conditions (using the `CellListMap.wrap_relative_to` function) and their (squared) distance. Since the `x_input`  array carries the uncertainties, the computation of `sum_sqr` will propagate them.   

!!! note
    All these computations should be performed inside the scope of a function for optimal performance. The examples here can be followed by copying and pasting the code into the REPL, but this is not the recommended practice for critical code. The strategy of bypassing the internal computations of `CellListMap` may be useful for improving performance even if the previous and simpler method is possible. 



#
# In this test we compute the average displacement of the x coordinates of the atoms
# Expected to be nearly zero in average
#              
function test1(N=100_000)

  # Number of particles, sides and cutoff
  sides = [250,250,250]
  cutoff = 10.
  box = Box(sides,cutoff)

  # Initialize auxiliary linked lists
  lc = LinkedLists(N)

  # Particle positions
  x = [ box.sides .* rand(SVector{3,Float64}) for i in 1:N ]

  # Initializing linked cells with these positions
  initcells!(x,box,lc)  

  # Function to be evalulated for each pair: sum of displacements on x
  f(x,y,avg_dx) = avg_dx + x[1] - y[1]

  avg_dx = (N/(N*(N-1)/2)) * map_pairwise((x,y,i,j,d2,avg_dx) -> f(x,y,avg_dx),0.,x,box,lc)
  return avg_dx

end

#
# In this test we compute the histogram of distances, expected to follow the
# function f(f) = ρ(4/3)π(r[i+1]^3 - r[i]^3) with ρ being the density of the system.
#
function test2(N=100_000)

  # Number of particles, sides and cutoff
  sides = [250,250,250]
  cutoff = 10.
  box = Box(sides,cutoff)

  # Initialize auxiliary linked lists
  lc = LinkedLists(N)

  # Particle positions
  x = [ box.sides .* rand(SVector{3,Float64}) for i in 1:N ]

  # Initializing linked cells with these positions
  initcells!(x,box,lc)  

  # Function to be evalulated for each pair: build distance histogram
  function build_histogram!(x,y,d2,hist) 
    d = sqrt(d2)
    ibin = floor(Int,d) + 1
    hist[ibin] += 1
    return hist
  end

  # Preallocate and initialize histogram
  hist = zeros(Int,10)

  # Run pairwise computation
  hist = map_pairwise((x,y,i,j,d2,hist) -> build_histogram!(x,y,d2,hist),hist,x,box,lc)
  return (N/(N*(N-1)/2)) * hist

end

#
# In this test we compute the "gravitational potential", pretending that each particle
# has a different mass. In this case, the closure is used to pass the masses to the
# function that computes the potential.
#
function test3(N=100_000)

  # Number of particles, sides and cutoff
  sides = [250,250,250]
  cutoff = 10.
  box = Box(sides,cutoff)

  # Initialize auxiliary linked lists
  lc = LinkedLists(N)

  # Particle positions
  x = [ box.sides .* rand(SVector{3,Float64}) for i in 1:N ]

  # masses
  mass = rand(N)

  # Initializing linked cells with these positions
  initcells!(x,box,lc)  

  # Function to be evalulated for each pair: build distance histogram
  function potential(x,y,i,j,d2,u,mass) 
    d = sqrt(d2)
    u = u - 9.8*mass[i]*mass[j]/d
    return u
  end

  # Run pairwise computation
  u = map_pairwise((x,y,i,j,d2,u) -> potential(x,y,i,j,d2,u,mass),0.0,x,box,lc)
  return u

end

#
# In this test we compute the "gravitational force", pretending that each particle
# has a different mass. In this case, the closure is used to pass the masses and
# the force vector to the function that computes the potential.
#
function test4(N=100_000)

  # Number of particles, sides and cutoff
  sides = [250,250,250]
  cutoff = 10.
  box = Box(sides,cutoff)

  # Initialize auxiliary linked lists
  lc = LinkedLists(N)

  # Particle positions
  x = [ box.sides .* rand(SVector{3,Float64}) for i in 1:N ]

  # masses
  mass = rand(N)

  # Initializing linked cells with these positions
  initcells!(x,box,lc)  

  # Function to be evalulated for each pair: build distance histogram
  function calc_forces!(x,y,i,j,d2,mass,forces) 
    G = 9.8*mass[i]*mass[j]/d2
    d = sqrt(d2)
    df = (G/d) * (x - y)
    forces[i] = forces[i] - df
    forces[j] = forces[j] + df
    return forces
  end

  # Preallocate and initialize forces
  forces = [ zeros(SVector{3,Float64}) for i in 1:N ]

  # Run pairwise computation
  forces = map_pairwise((x,y,i,j,d2,forces) -> calc_forces!(x,y,i,j,d2,mass,forces),forces,x,box,lc)
  return forces

end

#
# In this test we compute the minimum distance between two independent sets of particles
#
function test5(;N1=1_500,N2=1_500_000)

  # Number of particles, sides and cutoff
  sides = [250,250,250]
  cutoff = 10.
  box = Box(sides,cutoff)

  # Initialize auxiliary linked lists (largest set!)
  lc = LinkedLists(N2)

  # Particle positions
  x = [ box.sides .* rand(SVector{3,Float64}) for i in 1:N1 ]
  y = [ box.sides .* rand(SVector{3,Float64}) for i in 1:N2 ]

  # Initializing linked cells with these positions (largest set!)
  initcells!(y,box,lc)  

  # Function that keeps the minimum distance
  f(x,y,i,j,d2,mind) = d2 < mind[3] ? (i,j,d2) : mind

  # We have to define our own reduce function here
  function reduce_mind(output_threaded)
    mind = output_threaded[1]
    for i in 2:nthreads()
      if output_threaded[i][3] < mind[3]
        mind = output_threaded[i]
      end
    end
    return (mind[1],mind[2],sqrt(mind[3]))
  end 

  # Initialize
  mind = ( 0, 0, +Inf )

  # Run pairwise computation
  mind = map_pairwise(f,mind,x,y,box,lc;reduce=reduce_mind)
  return mind

end

#
# In this test we compute the minimum distance between two independent sets of particles,
# more or less without periodic conditions
#
function test6(;N1=1_500,N2=1_500_000)

  # Number of particles, sides and cutoff
  sides = [1.2,1.2,1.2]
  cutoff = 0.01
  box = Box(sides,cutoff)

  # Initialize auxiliary linked lists (largest set!)
  lc = LinkedLists(N2)

  # Particle positions
  x = [ rand(SVector{3,Float64}) for i in 1:N1 ]
  y = [ rand(SVector{3,Float64}) for i in 1:N2 ]

  # Initializing linked cells with these positions (largest set!)
  initcells!(y,box,lc)  

  # Function that keeps the minimum distance
  f(x,y,i,j,d2,mind) = d2 < mind[3] ? (i,j,d2) : mind

  # We have to define our own reduce function here
  function reduce_mind(output_threaded)
    mind = output_threaded[1]
    for i in 2:Threads.nthreads()
      if output_threaded[i][3] < mind[3]
        mind = output_threaded[i]
      end
    end
    return (mind[1],mind[2],sqrt(mind[3]))
  end 

  # Initialize 
  mind = ( 0, 0, +Inf )

  # Run pairwise computation
  mind = map_pairwise(f,mind,x,y,box,lc;reduce=reduce_mind)
  return mind

end


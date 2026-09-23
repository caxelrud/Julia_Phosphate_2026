# =============================================================================
# dynamic.jl -- the dynamic digital twin, built with ModelingToolkit.
#
# Where the steady-state twin answers "where does this plant end up", the dynamic
# twin answers "how long does it take, and what does it do on the way". It is an
# eleven-state model of the reaction train on an **hourly clock** -- the clock of
# the historian and the sample time of the controller:
#
# * the attack tanks as a CSTR in mass terms: undissolved P2O5, dissolved P2O5,
#   free sulphuric acid, water and temperature
# * the evaporators as a lag on the strength of the merchant acid, with a fouling
#   state that grows with the load and costs steam
# * the granulator as a lag on the bed moisture and the bed temperature
# * the grinding circuit as a holdup with a population lag on the P80
#
# The state vector of the twin is the state vector the soft sensors estimate and
# the controller regulates, so the three share one definition of the plant.
# =============================================================================

"""States of the dynamic twin, in the order of the state vector."""
const DYNAMIC_STATES = (:p2o5_undissolved, :p2o5_liquor, :h2so4, :water, :temperature,
    :acid_strength, :bed_moisture, :bed_temperature, :mill_holdup, :p80, :fouling)

"""Manipulated inputs of the dynamic twin (the parameters the controller moves)."""
const DYNAMIC_INPUTS = (:rock_feed, :acid_flow, :recycle_mass, :wash_water, :cooling_water,
    :steam_flow, :ammonia_flow, :mill_feed, :mill_water, :dryer_fuel)

"""Fixed parameters of the dynamic twin: the design and the kinetics it runs with."""
const DYNAMIC_PARAMETERS = (:rock_grade, :free_cao_rate, :tau_reactor, :tau_mill, :k_digest,
    :ea_digest, :temperature_ref, :economy, :steam_design, :acid_strength_design, :p80_design,
    :mill_water_design, :fouling_rate, :melt_moisture, :ammonia_design, :free_p2o5_cake,
    :cooling_gain, :cooling_water_design)


"""Outputs of the dynamic twin that the instruments and the soft sensors see."""
const DYNAMIC_OUTPUTS = (:temperature, :free_so4, :acid_strength_weak, :acid_strength,
    :product_rate, :filter_rate, :mill_power, :p80, :bed_moisture,
    :granulator_temperature, :mill_inventory, :fouling_pct)

"""Fixed parameters of the dynamic twin, from the registered design."""
function dynamic_parameters(d::PlantDesign = default_design())
    assay = ore_body(d.ore_body)
    rock = design_ore_tph(d)
    return Dict{Symbol,Float64}(
        :rock_grade => d.rock_p2o5, :free_cao_rate => free_cao(assay, rock), :tau_reactor => 3.8,
        :tau_mill => 0.55, :k_digest => 14.6, :ea_digest => 45000.0,
        :temperature_ref => d.digestion_temperature_k - 273.15,
        :economy => d.evaporator_economy, :steam_design => d.evaporator_steam_tph,
        :acid_strength_design => 100.0 * P2O5_MERCHANT_ACID, :p80_design => d.grind_p80_um,
        :mill_water_design => d.mill_water_m3ph, :fouling_rate => 0.0006,
        :melt_moisture => d.melt_moisture, :ammonia_design => d.ammonia_tph,
        :free_p2o5_cake => 100.0 * d.gypsum_free_p2o5,
        :cooling_gain => 20.0, :cooling_water_design => dynamic_inputs(d)[:cooling_water],
    )
end

"""`true` when a solver reached the end of its time span, whatever the solver."""
solver_ok(sol) = occursin("Success", string(sol.retcode))


"""Input values of the dynamic twin at the registered design point."""
function dynamic_inputs(d::PlantDesign = default_design())
    assay = ore_body(d.ore_body)
    rock = 0.47 * design_ore_tph(d)
    return Dict{Symbol,Float64}(
        :rock_feed => rock, :acid_flow => STOICH.acid * rock * d.flotation_grade *
                                        (1.0 + d.acid_excess),
        :recycle_mass => 900.0, :wash_water => d.filter_area_m2 * 0.61,
        :cooling_water => 620.0, :steam_flow => d.evaporator_steam_tph,
        :ammonia_flow => d.ammonia_tph, :mill_feed => d.ore_tph,
        :mill_water => d.mill_water_m3ph, :dryer_fuel => 112.0,
    )
end

"""
    DynamicTwin

The dynamic twin and its vocabulary: the `System` plus the symbolic `states`,
`inputs` and `parameters`, keyed by the symbols the rest of the package uses.
ModelingToolkit declares variables with a macro, so the builder keeps the declared
symbols here and every other function reaches them through this structure: there is
exactly one place in the package where the symbolic names are written.

`sys` is the uncompiled `System`; call `mtkcompile(twin.sys)` before building a
problem out of it.
"""
struct DynamicTwin
    sys::Any
    states::Dict{Symbol,Any}
    inputs::Dict{Symbol,Any}
    parameters::Dict{Symbol,Any}
end

"""
    dynamic_twin(design = default_design()) -> DynamicTwin

The dynamic twin as a `System` of eleven differential equations. The equations are
the model and each comment in the builder names the balance it writes; the state
vector is the one the Kalman filter estimates and the controller regulates.
"""
function dynamic_twin(d::PlantDesign = default_design())
    @independent_variables t
    @variables p2o5_undissolved(t) p2o5_liquor(t) h2so4(t) water(t) temperature(t)
    @variables acid_strength(t) bed_moisture(t) bed_temperature(t) mill_holdup(t) p80(t) fouling(t)
    @parameters rock_grade free_cao_rate tau_reactor tau_mill k_digest ea_digest temperature_ref economy
    @parameters steam_design acid_strength_design p80_design mill_water_design fouling_rate
    @parameters melt_moisture ammonia_design free_p2o5_cake
    @parameters rock_feed acid_flow recycle_mass wash_water cooling_water steam_flow
    @parameters ammonia_flow mill_feed mill_water dryer_fuel cooling_gain cooling_water_design
    D = Differential(t)
    x = Dict{Symbol,Any}(:p2o5_undissolved => p2o5_undissolved, :p2o5_liquor => p2o5_liquor,
        :h2so4 => h2so4, :water => water, :temperature => temperature,
        :acid_strength => acid_strength, :bed_moisture => bed_moisture,
        :bed_temperature => bed_temperature, :mill_holdup => mill_holdup, :p80 => p80,
        :fouling => fouling)
    u = Dict{Symbol,Any}(:rock_feed => rock_feed, :acid_flow => acid_flow,
        :recycle_mass => recycle_mass, :wash_water => wash_water,
        :cooling_water => cooling_water, :steam_flow => steam_flow,
        :ammonia_flow => ammonia_flow, :mill_feed => mill_feed, :mill_water => mill_water,
        :dryer_fuel => dryer_fuel)
    p = Dict{Symbol,Any}(:rock_grade => rock_grade, :free_cao_rate => free_cao_rate,
        :tau_reactor => tau_reactor, :tau_mill => tau_mill, :k_digest => k_digest,
        :ea_digest => ea_digest, :temperature_ref => temperature_ref, :economy => economy,
        :steam_design => steam_design, :acid_strength_design => acid_strength_design,
        :p80_design => p80_design, :mill_water_design => mill_water_design,
        :fouling_rate => fouling_rate, :melt_moisture => melt_moisture,
        :ammonia_design => ammonia_design, :free_p2o5_cake => free_p2o5_cake,
        :cooling_gain => cooling_gain, :cooling_water_design => cooling_water_design)

    ## dissolution: first order in the undissolved P2O5, Arrhenius in temperature
    k = p[:k_digest] * exp(-p[:ea_digest] * (1.0 / (x[:temperature] + 273.15) -
                                             1.0 / (p[:temperature_ref] + 273.15)))
    digest = k * x[:p2o5_undissolved]
    gypsum_rate = STOICH.gypsum * digest + GYPSUM_PER_FREE_CAO * p[:free_cao_rate]
    strength_weak = 100.0 * x[:p2o5_liquor] / (x[:p2o5_liquor] + x[:water] + 1.0e-9)
    ## the flash cooler: it takes out the adiabatic rise the kinetics produce at the
    ## reference temperature and, beyond it, an amount that grows with the driving force.
    ## That proportional term is what holds the tank: without it the Arrhenius feedback of
    ## the dissolution (a 3 % gain in rate per degree) makes the temperature run away.
    heat_rise = HEAT_OF_ATTACK_KJ_PER_KG_P2O5 * digest * HEAT_RETENTION_SLURRY /
                ((u[:rock_feed] + u[:acid_flow] + 0.30 * u[:recycle_mass]) *
                 SLURRY_CP_KJ_PER_KG_K)
    rise_reference = HEAT_OF_ATTACK_KJ_PER_KG_P2O5 * p[:k_digest] * x[:p2o5_undissolved] *
                     HEAT_RETENTION_SLURRY /
                     ((u[:rock_feed] + u[:acid_flow] + 0.30 * u[:recycle_mass]) *
                      SLURRY_CP_KJ_PER_KG_K)
    cooler = (rise_reference + p[:cooling_gain] * (x[:temperature] - p[:temperature_ref])) *
             (u[:cooling_water] / p[:cooling_water_design])
    temperature_target = p[:temperature_ref] + heat_rise - cooler
    strength_target = p[:acid_strength_design] -
                      0.09 * (u[:steam_flow] - p[:steam_design]) * (1.0 + x[:fouling]) +
                      0.02 * (strength_weak - 28.5)
    moisture_target = 0.35 * p[:melt_moisture] +
                      0.03 * (x[:acid_strength] - p[:acid_strength_design])
    bed_temperature_target = 96.0 + 14.0 * (u[:ammonia_flow] / p[:ammonia_design] - 1.0) +
                             0.5 * (x[:bed_moisture] - moisture_target) * 10.0
    mill_discharge = x[:mill_holdup] / p[:tau_mill]
    p80_target = p[:p80_design] + 0.06 * (u[:mill_feed] - 150.0) -
                 0.45 * (u[:mill_water] - p[:mill_water_design])
    eqs = [
        ## P2O5 waiting to be digested: fed with the rock, digested, washed out
        D(x[:p2o5_undissolved]) ~ u[:rock_feed] * p[:rock_grade] - digest -

                                  x[:p2o5_undissolved] / p[:tau_reactor],
        ## P2O5 in solution: produced by the reaction, leaves with the filtrate
        D(x[:p2o5_liquor]) ~ digest - x[:p2o5_liquor] / p[:tau_reactor],
        ## free sulphuric acid: fed, consumed by the apatite and the carbonate
        D(x[:h2so4]) ~ u[:acid_flow] - STOICH.acid * digest - x[:h2so4] / p[:tau_reactor],
        ## water of the filtrate: wash and recycle in, hydration and cake out
        D(x[:water]) ~ u[:wash_water] + u[:recycle_mass] * (1.0 - strength_weak / 100.0) -
                       STOICH.water * digest - 0.20 * gypsum_rate - x[:water] / p[:tau_reactor],
        ## temperature of the attack tanks: 27 min to take up a load change
        D(x[:temperature]) ~ (temperature_target - x[:temperature]) / 0.45,
        ## strength of the merchant acid: an evaporator lag, slower when it fouls
        D(x[:acid_strength]) ~ (strength_target - x[:acid_strength]) / 2.2,
        ## bed moisture of the granulator: 1.5 h of mixing
        D(x[:bed_moisture]) ~ (moisture_target - x[:bed_moisture]) / 1.5,
        ## bed temperature of the granulator: 48 min of mixing
        D(x[:bed_temperature]) ~ (bed_temperature_target - x[:bed_temperature]) / 0.8,
        ## holdup of the mills: 33 min of residence at the design rate
        D(x[:mill_holdup]) ~ u[:mill_feed] - mill_discharge,
        ## grind size of the mill discharge: the population lag of the circuit
        D(x[:p80]) ~ (p80_target - x[:p80]) / 0.6,
        ## fouling of the evaporator tubes: grows with the load, never removes itself
        D(x[:fouling]) ~ p[:fouling_rate] * (u[:steam_flow] / p[:steam_design]),
    ]
    sys = System(eqs, t, [x[s] for s in DYNAMIC_STATES],
        vcat([u[i] for i in DYNAMIC_INPUTS], [p[q] for q in DYNAMIC_PARAMETERS]);
        name = :phosphate_twin)
    return DynamicTwin(sys, x, u, p)
end



"""
    dynamic_initial_state(design; inputs, parameters) -> Dict{Symbol,Float64}

Starting state of the dynamic twin: the holdup the plant reaches when it runs at the
given inputs. The three holdups of the attack tank are solved from their own
steady-state balance and the water is fixed-pointed three times, because the
strength of the liquor depends on the water it contains.
"""
function dynamic_initial_state(d::PlantDesign = default_design();
    inputs::Dict{Symbol,Float64} = dynamic_inputs(d),
    parameters::Dict{Symbol,Float64} = dynamic_parameters(d),
    fouling::Real = 0.6)
    τ = parameters[:tau_reactor]
    k = parameters[:k_digest]
    fed = inputs[:rock_feed] * parameters[:rock_grade]
    undissolved = fed / (k + 1.0 / τ)
    digest = k * undissolved
    liquor = digest * τ
    h2so4 = max(0.0, (inputs[:acid_flow] - STOICH.acid * digest) * τ)
    gypsum_rate = STOICH.gypsum * digest + GYPSUM_PER_FREE_CAO * parameters[:free_cao_rate]
    water = 600.0
    for _ in 1:3
        strength = 100.0 * liquor / max(liquor + water, 1.0e-9)
        water = max(1.0, (inputs[:wash_water] + inputs[:recycle_mass] * (1.0 - strength / 100.0) -
                          STOICH.water * digest - 0.20 * gypsum_rate) * τ)
    end
    strength_weak = 100.0 * liquor / max(liquor + water, 1.0e-9)
    return Dict{Symbol,Float64}(:p2o5_undissolved => undissolved, :p2o5_liquor => liquor,
        :h2so4 => h2so4, :water => water, :temperature => parameters[:temperature_ref],
        :acid_strength => parameters[:acid_strength_design],
        :bed_moisture => 0.35 * parameters[:melt_moisture],
        :bed_temperature => 96.0, :mill_holdup => inputs[:mill_feed] * parameters[:tau_mill],
        :p80 => parameters[:p80_design], :fouling => fouling)
end

"""Outputs of the dynamic twin at a state, in the units the instruments report.

The last three are the states a quantity sensor cannot see -- the bed temperature of
the granulator, the inventory of the mills and the fouling of the evaporator tubes --
reported as the twin computes them. They are what keeps the linearised model observable
for the Kalman filter of the controller: a state that appears in no output can never be
estimated, and the filter refuses to be built.
"""
function dynamic_outputs(d::PlantDesign, x::Dict{Symbol,Float64},
    u::Dict{Symbol,Float64}, p::Dict{Symbol,Float64})
    g(k) = get(x, k, 0.0)
    τ = p[:tau_reactor]
    p2o5_out = g(:p2o5_liquor) / τ
    free_so4 = 100.0 * g(:h2so4) / max(g(:h2so4) + g(:water) + g(:p2o5_liquor), 1.0e-9)
    strength_weak = 100.0 * g(:p2o5_liquor) / max(g(:p2o5_liquor) + g(:water), 1.0e-9)
    ## the water-soluble loss goes out with the gypsum, the rest reaches the filters
    gypsum_rate = STOICH.gypsum * p2o5_out + GYPSUM_PER_FREE_CAO * p[:free_cao_rate]
    p2o5_acid = max(0.0, p2o5_out - gypsum_rate * p[:free_p2o5_cake] / 100.0)

    return Dict{Symbol,Float64}(:temperature => g(:temperature), :free_so4 => free_so4,
        :acid_strength_weak => strength_weak, :acid_strength => g(:acid_strength),
        :product_rate => 0.76 * p2o5_acid / 0.4605,
        :filter_rate => 24.0 * p2o5_acid / d.filter_area_m2,
        :mill_power => bond_mill_power(d.bond_wi, d.grind_f80_um, g(:p80), u[:mill_feed]),
        :p80 => g(:p80), :bed_moisture => g(:bed_moisture),
        :granulator_temperature => g(:bed_temperature), :mill_inventory => g(:mill_holdup),
        :fouling_pct => g(:fouling))
end

"""
    simulate_dynamic(design; tspan, inputs, initial, sample) -> Dict{Symbol,Any}

Integrate the dynamic twin and return the trajectory of the states and of the
outputs, with the mass balance of the reaction section checked over the horizon
(the water and the P2O5 that went in against what is in the tank plus what left).

Time is in hours, as everywhere in this application: one hour is the interval of
the historian and the sample time of the controller.
"""
function simulate_dynamic(d::PlantDesign = default_design();
    tspan::Tuple{Float64,Float64} = (0.0, 48.0),
    inputs::Dict{Symbol,Float64} = dynamic_inputs(d),
    parameters::Dict{Symbol,Float64} = dynamic_parameters(d),
    initial::Dict{Symbol,Float64} = dynamic_initial_state(d; inputs = inputs,
        parameters = parameters),
    sample::Real = 0.25, solver = Tsit5())
    twin = dynamic_twin(d)
    sys = mtkcompile(twin.sys)
    u0 = [twin.states[s] => initial[s] for s in DYNAMIC_STATES]
    ps = [[twin.inputs[k] => v for (k, v) in inputs]...,
        [twin.parameters[k] => v for (k, v) in parameters]...]
    t0 = time()
    prob = ODEProblem(sys, u0, tspan, ps)
    sol = solve(prob, solver; saveat = sample)
    stamps = collect(sol.t)
    states = Dict{Symbol,Vector{Float64}}(
        s => [sol[twin.states[s]][i] for i in eachindex(stamps)] for s in DYNAMIC_STATES)

    outputs = Dict{Symbol,Vector{Float64}}()
    for s in DYNAMIC_OUTPUTS
        outputs[s] = [dynamic_outputs(d, Dict(q => states[q][i] for q in DYNAMIC_STATES),
            inputs, parameters)[s] for i in eachindex(stamps)]
    end
    rows = [Dict{Symbol,Any}(:hour => stamps[i],
        (s => states[s][i] for s in DYNAMIC_STATES)...,
        (o => outputs[o][i] for o in DYNAMIC_OUTPUTS)...) for i in eachindex(stamps)]
    fed_t = inputs[:rock_feed] * parameters[:rock_grade] * (tspan[2] - tspan[1])
    liquor_start = initial[:p2o5_liquor]
    liquor_end = states[:p2o5_liquor][end]
    balance = Dict{Symbol,Any}(:fed_t => fed_t, :liquor_start => liquor_start,
        :liquor_end => liquor_end,
        :liquor_change_pct => liquor_start == 0 ? NaN :
                              100.0 * (liquor_end - liquor_start) / liquor_start,
        :digested_t => sum(states[:p2o5_liquor]) * sample,
        :max_temperature => maximum(outputs[:temperature]),
        :min_acid_strength => minimum(outputs[:acid_strength]),
        :final_p80 => states[:p80][end], :final_fouling => states[:fouling][end],
        :fouling_penalty_pct => states[:fouling][end])
    return Dict{Symbol,Any}(:status => solver_ok(sol) ? :compliant : :at_risk,
        :retcode => sol.retcode, :hours => stamps, :states => states, :outputs => outputs,
        :rows => rows, :balance => balance, :seconds => round(time() - t0, digits = 3),
        :tspan => tspan, :inputs => inputs, :initial => initial, :solver => string(solver))
end

"""
    step_response(design; input, delta, tspan, sample) -> Dict{Symbol,Any}

Step the twin from the same starting point with one input moved by `delta` (a
fraction of its design value) and report the trajectory, the gain of every output
and the time it takes to reach 63 % of the change — the identification the
controller designer asks for.

The ODE model is the plant of the closed-loop comparison: the MPC never sees the
equations, only the linearised model below, which is exactly the situation of a real
controller.
"""
function step_response(d::PlantDesign = default_design();
    input::Symbol = :acid_flow, delta::Real = 0.05,
    tspan::Tuple{Float64,Float64} = (0.0, 24.0), sample::Real = 0.25)
    inputs = dynamic_inputs(d)
    parameters = dynamic_parameters(d)
    input in keys(inputs) || throw(ArgumentError("unknown input $(code_string(input))"))
    initial = dynamic_initial_state(d; inputs = inputs, parameters = parameters)
    stepped = copy(inputs)
    stepped[input] = inputs[input] * (1.0 + delta)
    base = simulate_dynamic(d; tspan = tspan, inputs = inputs, parameters = parameters,
        initial = initial, sample = sample)
    resp = simulate_dynamic(d; tspan = tspan, inputs = stepped, parameters = parameters,
        initial = initial, sample = sample)
    rows = Vector{Dict{Symbol,Any}}()
    gains = Dict{Symbol,Any}()
    for o in DYNAMIC_OUTPUTS
        y0 = base[:outputs][o][1]
        y1 = resp[:outputs][o][end]
        target = y1 - y0
        y63 = Inf
        if !iszero(target)
            for i in eachindex(resp[:hours])
                if abs(resp[:outputs][o][i] - y0) >= 0.63 * abs(target)
                    y63 = resp[:hours][i]
                    break
                end
            end
        end
        gains[o] = Dict{Symbol,Any}(:initial => y0, :final => y1, :gain => y1 - y0,
            :gain_pct => iszero(y0) ? NaN : 100.0 * (y1 - y0) / y0, :t63_h => y63)
    end
    table = [Dict{Symbol,Any}(:hour => resp[:hours][i],
        (o => resp[:outputs][o][i] for o in DYNAMIC_OUTPUTS)...) for i in eachindex(resp[:hours])]
    return Dict{Symbol,Any}(:input => input, :delta_pct => 100.0 * delta,
        :rows => table, :gains => gains, :base => base, :response => resp,
        :status => resp[:status] === :compliant && base[:status] === :compliant ?
                   :compliant : :at_risk,
        :basis => "step of the input on the ODE twin from a common starting point")
end

"""
    linearize_twin(design; sample_time, inputs, outputs) -> Dict{Symbol,Any}

Linearise the twin at its operating point into the discrete state-space model the
predictive controller uses:

`x⁺ = A x + B u`, `y = C x + D u`

`A` and `B` come from the symbolic Jacobians of the equations that `dynamic_twin`
returns, so they are analytic; `C` and `D` are computed from the output map by
central differences, because the outputs are correlations rather than states. The
continuous model is discretised with a zero-order hold, which is what a controller
that holds its move for one hour needs.

The result reports the poles of `A` (the time constants of the plant) and the
conditioning of the controllability matrix, so the notebook can say whether the
model is *controllable* before an MPC is built on it.
"""
function linearize_twin(d::PlantDesign = default_design();
    sample_time::Real = 1.0,
    inputs::Dict{Symbol,Float64} = dynamic_inputs(d),
    parameters::Dict{Symbol,Float64} = dynamic_parameters(d),
    input_names::Vector{Symbol} = [:acid_flow, :wash_water, :cooling_water, :steam_flow,
        :ammonia_flow, :mill_feed],
    output_names::Vector{Symbol} = collect(DYNAMIC_OUTPUTS))
    twin = dynamic_twin(d)
    sys = twin.sys
    x = [twin.states[s] for s in DYNAMIC_STATES]
    ## the symbolic derivative is built over every input of the twin (the ones that are
    ## not linearisation inputs stay at their operating point); the columns of the
    ## requested inputs are selected afterwards
    uu = [twin.inputs[i] for i in DYNAMIC_INPUTS]
    pp = [twin.parameters[k] for k in DYNAMIC_PARAMETERS]
    rhs = [eq.rhs for eq in MTK.equations(sys)]
    xu = [dynamic_initial_state(d; inputs = inputs, parameters = parameters)[s]
          for s in DYNAMIC_STATES]
    pv = [parameters[k] for k in DYNAMIC_PARAMETERS]
    uv = [inputs[k] for k in DYNAMIC_INPUTS]
    columns = [findfirst(==(i), DYNAMIC_INPUTS) for i in input_names]
    A = compile_function(Symbolics.jacobian(rhs, x), x, uu, pp)(xu, uv, pv)
    Bfull = compile_function(Symbolics.jacobian(rhs, uu), x, uu, pp)(xu, uv, pv)
    B = Bfull[:, columns]

    C = _numeric_output_jacobian(d, xu, uv, parameters, output_names, :state)
    Dfull = _numeric_output_jacobian(d, xu, uv, parameters, output_names, :input)
    D = Dfull[:, columns]
    ## the operating point of the estimator: the inputs of the linearisation and the
    ## outputs the twin reports there
    uv = uv[columns]
    x_dict = Dict{Symbol,Float64}(q => xu[i] for (i, q) in enumerate(DYNAMIC_STATES))
    u_dict = dynamic_inputs(d)
    for (i, q) in enumerate(input_names)
        u_dict[q] = uv[i]
    end
    yop = [dynamic_outputs(d, x_dict, u_dict, parameters)[o] for o in output_names]
    Ad, Bd = _zoh(A, B, sample_time)
    poles = eigvals(Ad)
    times = [p == 0 ? Inf : -sample_time / log(abs(p)) for p in poles if abs(p) < 1.0]
    ## the stable subspace is what the estimator and the controller are built on
    reduced = stable_reduction(Ad, Bd, C, D)
    gain = reduced.Cr * ((I - reduced.Ar) \ reduced.Br) + reduced.Dr
    return Dict{Symbol,Any}(:Ad => Ad, :Bd => Bd, :Cd => C, :Dd => D, :Ts => sample_time,
        :A => A, :B => B, :reduced => reduced, :gain => gain,
        :states => collect(DYNAMIC_STATES), :inputs => input_names, :outputs => output_names,
        :operating_point => (; x = xu, u = uv, p = pv, y = yop),
        :poles => poles, :time_constants_h => sort(times),
        :unstable_poles => sort(real(reduced.dropped)),
        :controllability => cond(_controllability(Ad, Bd)),
        :observability => cond(_observability(Ad, C)),
        :status => all(abs.(poles) .< 1.0) ? :compliant : :at_risk,
        :basis => "symbolic Jacobians + zero-order-hold discretisation of the ODE twin")
end

"""Jacobian of the output map by central differences (states or inputs)."""
function _numeric_output_jacobian(d::PlantDesign, xu::Vector{Float64}, uv::Vector{Float64},
    parameters::Dict{Symbol,Float64}, output_names::Vector{Symbol}, wrt::Symbol)
    n_y = length(output_names)
    vector = wrt === :state ? DYNAMIC_STATES : DYNAMIC_INPUTS
    base_x = Dict(q => xu[i] for (i, q) in enumerate(DYNAMIC_STATES))
    base_u = Dict(q => uv[i] for (i, q) in enumerate(DYNAMIC_INPUTS))
    J = zeros(n_y, length(vector))
    for (j, q) in enumerate(vector)
        step = wrt === :state ? max(1.0e-4, abs(xu[j]) * 1.0e-5) : max(1.0e-4, abs(uv[j]) * 1.0e-5)
        xp = copy(base_x); up = copy(base_u)
        xm = copy(base_x); um = copy(base_u)
        wrt === :state ? (xp[q] += step; xm[q] -= step) : (up[q] += step; um[q] -= step)
        yp = dynamic_outputs(d, xp, up, parameters)
        ym = dynamic_outputs(d, xm, um, parameters)
        for (i, o) in enumerate(output_names)
            J[i, j] = (yp[o] - ym[o]) / (2.0 * step)
        end
    end
    return J
end

"""
    _zoh(A, B, Ts) -> (Ad, Bd)

Zero-order-hold discretisation of a continuous state-space pair, from the matrix
exponential of the augmented matrix `[[A B]; [0 0]]`.
"""
function _zoh(A::AbstractMatrix, B::AbstractMatrix, Ts::Real)
    n, m = size(B)
    M = zeros(n + m, n + m)
    M[1:n, 1:n] .= A
    M[1:n, (n + 1):(n + m)] .= B
    E = exp(M * Ts)
    return E[1:n, 1:n], E[1:n, (n + 1):(n + m)]
end

"""
    stable_reduction(linear; margin = 1.0e-6) -> NamedTuple

Stable invariant subspace of a discrete linear model, as the controller and the state
estimator use it: a plant whose reaction section runs away at the operating point (the
thermal and acid loops of the twin each carry a positive eigenvalue there) cannot be
*estimated* by a filter, because the covariance of an unstable mode grows without bound
until the innovation matrix is singular.

The reduction projects the model onto the span of the eigenvectors inside the unit
circle, so the pair `(Ar, Br)` is stabilisable and `(Ar, Cr)` is detectable by
construction; `V` maps the reduced state back to the full one for the report, and
`dropped` carries the eigenvalues that were left out -- those are the modes the
controller has to hold, not the estimator.
"""
function stable_reduction(Ad::AbstractMatrix, Bd::AbstractMatrix, Cd::AbstractMatrix,
    Dd::AbstractMatrix; margin::Real = 1.0e-6)
    n = size(Ad, 1)
    F = eigen(Ad)
    keep = findall(p -> abs(p) <= 1.0 - margin, F.values)
    dropped = sort(real(F.values[setdiff(1:length(F.values), keep)]))
    if isempty(dropped)
        return (Ar = Ad, Br = Bd, Cr = Cd, Dr = Dd, V = Matrix{Float64}(I, n, n),
            dropped = Float64[], kept = n, nx = n, reduced = false)
    end
    ## a real, well conditioned basis of the stable eigenspace (the vectors of a complex
    ## pair are kept together, because the real span of Re and Im is what is invariant)
    Vs = real(F.vectors[:, keep])
    Q = Matrix(qr(Vs).Q)[:, 1:size(Vs, 2)]
    return (Ar = Q \ (Ad * Q), Br = Q \ Bd, Cr = Cd * Q, Dr = Dd, V = Q,
        dropped = dropped, kept = size(Q, 2), nx = n, reduced = true)
end

"""Convenience method for the dictionary a linearisation is returned in."""
stable_reduction(linear::Dict{Symbol,Any}; kwargs...) =
    stable_reduction(linear[:Ad], linear[:Bd], linear[:Cd], linear[:Dd]; kwargs...)

"""Controllability matrix of a discrete pair, for the conditioning report."""
function _controllability(Ad::AbstractMatrix, Bd::AbstractMatrix)
    n = size(Ad, 1)
    blocks = [Bd]
    for k in 1:(n - 1)
        push!(blocks, Ad^k * Bd)
    end
    return reduce(hcat, blocks)
end

"""Observability matrix of a discrete pair, for the conditioning report."""
function _observability(Ad::AbstractMatrix, Cd::AbstractMatrix)
    n = size(Ad, 1)
    blocks = [Cd]
    for k in 1:(n - 1)
        push!(blocks, Cd * Ad^k)
    end
    return reduce(vcat, blocks)
end






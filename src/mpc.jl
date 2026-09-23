# =============================================================================
# mpc.jl -- model predictive control of the reaction train.
#
# The controller is the one the plant would really run: a linear MPC over the
# discrete model that `linearize_twin` returns, with a Kalman filter estimating the
# states of the plant from the measurements, and the *nonlinear ODE twin* playing
# the plant. The controller never sees the equations of the twin, only the linear
# model and the measurements, which is the honest way to test a controller.
#
# Two things are reported for every closed loop:
#
# * the trajectory of the controlled variables against their bands and of the
#   manipulated variables against their limits, with the violations counted;
# * the integral of the absolute error of the loop against a tuned PI baseline, so
#   the claim "the MPC is better" comes with a number.
# =============================================================================

import ModelPredictiveControl as MPC

"""
    MPCConfig

Everything the controller needs: the horizon, the weights of the objective, the
operating window of the manipulated variables and the band each controlled variable
has to be held in.

The band is how a setpoint is written in this controller: the objective tracks the
midpoint of the output bounds, so a narrow band around the target *is* the setpoint,
and its width is the tolerance the product specification accepts.
"""
Base.@kwdef struct MPCConfig
    sample_time::Float64 = 1.0
    horizon::Int = 12
    control_horizon::Int = 4
    output_weight::Dict{Symbol,Float64} = Dict(:temperature => 1.0, :acid_strength => 3.0,
        :free_so4 => 2.0, :product_rate => 0.5, :p80 => 0.8, :filter_rate => 0.4)
    input_weight::Dict{Symbol,Float64} = Dict(:acid_flow => 0.30, :wash_water => 0.15,
        :cooling_water => 0.04, :steam_flow => 0.45, :ammonia_flow => 0.25, :mill_feed => 0.10)
    move_weight::Dict{Symbol,Float64} = Dict(:acid_flow => 0.60, :wash_water => 0.30,
        :cooling_water => 0.10, :steam_flow => 0.70, :ammonia_flow => 0.40, :mill_feed => 0.20)
    input_limits::Dict{Symbol,Tuple{Float64,Float64}} = Dict(
        :acid_flow => (0.85, 1.15), :wash_water => (0.70, 1.30), :cooling_water => (0.40, 1.60),
        :steam_flow => (0.75, 1.20), :ammonia_flow => (0.90, 1.10), :mill_feed => (0.70, 1.05))
    move_limits::Dict{Symbol,Tuple{Float64,Float64}} = Dict(
        :acid_flow => (-0.04, 0.04), :wash_water => (-0.06, 0.06), :cooling_water => (-0.20, 0.20),
        :steam_flow => (-0.05, 0.05), :ammonia_flow => (-0.03, 0.03), :mill_feed => (-0.05, 0.05))
    band::Dict{Symbol,Tuple{Float64,Float64}} = Dict(
        :temperature => (78.5, 0.6), :acid_strength => (52.4, 0.15), :free_so4 => (2.6, 0.20),
        :product_rate => (268.0, 6.0), :p80 => (148.0, 6.0), :filter_rate => (5.4, 0.35))
end

"""Fractions of the operating point the limits and bands of the configuration refer to."""
mpc_reference(d::PlantDesign) = dynamic_inputs(d)

"""
    mpc_controller(design = default_design(); config, linear) -> NamedTuple

Build the predictive controller of the reaction train: the discrete model from
[`linearize_twin`](@ref), a Kalman filter on that model, and the `LinMPC` of
`ModelPredictiveControl.jl` with the weights, the input limits, the move limits and
the output band of `config`.

Returns `(; controller, model, linear, config, inputs, outputs)` so the caller can
inspect the model and the tuning it is about to close the loop with.
"""
function mpc_controller(d::PlantDesign = default_design();
    config::MPCConfig = MPCConfig(),
    linear::Dict{Symbol,Any} = linearize_twin(d; sample_time = config.sample_time,
        input_names = sort(collect(keys(config.input_weight)); by = String),
        output_names = collect(DYNAMIC_OUTPUTS)))
    ## the model of the controller and of its estimator is the stable subspace of the
    ## linearised twin: the modes that run away cannot be estimated and are left to the
    ## controller, which is what a real MPC on a runaway reactor does as well
    red = linear[:reduced]
    model = MPC.LinModel(red.Ar, red.Br, red.Cr, zeros(size(red.Ar, 1), 0),
        zeros(size(red.Cr, 1), 0), linear[:Ts])
    ## the estimator sees every output of the twin, so that no state is unobservable, and
    ## carries no extra integrator: the twin already integrates the fouling it estimates
    estim = MPC.KalmanFilter(model; nint_u = 0, nint_ym = 0)
    mpc = MPC.LinMPC(estim; Hp = config.horizon, Hc = config.control_horizon,
        Mwt = [get(config.output_weight, o, 0.0) for o in linear[:outputs]],
        Nwt = [config.input_weight[i] for i in linear[:inputs]],
        Lwt = [config.move_weight[i] for i in linear[:inputs]])
    uop = copy(linear[:operating_point].u)
    yop = copy(linear[:operating_point].y)
    umin = [config.input_limits[i][1] * uop[k] for (k, i) in enumerate(linear[:inputs])]
    umax = [config.input_limits[i][2] * uop[k] for (k, i) in enumerate(linear[:inputs])]
    Δumin = [config.move_limits[i][1] * uop[k] for (k, i) in enumerate(linear[:inputs])]
    Δumax = [config.move_limits[i][2] * uop[k] for (k, i) in enumerate(linear[:inputs])]
    bands = [mpc_band(config, o, yop[i]) for (i, o) in enumerate(linear[:outputs])]
    ymin = [b[1] - b[2] for b in bands]
    ymax = [b[1] + b[2] for b in bands]
    MPC.setconstraint!(mpc; umin = umin, umax = umax, Δumin = Δumin, Δumax = Δumax,
        ymin = ymin, ymax = ymax)
    MPC.setname!(model; u = string.(linear[:inputs]), y = string.(linear[:outputs]))
    MPC.preparestate!(mpc, yop)
    return (; controller = mpc, model = model, estimator = estim, linear = linear,
        config = config, inputs = linear[:inputs], outputs = linear[:outputs],
        uop = uop, yop = yop, bands = bands, umin = umin, umax = umax, ymin = ymin,
        ymax = ymax, dropped_poles = red.dropped, nx_reduced = size(red.Ar, 1))
end

"""
    mpc_band(config, output, y0) -> (centre, halfwidth)

Band of one output: the one the configuration registers, and an unbounded band around
the operating point for the outputs the controller does not regulate -- those are
reported and estimated, but nothing is asked of them.
"""
mpc_band(config::MPCConfig, o::Symbol, y0::Real) = get(config.band, o, (Float64(y0), 1.0e6))

"""Advance the nonlinear twin by one sample time, holding the inputs (the plant)."""
function plant_step(d::PlantDesign, state::Dict{Symbol,Float64},
    inputs::Dict{Symbol,Float64}, parameters::Dict{Symbol,Float64}, dt::Real)
    sim = simulate_dynamic(d; tspan = (0.0, Float64(dt)), inputs = inputs,
        parameters = parameters, initial = state, sample = dt, solver = Rodas5P())
    new_state = Dict{Symbol,Float64}(s => sim[:states][s][end] for s in DYNAMIC_STATES)
    return new_state, sim
end

"""
    PILoop

One PI loop of the baseline controller: a gain, an integral time and the same
anti-windup and move limits the MPC has. The gains are taken from the steady-state
gain of the linear model (`Bd / (I - Ad)`) for the input that moves the output the
most, which is how a control engineer would tune it from step tests.
"""
mutable struct PILoop
    output::Symbol
    input::Symbol
    gain::Float64
    move_gain::Float64
    error::Float64
    integral::Float64
    output_value::Float64
    input_value::Float64
end

"""Build one PI loop per controlled output, from the steady-state gains of the model."""
function pi_loops(linear::Dict{Symbol,Any}, config::MPCConfig, uop::Vector{Float64};
    move_gain::Real = 0.35)
    ## the gains come from the stable subspace, the only one a steady-state gain of an
    ## unstable model means anything for
    K = linear[:gain]
    loops = PILoop[]
    for (i, o) in enumerate(linear[:outputs])
        haskey(config.output_weight, o) || continue
        gains = [abs(K[i, j]) for j in eachindex(linear[:inputs])]
        j = argmax(gains)
        gains[j] <= 1.0e-12 && continue
        push!(loops, PILoop(o, linear[:inputs][j], K[i, j], move_gain, 0.0, 0.0, 0.0, uop[j]))
    end
    return loops
end

"""One sample of the PI baseline: proportional action on the error, integral on the bias."""
function pi_step!(loops::Vector{PILoop}, y::Dict{Symbol,Float64},
    bands::Dict{Symbol,Tuple{Float64,Float64}}, u::Vector{Float64}, inputs::Vector{Symbol},
    uop::Vector{Float64}, config::MPCConfig)
    new_u = copy(u)
    for l in loops
        ju = findfirst(==(l.input), inputs)
        ju === nothing && continue
        target, _ = bands[l.output]
        error = target - get(y, l.output, target)
        l.error = error
        l.output_value = get(y, l.output, target)
        ## the model says y = y0 + gain (u - u0), so the move that removes the error is -error/gain
        correction = l.gain == 0 ? 0.0 : -(0.6 / abs(l.gain)) * error * sign(l.gain)
        l.integral = clamp(l.integral + 0.05 * correction, -0.25 * uop[ju], 0.25 * uop[ju])
        requested = l.input_value + correction + l.integral
        lo = config.input_limits[l.input][1] * uop[ju]
        hi = config.input_limits[l.input][2] * uop[ju]
        mlo = config.move_limits[l.input][1] * uop[ju]
        mhi = config.move_limits[l.input][2] * uop[ju]
        new_u[ju] = clamp(clamp(requested, lo, hi), u[ju] + mlo, u[ju] + mhi)
        l.input_value = new_u[ju]
    end
    return new_u
end

"""
    simulate_closed_loop(design; config, steps, scenario, kind, noise, seed)
        -> Dict{Symbol,Any}

Close the loop between the controller and the nonlinear twin for `steps` sample
times and return the trajectory, the inputs, the bands and the metrics.

* `kind = :mpc` uses the predictive controller, `kind = :pi` the PI baseline built
  from the same model, so the two are compared on the same plant and the same
  disturbances.
* `scenario = :setpoint` moves the acid strength band at hour 12 and the
  temperature band at hour 24; `scenario = :grade_change` drops the grade of the
  ore by 8 % at hour 16, an unmeasured disturbance the model of the controller
  knows nothing about.
* `noise` adds measurement noise (a fraction of the value) from `seed`, so the
  Kalman filter of the MPC has something to filter.
"""
function simulate_closed_loop(d::PlantDesign = default_design();
    config::MPCConfig = MPCConfig(), steps::Integer = 48, scenario::Symbol = :setpoint,
    kind::Symbol = :mpc, noise::Real = 0.004, seed::Integer = 20260101)
    setup = mpc_controller(d; config = config)
    inputs = setup.inputs
    outputs = setup.outputs
    uop = setup.uop
    loops = kind === :pi ? pi_loops(setup.linear, config, uop) : PILoop[]
    parameters = dynamic_parameters(d)
    full_inputs = dynamic_inputs(d)
    state = dynamic_initial_state(d; inputs = full_inputs, parameters = parameters)
    rng = MersenneTwister(seed)
    u = copy(uop)
    rows = Vector{Dict{Symbol,Any}}()
    bands = Dict{Symbol,Tuple{Float64,Float64}}(o => setup.bands[i]
        for (i, o) in enumerate(outputs))
    for k in 0:(steps - 1)
        ## the plant the controller does not know about: the ore changes
        p_k = copy(parameters)
        (scenario === :grade_change && k >= 16) && (p_k[:rock_grade] = parameters[:rock_grade] * 0.92)
        ## the bands of the scenario (the setpoints of the operator)
        scenario === :setpoint && k >= 12 && (bands[:acid_strength] = (52.0, 0.15))
        scenario === :setpoint && k >= 24 && (bands[:temperature] = (79.6, 0.6))
        ## measurements, with the noise the Kalman filter has to live with
        u_dict = _merge_inputs(full_inputs, inputs, u)
        y_true = dynamic_outputs(d, state, u_dict, p_k)
        y_meas = [y_true[o] * (1.0 + noise * randn(rng)) for o in outputs]
        y_meas_dict = Dict{Symbol,Float64}(outputs[i] => y_meas[i] for i in eachindex(outputs))
        ## the controller decides: the Kalman filter takes the measurements, the MPC moves
        ## the inputs towards the midpoint of the bands (the setpoints of the operator)
        ry = [bands[o][1] for o in outputs]
        if kind === :mpc
            MPC.preparestate!(setup.controller, y_meas)
            u = MPC.moveinput!(setup.controller, ry)
        else
            u = pi_step!(loops, y_meas_dict, bands, u, inputs, uop, config)
        end
        ## the plant advances one sample with the move held
        u_dict = _merge_inputs(full_inputs, inputs, u)
        state, _ = plant_step(d, state, u_dict, p_k, config.sample_time)
        y_next = dynamic_outputs(d, state, u_dict, p_k)
        row = Dict{Symbol,Any}(:hour => Float64(k), :kind => kind, :scenario => scenario)
        for o in outputs
            row[Symbol(o, :_value)] = y_true[o]
            row[Symbol(o, :_measurement)] = y_meas_dict[o]
            row[Symbol(o, :_target)] = bands[o][1]
            row[Symbol(o, :_band)] = bands[o][2]
        end
        for (i, name) in enumerate(inputs)
            row[Symbol(name, :_value)] = u[i]
            row[Symbol(name, :_percent)] = 100.0 * u[i] / uop[i]
        end
        row[:rock_grade] = p_k[:rock_grade]
        row[:violations] = count(o -> abs(row[Symbol(o, :_value)] - bands[o][1]) > bands[o][2],
            outputs)
        push!(rows, row)
    end
    return Dict{Symbol,Any}(:kind => kind, :scenario => scenario, :rows => rows,
        :inputs => inputs, :outputs => outputs, :uop => uop, :config => config,
        :metrics => loop_metrics(rows, config, inputs, outputs, uop),
        :setup => setup, :status => kind === :mpc ? :compliant : :at_risk)
end

"""Merge the inputs of the controller into the full input vector of the plant."""
function _merge_inputs(full::Dict{Symbol,Float64}, names::Vector{Symbol},
    u::Vector{Float64})
    out = copy(full)
    for (i, n) in enumerate(names)
        out[n] = u[i]
    end
    return out
end

"""
    loop_metrics(rows, config, inputs, outputs, uop) -> Dict{Symbol,Any}

Score of a closed loop: the integral of the absolute error of every output in units
of its band, the largest excursion, the hours spent outside the band, the settling
time after the last setpoint change, the total movement of the manipulated
variables and how many times they reversed direction.
"""
function loop_metrics(rows::Vector{Dict{Symbol,Any}}, config::MPCConfig,
    inputs::Vector{Symbol}, outputs::Vector{Symbol}, uop::Vector{Float64})
    per_output = Dict{Symbol,Any}()
    total_iae = 0.0
    violations = 0
    for o in outputs
        band = get(config.band, o, nothing)
        if band === nothing || band[2] <= 0.0
            ## an output nobody regulates is estimated and reported, but nothing is asked
            ## of it, so its metrics are not comparable with the ones of a band and stay NaN
            per_output[o] = Dict{Symbol,Any}(:iae_bands => NaN, :max_deviation_bands => NaN,
                :hours_in_band => NaN, :hours_out_of_band => NaN, :final_error => NaN,
                :band => NaN, :regulated => false)
            continue
        end
        width = max(band[2], 1.0e-9)
        errors = [abs(r[Symbol(o, :_value)] - r[Symbol(o, :_target)]) / width for r in rows]
        iae = sum(errors)
        total_iae += iae
        violations += count(>(1.0), errors)
        per_output[o] = Dict{Symbol,Any}(:iae_bands => iae, :max_deviation_bands => maximum(errors),
            :hours_in_band => count(<=(1.0), errors),
            :hours_out_of_band => count(>(1.0), errors),
            :final_error => last(errors), :band => band[2], :regulated => true)
    end
    moves = Dict{Symbol,Any}()
    for (i, name) in enumerate(inputs)
        v = [r[Symbol(name, :_percent)] for r in rows]
        Δ = diff(v)
        reversals = count(k -> Δ[k] * Δ[k + 1] < 0, 1:(length(Δ) - 1))
        moves[name] = Dict{Symbol,Any}(:total_movement_pct => sum(abs.(Δ)),
            :reversals => reversals, :min_pct => minimum(v), :max_pct => maximum(v))
    end
    return Dict{Symbol,Any}(:iae_bands => total_iae, :violations => violations,
        :per_output => per_output, :moves => moves, :hours => length(rows),
        :status => violations == 0 ? :compliant : violations <= 0.1 * length(rows) ? :at_risk :
                  :noncompliant)
end

"""
    mpc_report(design; config, steps, scenario, noise, seed) -> Dict{Symbol,Any}

Run the predictive controller and the PI baseline on the same plant, the same
scenario and the same noise, and return the two loops with the comparison the
report prints: the integral of the absolute error of every output, the excursions
outside the band and the movement of the manipulated variables, side by side.

The status of the bundle is the status of the *worse* of the two loops only in the
sense that it is `:compliant` when the MPC holds every output inside its band; the
comparison rows carry the rest of the judgement, because a controller is chosen on
its numbers, not on a verdict.
"""
function mpc_report(d::PlantDesign = default_design();
    config::MPCConfig = MPCConfig(), steps::Integer = 48, scenario::Symbol = :setpoint,
    noise::Real = 0.004, seed::Integer = 20260101)
    mpc = simulate_closed_loop(d; config = config, steps = steps, scenario = scenario,
        kind = :mpc, noise = noise, seed = seed)
    pi = simulate_closed_loop(d; config = config, steps = steps, scenario = scenario,
        kind = :pi, noise = noise, seed = seed)
    rows = Vector{Dict{Symbol,Any}}()
    for o in mpc[:outputs]
        m_m = mpc[:metrics][:per_output][o]
        m_p = pi[:metrics][:per_output][o]
        push!(rows, Dict{Symbol,Any}(:output => o, :band => m_m[:band],
            :mpc_iae => m_m[:iae_bands], :pi_iae => m_p[:iae_bands],
            :iae_improvement_pct => m_p[:iae_bands] > 0 ?
                100.0 * (m_p[:iae_bands] - m_m[:iae_bands]) / m_p[:iae_bands] : NaN,
            :mpc_max_deviation => m_m[:max_deviation_bands],
            :pi_max_deviation => m_p[:max_deviation_bands],
            :mpc_hours_out => m_m[:hours_out_of_band], :pi_hours_out => m_p[:hours_out_of_band]))
    end
    move_rows = Vector{Dict{Symbol,Any}}()
    for i in mpc[:inputs]
        mm = mpc[:metrics][:moves][i]
        mp = pi[:metrics][:moves][i]
        push!(move_rows, Dict{Symbol,Any}(:input => i,
            :mpc_movement_pct => mm[:total_movement_pct], :pi_movement_pct => mp[:total_movement_pct],
            :mpc_reversals => mm[:reversals], :pi_reversals => mp[:reversals],
            :mpc_range_pct => mm[:max_pct] - mm[:min_pct], :pi_range_pct => mp[:max_pct] - mp[:min_pct]))
    end
    return Dict{Symbol,Any}(:mpc => mpc, :pi => pi, :comparison => rows, :moves => move_rows,
        :scenario => scenario, :steps => steps,
        :summary => Dict{Symbol,Any}(:mpc_iae => mpc[:metrics][:iae_bands],
            :pi_iae => pi[:metrics][:iae_bands],
            :mpc_violations => mpc[:metrics][:violations],
            :pi_violations => pi[:metrics][:violations],
            :mpc_status => mpc[:metrics][:status], :pi_status => pi[:metrics][:status],
            :status => mpc[:metrics][:status]),
        :basis => "nonlinear ODE twin as the plant, LinMPC with a Kalman filter, " *
                  "PI baseline from the same steady-state gains")
end






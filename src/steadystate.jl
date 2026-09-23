# =============================================================================
# steadystate.jl -- the steady-state digital twin, built with ModelingToolkit.
#
# The twin is the mass and energy balance of the reaction train written once as a
# square system of nonlinear equations: feed, acidulation, digestion, filtration
# water balance, evaporation and ammoniation. The unknown of the balance is the
# operating point; the parameters are the design and the manipulated variables the
# operator sets. Solving it answers the question the control room asks all day:
# *given this ore, this acid and this much wash water, where does this plant end
# up?*
#
# Two properties make it a twin rather than a spreadsheet:
#
# * the algebraic loop of the recycle acid is solved, not iterated by hand, so
#   `acid_strength_weak` is a true fixed point of the water balance;
# * the residual of every equation is returned with the solution, and the
#   sensitivities of every unknown to every parameter come from the symbolic
#   Jacobian of the same equations.
# =============================================================================

"""Unknowns of the steady-state balance, in the order they are reported."""
const STEADY_UNKNOWNS = (:p2o5_fed, :excess, :free_so4, :temperature, :efficiency,
    :p2o5_digested, :gypsum, :p2o5_acid, :water_liquor, :acid_strength_weak, :steam,
    :water_evaporated, :ammonia, :product, :merchant_p2o5)

"""
    compile_function(expr, args...; kwargs...) -> Function

Compile a symbolic expression into a Julia function. `Symbolics.build_function`
returns a tuple `(out_of_place, in_place)` for systems and a single function for a
scalar expression, so the out-of-place form is taken here once, for the whole
package.
"""
function compile_function(expr, args...; kwargs...)
    f = Symbolics.build_function(expr, args...; expression = Val(false), kwargs...)
    return f isa Tuple ? first(f) : f
end


"""Parameters of the steady-state balance: the design and the operator's levers."""
const STEADY_PARAMETERS = (:rock_feed, :rock_grade, :free_cao_rate, :acid_flow,
    :wash_water, :recycle_mass, :cooling_water, :economy, :free_p2o5_cake, :ammonia_ratio,
    :product_grade, :merchant_grade, :acid_excess_design, :temperature_design,
    :weak_acid_design)

"""
    steady_state_system(design = default_design()) -> MTK.System

The steady-state balance as a square `System` of fifteen equations: the same
correlations the historian uses, written symbolically, with the water balance of
the filters closed by the strength of the weak acid itself.

The equations, in the order of [`STEADY_UNKNOWNS`](@ref):

1. P2O5 fed with the rock
2. acid excess delivered by the acid plant
3. free sulphate of the slurry (the crystallisation window)
4. temperature of the attack tanks (heat of reaction against the flash cooler)
5. digestion efficiency (temperature, sulphate, grind)
6. P2O5 digested
7. gypsum produced (apatite and free lime)
8. P2O5 to the filters after the water-soluble loss
9. water of the filtrate (wash, recycle, hydration and cake)
10. strength of the weak acid (the fixed point of the recycle loop)
11. water the evaporator removes
12. steam the evaporator needs
13. merchant acid produced
14. ammonia the sparger needs
15. product at its grade
"""
function steady_state_system(d::PlantDesign = default_design())
    v = Dict(s => Symbolics.variable(s) for s in STEADY_UNKNOWNS)
    p = Dict(s => Symbolics.variable(s) for s in STEADY_PARAMETERS)
    eqs = Equation[
        ## 1 -- P2O5 fed with the rock
        v[:p2o5_fed] ~ p[:rock_feed] * p[:rock_grade],
        ## 2 -- sulphuric acid excess delivered by the acid plant
        v[:excess] ~ p[:acid_flow] /
                     (STOICH.acid * v[:p2o5_fed] + ACID_PER_FREE_CAO * p[:free_cao_rate]) - 1.0,
        ## 3 -- free sulphate seen by the crystalliser
        v[:free_so4] ~ 2.6 + 30.0 * (v[:excess] - p[:acid_excess_design]) +
                       0.14 * (100.0 * p[:rock_grade] - 31.2),
        ## 4 -- temperature of the attack tanks: the heat of the reaction against the
        ##      heat capacity of the slurry, with the flash cooler as the lever
        v[:temperature] ~ 62.0 +
                          HEAT_OF_ATTACK_KJ_PER_KG_P2O5 * v[:p2o5_fed] * HEAT_RETENTION_SLURRY /
                          ((p[:rock_feed] + p[:acid_flow] + 0.30 * p[:recycle_mass]) *
                           SLURRY_CP_KJ_PER_KG_K) +
                          0.35 * (v[:free_so4] - 2.6) -
                          COOLING_GAIN_C_PER_M3PH * 62.0 * (p[:cooling_water] / 620.0 - 1.0),
        ## 5 -- digestion efficiency, the correlation of the plant control room
        v[:efficiency] ~ 0.985 + 0.0045 * (v[:temperature] - 78.5) -
                         0.0025 * (v[:free_so4] - 2.6),
        ## 6 -- P2O5 digested
        v[:p2o5_digested] ~ v[:p2o5_fed] * v[:efficiency],
        ## 7 -- gypsum produced
        v[:gypsum] ~ STOICH.gypsum * v[:p2o5_digested] +
                     GYPSUM_PER_FREE_CAO * p[:free_cao_rate],
        ## 8 -- P2O5 that reaches the filters
        v[:p2o5_acid] ~ v[:p2o5_digested] - v[:gypsum] * p[:free_p2o5_cake] / 100.0,
        ## 9 -- water carried by the filtrate, from the strength of the acid it contains
        v[:water_liquor] ~ v[:p2o5_acid] * (100.0 / v[:acid_strength_weak] - 1.0),
        ## 10 -- strength of the weak acid, the correlation the plant control room uses:
        ##       it falls with the wash water and rises with the free sulphate
        v[:acid_strength_weak] ~ p[:weak_acid_design] -
                                 0.021 * (p[:wash_water] - 195.0) +
                                 0.30 * (v[:free_so4] - 2.6),
        ## 11 -- water removed by the evaporators: the evaporators see the acid share of
        ##       the filtrate P2O5, the rest going back to the granulator as recycle acid
        v[:water_evaporated] ~ (v[:p2o5_acid] * 100.0 / v[:acid_strength_weak]) *
                               (1.0 - v[:acid_strength_weak] / (100.0 * p[:merchant_grade])),
        ## 12 -- steam the evaporators need
        v[:steam] ~ v[:water_evaporated] / p[:economy],
        ## 13 -- merchant acid produced
        v[:merchant_p2o5] ~ 0.24 * v[:p2o5_acid],
        ## 14 -- ammonia for the sparger
        v[:ammonia] ~ p[:ammonia_ratio] * 0.76 * v[:p2o5_acid],
        ## 15 -- product at its grade
        v[:product] ~ 0.76 * v[:p2o5_acid] / p[:product_grade],
    ]
    return System(eqs, [v[s] for s in STEADY_UNKNOWNS], [p[s] for s in STEADY_PARAMETERS];
        name = :steady_state)
end

"""Default parameter values of the steady-state twin, taken from the registered design."""
function steady_state_parameters(d::PlantDesign = default_design(); kwargs...)
    assay = ore_body(d.ore_body)
    ## the twin describes the attack section, whose feed is the flotation concentrate: the
    ## two-product balance of the flotation circuit turns the ROM rate into the concentrate
    ## rate at the recovery and the concentrate grade of the design
    rom = design_ore_tph(d)
    rock = rom * d.flotation_recovery * d.rock_p2o5 / max(d.flotation_grade, 1.0e-6)
    values = Dict{Symbol,Float64}(
        :rock_feed => rock,
        :rock_grade => d.flotation_grade,
        :free_cao_rate => free_cao(assay, rock),
        :acid_flow => acid_requirement(rock, upgraded_assay(assay, d.flotation_grade);
            excess = d.acid_excess).total,
        :wash_water => d.filter_area_m2 * 0.61,
        :recycle_mass => 900.0,
        :cooling_water => 620.0,
        :economy => d.evaporator_economy,
        :free_p2o5_cake => 100.0 * d.gypsum_free_p2o5,
        :ammonia_ratio => d.product === :map ? AMMONIA_PER_P2O5_MAP : AMMONIA_PER_P2O5_DAP,
        :product_grade => d.product === :map ? 0.52 : 0.4605,
        :merchant_grade => P2O5_MERCHANT_ACID,
        :acid_excess_design => d.acid_excess,
        :temperature_design => d.digestion_temperature_k - 273.15,
        :weak_acid_design => 100.0 * d.weak_acid_p2o5,
    )
    for (k, val) in kwargs
        values[Sym(k)] = Float64(val)
    end
    return values
end

"""Initial guess of the steady-state unknowns, from the design."""
function steady_state_initial_guess(d::PlantDesign = default_design())
    p2o5 = design_p2o5_tph(d)
    return Dict{Symbol,Float64}(:p2o5_fed => 0.5 * p2o5, :excess => d.acid_excess,
        :free_so4 => 2.6, :temperature => d.digestion_temperature_k - 273.15,
        :efficiency => 0.985, :p2o5_digested => 0.5 * p2o5, :gypsum => 2.0 * p2o5,
        :p2o5_acid => p2o5, :water_liquor => 600.0,
        :acid_strength_weak => d.weak_acid_p2o5, :steam => d.evaporator_steam_tph,
        :water_evaporated => 3.6 * d.evaporator_steam_tph, :ammonia => 0.24 * p2o5,
        :product => 0.5 * p2o5 / 0.46, :merchant_p2o5 => 0.24 * p2o5)
end

"""
    solve_steady_state(design = default_design(); parameters, guess, solver)
        -> Dict{Symbol,Any}

Solve the steady-state twin and return the symbol-keyed result:

* `:solution` -- every unknown with its value and its unit
* `:residuals` -- the residual of every equation, which is what proves the
  solution is a solution (the largest one is reported in `:max_residual`)
* `:status` -- `:compliant` when the solver converged and the residuals are small
* `:table` -- the rows the notebook and the report print
"""
function solve_steady_state(d::PlantDesign = default_design();
    parameters::Dict{Symbol,Float64} = steady_state_parameters(d),
    guess::Dict{Symbol,Float64} = steady_state_initial_guess(d),
    solver = NonlinearSolve.NewtonRaphson())
    sys = mtkcompile(steady_state_system(d))
    u0 = [Symbolics.variable(k) => v for (k, v) in guess]
    ps = [Symbolics.variable(k) => v for (k, v) in parameters]
    t0 = time()
    status = :compliant
    solution = copy(guess)
    try
        ## MTK v11 takes one merged map of initial guesses and parameter values
        prob = NonlinearProblem(sys, merge(Dict(u0), Dict(ps)))
        sol = solve(prob, solver; abstol = 1.0e-10, reltol = 1.0e-10)
        for k in STEADY_UNKNOWNS
            solution[k] = sol[Symbolics.variable(k)]
        end
        solver_ok(sol) || (status = :at_risk)
    catch err
        status = :noncompliant
        @warn "steady-state twin did not converge" exception = err
    end

    residuals = steady_state_residuals(d, solution, parameters)
    max_residual = isempty(residuals) ? 0.0 : maximum(abs.(values(residuals)))
    (max_residual > 1.0e-5 && status === :compliant) && (status = :at_risk)
    return Dict{Symbol,Any}(:status => status, :solution => solution, :residuals => residuals,
        :max_residual => max_residual, :parameters => parameters,
        :seconds => round(time() - t0, digits = 3),
        :table => [Dict{Symbol,Any}(:variable => k, :value => solution[k],
                :unit => steady_state_unit(k), :description => to_string(k))
                   for k in STEADY_UNKNOWNS],
        :basis => "ModelingToolkit nonlinear balance, mtkcompile + NonlinearProblem")
end

"""Unit of a steady-state unknown, for the tables."""
steady_state_unit(k::Symbol) = get((
    p2o5_fed = :t_ph, excess = :fraction, free_so4 = :wt_pct, temperature = :deg_c,
    efficiency = :fraction, p2o5_digested = :t_ph, gypsum = :t_ph, p2o5_acid = :t_ph,
    water_liquor = :t_ph, acid_strength_weak = :wt_pct, steam = :t_ph,
    water_evaporated = :t_ph, ammonia = :t_ph, product = :t_ph, merchant_p2o5 = :t_ph,
), k, :count)

"""
    steady_state_residuals(design, solution, parameters) -> Dict{Symbol,Float64}

Residual of every equation of the twin at a candidate solution: the right-hand side
recomputed and subtracted from the unknown. A solution is a solution when all of
them vanish, and the report states the largest one instead of claiming convergence.
"""
function steady_state_residuals(d::PlantDesign, s::Dict{Symbol,Float64},
    p::Dict{Symbol,Float64})
    g(k) = get(s, k, 0.0)
    q(k) = get(p, k, 0.0)
    base = STOICH.acid * g(:p2o5_fed) + ACID_PER_FREE_CAO * q(:free_cao_rate)
    return Dict{Symbol,Float64}(
        :p2o5_fed => g(:p2o5_fed) - q(:rock_feed) * q(:rock_grade),
        :excess => g(:excess) - (q(:acid_flow) / max(base, 1.0e-9) - 1.0),
        :free_so4 => g(:free_so4) - (2.6 + 30.0 * (g(:excess) - q(:acid_excess_design)) +
                       0.14 * (100.0 * q(:rock_grade) - 31.2)),
        :temperature => g(:temperature) - (62.0 +
            HEAT_OF_ATTACK_KJ_PER_KG_P2O5 * g(:p2o5_fed) * HEAT_RETENTION_SLURRY /
            ((q(:rock_feed) + q(:acid_flow) + 0.30 * q(:recycle_mass)) * SLURRY_CP_KJ_PER_KG_K) +
            0.35 * (g(:free_so4) - 2.6) -
            COOLING_GAIN_C_PER_M3PH * 62.0 * (q(:cooling_water) / 620.0 - 1.0)),
        :efficiency => g(:efficiency) - (0.985 +
                        0.0045 * (g(:temperature) - 78.5) -
                        0.0025 * (g(:free_so4) - 2.6)),
        :p2o5_digested => g(:p2o5_digested) - g(:p2o5_fed) * g(:efficiency),
        :gypsum => g(:gypsum) - (STOICH.gypsum * g(:p2o5_digested) +
                   GYPSUM_PER_FREE_CAO * q(:free_cao_rate)),
        :p2o5_acid => g(:p2o5_acid) -
                      (g(:p2o5_digested) - g(:gypsum) * q(:free_p2o5_cake) / 100.0),
        :water_liquor => g(:water_liquor) -
                         g(:p2o5_acid) * (100.0 / max(g(:acid_strength_weak), 1.0e-9) - 1.0),
        :acid_strength_weak => g(:acid_strength_weak) - (q(:weak_acid_design) -
                               0.021 * (q(:wash_water) - 195.0) +
                               0.30 * (g(:free_so4) - 2.6)),
        :water_evaporated => g(:water_evaporated) -
                             (g(:p2o5_acid) * 100.0 / max(g(:acid_strength_weak), 1.0e-9)) *
                             (1.0 - g(:acid_strength_weak) / (100.0 * q(:merchant_grade))),
        :steam => g(:steam) - g(:water_evaporated) / max(q(:economy), 1.0e-9),
        :merchant_p2o5 => g(:merchant_p2o5) - 0.24 * g(:p2o5_acid),
        :ammonia => g(:ammonia) - q(:ammonia_ratio) * 0.76 * g(:p2o5_acid),
        :product => g(:product) - 0.76 * g(:p2o5_acid) / max(q(:product_grade), 1.0e-9),
    )
end

"""Operating limits of the steady-state twin, as `(low, high)` pairs."""
const STEADY_LIMITS = Dict{Symbol,Tuple{Float64,Float64}}(
    :temperature => (72.0, 83.0), :free_so4 => (1.20, 7.00),
    :acid_strength_weak => (27.0, 33.0), :excess => (0.015, 0.055),
    :steam => (40.0, 130.0), :ammonia => (20.0, 55.0),
)

"""Check the solution against the operating limits, one row per limit."""
function battery_limits_check(d::PlantDesign, ss::Dict{Symbol,Any})
    sol = ss[:solution]
    rows = Vector{Dict{Symbol,Any}}()
    for (k, (lo, hi)) in sort(collect(STEADY_LIMITS); by = x -> String(x[1]))
        haskey(sol, k) || continue
        v = sol[k]
        push!(rows, Dict{Symbol,Any}(:variable => k, :value => v, :low => lo, :high => hi,
            :unit => steady_state_unit(k), :margin_low => v - lo, :margin_high => hi - v,
            :status => lo <= v <= hi ? :compliant :
                       (v < 0.9 * lo || v > 1.1 * hi) ? :noncompliant : :at_risk))
    end
    return rows
end

"""
    sensitivity_table(design; solution, parameters, names) -> Vector{Dict{Symbol,Any}}

Sensitivity of every unknown of the twin to the parameters the operator moves, from
the implicit function theorem applied to the symbolic system:
`du/dp = -(∂F/∂u)⁻¹ ∂F/∂p`, evaluated at the operating point. `:elasticity_pct` is
the relative sensitivity in per cent: a one per cent move of the parameter moves
the unknown by that many per cent.
"""
function sensitivity_table(d::PlantDesign = default_design();
    solution::Dict{Symbol,Float64} = solve_steady_state(d)[:solution],
    parameters::Dict{Symbol,Float64} = steady_state_parameters(d),
    names::Vector{Symbol} = [:acid_flow, :wash_water, :recycle_mass, :cooling_water,
        :rock_grade, :economy])
    sys = steady_state_system(d)
    x = [Symbolics.variable(s) for s in STEADY_UNKNOWNS]
    pp = [Symbolics.variable(s) for s in STEADY_PARAMETERS]
    F = [eq.lhs - eq.rhs for eq in MTK.equations(sys)]
    xu = [solution[k] for k in STEADY_UNKNOWNS]
    pv = [parameters[k] for k in STEADY_PARAMETERS]
    Ju = compile_function(Symbolics.jacobian(F, x), x, pp)(xu, pv)
    Jp = compile_function(Symbolics.jacobian(F, pp), x, pp)(xu, pv)
    S = -(Ju \ Jp)

    rows = Vector{Dict{Symbol,Any}}()
    for (i, u) in enumerate(STEADY_UNKNOWNS), k in names
        j = findfirst(==(k), STEADY_PARAMETERS)
        j === nothing && continue
        dudp = S[i, j]
        push!(rows, Dict{Symbol,Any}(:unknown => u, :parameter => k, :sensitivity => dudp,
            :elasticity_pct => solution[u] == 0 ? NaN :
                               100.0 * dudp * parameters[k] / solution[u],
            :unit => steady_state_unit(u)))
    end
    sort!(rows; by = r -> (-abs(r[:elasticity_pct]), String(r[:unknown])))
    return rows
end

"""
    steady_state_envelope(design; parameter, values, tracked) -> Vector{Dict{Symbol,Any}}

Re-solve the twin along a parameter sweep, which is how the operating envelope of
the plant is drawn: one row per value with the unknowns the figures plot.
"""
function steady_state_envelope(d::PlantDesign = default_design();
    parameter::Symbol = :rock_grade, values::AbstractVector = range(0.24, 0.34, length = 13),
    tracked::Vector{Symbol} = [:product, :steam, :acid_strength_weak, :temperature,
        :efficiency, :p2o5_acid])
    rows = Vector{Dict{Symbol,Any}}()
    for v in values
        params = steady_state_parameters(d; (parameter => Float64(v),)...)
        ss = solve_steady_state(d; parameters = params)
        row = Dict{Symbol,Any}(:parameter => parameter, :value => Float64(v),
            :status => ss[:status], :max_residual => ss[:max_residual])
        for k in tracked
            row[k] = ss[:solution][k]
        end
        push!(rows, row)
    end
    return rows
end

"""
    twin_report(design; parameters) -> Dict{Symbol,Any}

The steady-state twin as the report uses it: the solution, the residuals, the
battery-limit check, the sensitivities and the envelope, in one bundle.
"""
function twin_report(d::PlantDesign = default_design();
    parameters::Dict{Symbol,Float64} = steady_state_parameters(d))
    ss = solve_steady_state(d; parameters = parameters)
    return Dict{Symbol,Any}(:solution => ss, :limits => battery_limits_check(d, ss),
        :sensitivities => sensitivity_table(d; solution = ss[:solution], parameters = parameters),
        :envelope => steady_state_envelope(d),
        :status => ss[:status], :max_residual => ss[:max_residual],
        :table => ss[:table])
end




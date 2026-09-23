# =============================================================================
# optimization.jl -- the three decisions the plant takes every day.
#
# 1. `blend_optimization` -- which ore bodies to buy and in what proportion, so
#    that the digester is fed an assay it can attack at the lowest delivered cost.
#    A linear program over the assays of `ORE_BODIES`, solved with HiGHS, with the
#    dual prices of the quality constraints reported as the marginal value of a
#    unit of each specification.
# 2. `operating_point_optimization` -- where to run the reaction, filtration,
#    evaporation and granulation sections, as a nonlinear program over the same
#    correlations the twin uses, solved with Ipopt.
# 3. `sourcing_optimization` -- the monthly sourcing plan as a mixed-integer
#    program, because a body is bought by the shipload, not by the tonne.
#
# Every model is built from the symbol-keyed dictionaries of the package, so a
# constraint can be traced back to the design value it came from.
# =============================================================================

import JuMP
import HiGHS
import Ipopt

"""Build a silent JuMP model on the given optimiser factory."""
function _model(factory)
    m = JuMP.Model(factory)
    JuMP.set_silent(m)
    if factory === Ipopt.Optimizer
        ## the adaptive barrier and the looser tolerance are what keeps the nonlinear
        ## program of the operating point converging on the kinks of the correlations
        JuMP.set_optimizer_attribute(m, "mu_strategy", "adaptive")
        JuMP.set_optimizer_attribute(m, "tol", 1.0e-7)
        JuMP.set_optimizer_attribute(m, "max_iter", 3000)
    end
    return m
end

"""Status of a solved JuMP model, as one of the package's status symbols."""
function solve_status(m::JuMP.Model)
    JuMP.termination_status(m) in (JuMP.MOI.OPTIMAL, JuMP.MOI.LOCALLY_SOLVED,
        JuMP.MOI.ALMOST_OPTIMAL, JuMP.MOI.ALMOST_LOCALLY_SOLVED) && return :compliant
    JuMP.termination_status(m) in (JuMP.MOI.INFEASIBLE, JuMP.MOI.LOCALLY_INFEASIBLE) &&
        return :noncompliant
    return :at_risk
end

"""Symbol-keyed row for a solved decision variable of a JuMP model."""
function solution_row(name::Symbol, value::Real, unit::Symbol, share::Real)
    return Dict{Symbol,Any}(:name => name, :value => value, :unit => unit,
        :share_pct => share)
end

"""
    blend_optimization(; design, bodies, demand_tph, quality, availability)
        -> Dict{Symbol,Any}

Linear program for the daily ore blend: minimise the delivered cost of the blend
that delivers `demand_tph` tonnes of P2O5 per hour to the attack tanks, subject to
the assay specifications the digester, the filters and the granulator impose.

The specifications are the ones the flowsheet makes explicit:

| Specification | Limit | Why |
|---|---|---|
| `Fe2O3 + Al2O3` | `quality.fe_al_max` | iron and aluminium raise the filtration resistance |
| `MgO` | `quality.mgo_max` | magnesium consumes acid and ruins the crystal growth |
| `SiO2` | `quality.sio2_max` | free silica gels the slurry |
| `CaO : P2O5` | `quality.cao_p2o5_max` | the acidulation ratio of the blend |
| CO2 | `quality.co2_max` | carbonate consumes acid and foams the digester |

The dual prices of the quality constraints are reported, because they answer the
question of the buyer: what is one more tenth of a per cent of iron worth?
"""
function blend_optimization(c::Campaign; design::PlantDesign = c.design,
    bodies::Vector{Symbol} = ore_bodies(), demand_tph::Real = design_p2o5_tph(design) * 1.2,
    quality::NamedTuple = (fe_al_max = 4.60, mgo_max = 0.90, sio2_max = 7.50,
        cao_p2o5_max = 1.640, co2_max = 6.50),
    availability::Dict{Symbol,Float64} = Dict(b => 3.0 * demand_tph / design.rock_p2o5
                                              for b in bodies),
    feed_grade::Real = 0.290)
    m = _model(HiGHS.Optimizer)
    assays = Dict(b => ore_body(b) for b in bodies)
    rock_tph = demand_tph / max(feed_grade, 1.0e-6)
    x = Dict{Symbol,Any}(b => JuMP.@variable(m, lower_bound = 0.0,
            upper_bound = get(availability, b, Inf), base_name = string(b)) for b in bodies)
    JuMP.@constraint(m, sum(x[b] for b in bodies) == rock_tph)
    ## the blend has to keep the grade of the registered ore: the optimiser is asked to cut
    ## the cost of the same quality, not to buy a cheaper and poorer feed
    JuMP.@constraint(m, sum(x[b] * assays[b][:p2o5] for b in bodies) >= rock_tph * feed_grade)
    p2o5 = JuMP.@constraint(m, sum(x[b] * assays[b][:p2o5] for b in bodies) >= demand_tph)
    fe_al = JuMP.@constraint(m, sum(x[b] * (assays[b][:fe2o3] + assays[b][:al2o3])
                                    for b in bodies) <= rock_tph * quality.fe_al_max / 100.0)
    mgo = JuMP.@constraint(m, sum(x[b] * assays[b][:mgo] for b in bodies) <=
                              rock_tph * quality.mgo_max / 100.0)
    sio2 = JuMP.@constraint(m, sum(x[b] * assays[b][:sio2] for b in bodies) <=
                               rock_tph * quality.sio2_max / 100.0)
    cao = JuMP.@constraint(m, sum(x[b] * (assays[b][:cao] - quality.cao_p2o5_max *
                                          assays[b][:p2o5]) for b in bodies) <= 0.0)
    co2 = JuMP.@constraint(m, sum(x[b] * assays[b][:co2] for b in bodies) <=
                              rock_tph * quality.co2_max / 100.0)
    JuMP.@objective(m, Min, sum(x[b] * ORE_PRICES[b] for b in bodies))
    JuMP.optimize!(m)
    status = solve_status(m)
    rows = Vector{Dict{Symbol,Any}}()
    total_p2o5 = 0.0
    for b in bodies
        v = JuMP.value(x[b])
        total_p2o5 += v * assays[b][:p2o5]
        push!(rows, Dict{Symbol,Any}(:body => b, :tonnes_ph => v, :share_pct => 100.0 * v / rock_tph,
            :price => ORE_PRICES[b], :cost_ph => v * ORE_PRICES[b],
            :p2o5 => 100.0 * assays[b][:p2o5], :cao_p2o5 => ratio(assays[b], :cao, :p2o5),
            :fe_al => 100.0 * (assays[b][:fe2o3] + assays[b][:al2o3]), :mgo => 100.0 * assays[b][:mgo]))
    end
    sort!(rows; by = r -> -r[:tonnes_ph])
    mixed = status === :compliant ? blend([assays[b] for b in sort(bodies; by = String)],
        [JuMP.value(x[b]) for b in sort(bodies; by = String)]) :
        blend_assay(Dict(b => 1.0 for b in bodies))
    objective = status === :compliant ? JuMP.objective_value(m) : NaN
    duals = status === :compliant ? Dict{Symbol,Float64}(
        :p2o5 => JuMP.dual(p2o5), :fe_al => JuMP.dual(fe_al), :mgo => JuMP.dual(mgo),
        :sio2 => JuMP.dual(sio2), :cao_p2o5 => JuMP.dual(cao), :co2 => JuMP.dual(co2)) :
        Dict{Symbol,Float64}()
    return Dict{Symbol,Any}(:status => status, :rows => rows, :rock_tph => rock_tph,
        :p2o5_tph => total_p2o5, :objective => objective,
        :cost_per_t_rock => objective / rock_tph, :cost_per_t_p2o5 => objective / max(total_p2o5, 1.0e-9),
        :blend => mixed, :blend_grade => p2o5_grade(mixed), :blend_bpl => bpl_grade(mixed),
        :cao_p2o5_ratio => ratio(mixed, :cao, :p2o5),
        :acid_demand => acid_requirement(rock_tph, mixed; excess = design.acid_excess).total,
        :specifications => quality, :duals => duals, :solver => :HiGHS,
        :basis => "linear program over the registered assays of the ore bodies")
end

"""
    operating_point_optimization(; design, grade, prices) -> Dict{Symbol,Any}

Nonlinear program for the operating point of the reaction, filtration, evaporation
and granulation sections, solved with Ipopt over the same correlations the plant
model uses:

* maximise the margin of the day, `product value + merchant acid - rock - acid -
  ammonia - steam - power - water - gypsum disposal`
* subject to the operating window of the design: acid excess, attack temperature,
  free sulphate, acid strength, filter rate, steam header, product nitrogen,
  moisture and solubility, and the throughput capacity of every section.

The result reports the decisions and the controlled variables at the optimum, plus
the termination report of the solver, so the notebook can show what the plant is
limited by today.
"""
function operating_point_optimization(c::Campaign; design::PlantDesign = c.design,
    grade::Real = masked_mean(c, :ROCK_P2O5, mode_mask(c)) / 100.0, prices = ECONOMICS)
    m = _model(Ipopt.Optimizer)
    p2o5_design = design_p2o5_tph(design)
    ## ---- decisions, with the operating window of every lever: an unbounded search is
    ##      how a nonlinear program ends up infeasible on a badly scaled iterate
    concentrate_design = design_concentrate_tph(design)
    wash_design = design.filter_area_m2 * 0.61
    acid_design = acid_requirement(concentrate_design,
        upgraded_assay(ore_body(design.ore_body), design.flotation_grade);
        excess = design.acid_excess).total
    ammonia_design = AMMONIA_PER_P2O5_DAP * 0.76 * p2o5_design
    recycle_design = dynamic_inputs(design)[:recycle_mass]
    rock = JuMP.@variable(m, lower_bound = 0.30 * concentrate_design,
        upper_bound = 1.15 * concentrate_design, start = concentrate_design)
    acid = JuMP.@variable(m, lower_bound = 0.60 * acid_design, upper_bound = 1.40 * acid_design,
        start = acid_design)
    wash = JuMP.@variable(m, lower_bound = 0.50 * wash_design, upper_bound = 1.60 * wash_design,
        start = wash_design)
    steam = JuMP.@variable(m, lower_bound = 0.50 * design.evaporator_steam_tph,
        upper_bound = 1.25 * design.evaporator_steam_tph, start = design.evaporator_steam_tph)
    ammonia = JuMP.@variable(m, lower_bound = 0.50 * ammonia_design,
        upper_bound = 1.20 * ammonia_design, start = ammonia_design)
    cooling = JuMP.@variable(m, lower_bound = 0.40 * 620.0, upper_bound = 1.60 * 620.0,
        start = 620.0)
    recycle = JuMP.@variable(m, lower_bound = 0.50 * recycle_design,
        upper_bound = 1.50 * recycle_design, start = recycle_design)

    ## ---- the process correlations, written as expressions of the decisions
    assay = upgraded_assay(ore_body(design.ore_body), grade)
    p2o5_fed = rock * grade
    stoich = STOICH.acid * p2o5_fed
    carbonate = ACID_PER_FREE_CAO * free_cao(assay, 1.0) * rock
    excess = acid / (stoich + carbonate + 1.0e-6) - 1.0
    free_so4 = 2.6 + 30.0 * (excess - design.acid_excess)
    heat = HEAT_OF_ATTACK_KJ_PER_KG_P2O5 * p2o5_fed
    slurry = rock + acid + 0.30 * recycle
    temperature = 62.0 + heat / (slurry * SLURRY_CP_KJ_PER_KG_K) * HEAT_RETENTION_SLURRY +
                  0.35 * (free_so4 - 2.6) -
                  COOLING_GAIN_C_PER_M3PH * 62.0 * (cooling / 620.0 - 1.0)
    efficiency = 0.985 + 0.0045 * (temperature - 78.5) - 0.0025 * (free_so4 - 2.6)
    p2o5_digested = p2o5_fed * efficiency
    gypsum = STOICH.gypsum * p2o5_digested
    wash_ratio = wash / p2o5_digested
    weak_strength = 100.0 * design.weak_acid_p2o5 - 0.021 * (wash - 195.0) +
                    0.30 * (free_so4 - 2.6) - 0.008 * (rock - design_concentrate_tph(design))
    filter_rate = 24.0 * p2o5_digested / design.filter_area_m2
    ## the correlations are kept free of `max` guards inside the program: a kink in a
    ## constraint is what sends the barrier method into its restoration phase
    free_loss_pct = 100.0 * design.gypsum_free_p2o5 * (1.6 / wash_ratio)^0.85 *
                    (5.4 / filter_rate)^0.35
    free_loss = gypsum * free_loss_pct / 100.0
    p2o5_acid = p2o5_digested - free_loss
    duty_water = p2o5_acid * (100.0 / weak_strength - 100.0 / 52.0)
    steam_required = duty_water / design.evaporator_economy
    strength = 100.0 * P2O5_MERCHANT_ACID - 0.09 * (steam - design.evaporator_steam_tph)
    merchant = 0.24 * p2o5_acid
    p2o5_plant = 0.76 * p2o5_acid
    product = p2o5_plant / 0.4605
    nitrogen = 100.0 * ammonia * (14.006 / 17.031) / product
    moisture = 1.75 - 0.075 * 0.35 * (design.dryer_fuel_gj_per_t * product / 10.0)
    wsp = 88.5 + 0.5 * (ammonia / (AMMONIA_PER_P2O5_DAP * p2o5_plant) - 1.0) * 10.0
    electricity = 2.0 * rock + 0.42 + 1.9 * product / 1000.0
    fuel = design.dryer_fuel_gj_per_t * product
    ## ---- the operating window
    JuMP.@constraint(m, rock <= 1.10 * design_concentrate_tph(design))
    JuMP.@constraint(m, rock * grade <= 1.15 * p2o5_design)
    JuMP.@constraint(m, excess >= 0.015)
    JuMP.@constraint(m, excess <= 0.055)
    JuMP.@constraint(m, free_so4 >= 1.20)
    JuMP.@constraint(m, temperature <= 83.0)
    JuMP.@constraint(m, temperature >= 72.0)
    JuMP.@constraint(m, weak_strength >= 27.0)
    ## the filters of this plant run above the rate the register calls nominal (the filter
    ## area is the bottleneck the campaign also shows): the window is what the vacuum and
    ## the cake allow, not what was specified
    JuMP.@constraint(m, filter_rate <= 13.0)
    JuMP.@constraint(m, steam <= 1.25 * design.evaporator_steam_tph)
    JuMP.@constraint(m, steam >= steam_required)
    JuMP.@constraint(m, strength >= 52.0)
    JuMP.@constraint(m, nitrogen >= 17.40)
    JuMP.@constraint(m, nitrogen <= 19.20)
    JuMP.@constraint(m, moisture <= 2.00)
    JuMP.@constraint(m, wsp >= 85.0)
    ## the product the design chain delivers at the design P2O5, not the nameplate rate of
    ## the granulation line: the plant has to make at least nine tenths of it
    JuMP.@constraint(m, product >= 0.85 * 0.76 * p2o5_design / 0.4605)
    JuMP.@constraint(m, cooling <= 1100.0)
    ## P2O5 reaching the filters: the acid share of it is what the evaporators see, so the
    ## ceiling is the throughput of the digester, not the acid plant
    JuMP.@constraint(m, p2o5_acid <= 1.15 * p2o5_design)
    ## ---- the margin of the day
    revenue = product * prices[:dap_per_t] + merchant * prices[:merchant_acid_per_t_p2o5] *
              design.weak_acid_p2o5
    cost = rock * prices[:rock_per_t] + acid * (prices[:sulphur_per_t] / 3.06) +
           ammonia * prices[:ammonia_per_t] + steam * prices[:steam_per_t] +
           electricity * prices[:electricity_per_kwh] + fuel * prices[:natural_gas_per_gj] +
           (wash + 60.0) * prices[:process_water_per_m3] + gypsum * prices[:gypsum_disposal_per_t]
    JuMP.@objective(m, Max, revenue - cost)
    JuMP.optimize!(m)
    status = solve_status(m)
    ## the last iterate is reported even when Ipopt gives up before the optimum: a plant
    ## engineer wants to see where the search stopped and which limit it hit
    has_solution = JuMP.has_values(m)
    v(x) = has_solution ? JuMP.value(x) : NaN
    ## a nonlinear program over correlations that carry kinks can stop in the restoration
    ## phase with an iterate that already satisfies its own window; the program is
    ## therefore validated against the window before the verdict of the solver is taken
    window_violation = function ()
        has_solution || return -Inf
        r, a, w, s, n, cl = (JuMP.value(rock), JuMP.value(acid), JuMP.value(wash),
            JuMP.value(steam), JuMP.value(ammonia), JuMP.value(cooling))
        fed = r * grade
        base = STOICH.acid * fed + ACID_PER_FREE_CAO * free_cao(assay, 1.0) * r
        ex = a / base - 1.0
        so4 = 2.6 + 30.0 * (ex - design.acid_excess) + 0.14 * (100.0 * grade - 31.2)
        heat = HEAT_OF_ATTACK_KJ_PER_KG_P2O5 * fed
        temp = 62.0 + heat / ((r + a + 0.30 * JuMP.value(recycle)) * SLURRY_CP_KJ_PER_KG_K) *
               HEAT_RETENTION_SLURRY + 0.35 * (so4 - 2.6) -
               COOLING_GAIN_C_PER_M3PH * 62.0 * (cl / 620.0 - 1.0)
        eff = 0.985 + 0.0045 * (temp - 78.5) - 0.0025 * (so4 - 2.6)
        digested = fed * eff
        gypsum_rate = STOICH.gypsum * digested
        weak = 100.0 * design.weak_acid_p2o5 - 0.021 * (w - 195.0) + 0.30 * (so4 - 2.6) -
               0.008 * (r - design_concentrate_tph(design))
        rate = 24.0 * digested / design.filter_area_m2
        loss = gypsum_rate * design.gypsum_free_p2o5 * (1.6 / (w / digested))^0.85 *
               (5.4 / rate)^0.35
        acid_p2o5 = digested - loss
        water = acid_p2o5 * (100.0 / weak - 100.0 / 52.0)
        need = water / design.evaporator_economy
        str = 100.0 * P2O5_MERCHANT_ACID - 0.09 * (s - design.evaporator_steam_tph)
        plant_p2o5 = 0.76 * acid_p2o5
        n_pct = 100.0 * n * (14.006 / 17.031) / (plant_p2o5 / 0.4605)
        moist = 1.75 - 0.075 * 0.35 * (design.dryer_fuel_gj_per_t * plant_p2o5 / 0.4605 / 10.0)
        solute = 88.5 + 0.5 * (n / (AMMONIA_PER_P2O5_DAP * plant_p2o5) - 1.0) * 10.0
        return minimum((ex - 0.015, 0.055 - ex, so4 - 1.20, 83.0 - temp, temp - 72.0,
            weak - 27.0, 13.0 - rate, 1.25 * design.evaporator_steam_tph - s, s - need,
            str - 52.0, n_pct - 17.40, 19.20 - n_pct, 2.00 - moist, solute - 85.0,
            plant_p2o5 / 0.4605 - 0.85 * 0.76 * p2o5_design / 0.4605,
            1.15 * p2o5_design - fed, 1.15 * p2o5_design - acid_p2o5))
    end
    violation = window_violation()
    if status !== :compliant
        ## a second attempt from the operating point the campaign recorded
        mask = mode_mask(c)
        hours = max(count(mask), 1)
        JuMP.set_start_value(rock, masked_sum(c, :ROCK_FEED, mask) / hours)
        JuMP.set_start_value(acid, masked_sum(c, :H2SO4_FLOW, mask) / hours)
        JuMP.set_start_value(wash, masked_sum(c, :WASH_WATER_FLOW, mask) / hours)
        JuMP.set_start_value(steam, masked_sum(c, :STEAM_FLOW, mask) / hours)
        JuMP.set_start_value(ammonia, masked_sum(c, :AMMONIA_FLOW, mask) / hours)
        JuMP.optimize!(m)
        status = solve_status(m)
        violation = window_violation()
    end
    (status !== :compliant && violation >= -1.0e-6) && (status = :compliant)
    has_solution = JuMP.has_values(m)
    ok = has_solution && status === :compliant
    decisions = Dict{Symbol,Float64}(:rock_feed => v(rock), :sulphuric_acid_flow => v(acid),
        :recycle_acid_flow => v(recycle), :wash_water_flow => v(wash),
        :cooling_water_flow => v(cooling), :steam_flow => v(steam),
        :ammonia_flow => v(ammonia))
    controlled = Dict{Symbol,Float64}(:acid_excess => v(excess) * 100.0,
        :reactor_temperature => v(temperature), :sulfate_ratio => v(free_so4),
        :acid_strength => v(strength), :acid_strength_weak => v(weak_strength),
        :filtration_rate => v(filter_rate), :gypsum_free_p2o5 => v(free_loss_pct),
        :product_n => v(nitrogen), :product_moisture => v(moisture), :product_wsp => v(wsp),
        :p2o5_product => v(p2o5_plant), :p2o5_fed => v(p2o5_fed),
        :gypsum_t => v(gypsum), :steam_required => v(steam_required))
    return Dict{Symbol,Any}(:status => status, :solved => ok,
        :objective => ok ? JuMP.objective_value(m) : NaN,
        :margin_per_t_product => ok ? JuMP.objective_value(m) / max(JuMP.value(product), 1.0) : NaN,
        :decisions => decisions, :controlled => controlled, :product_tph => v(product),
        :revenue_per_h => v(revenue), :cost_per_h => v(cost),
        :row => [Dict{Symbol,Any}(:variable => k, :value => val, :kind => :decision)
                 for (k, val) in decisions],
        :controlled_row => [Dict{Symbol,Any}(:variable => k, :value => val, :kind => :controlled)
                            for (k, val) in controlled],
        :solver => :Ipopt, :termination => JuMP.termination_status(m),
        :iterations => JuMP.barrier_iterations(m), :solve_time_s => JuMP.solve_time(m),
        :basis => "nonlinear program over the correlations of the digital twin")
end


"""
    sourcing_optimization(; design, months, bodies, max_bodies_per_month)
        -> Dict{Symbol,Any}

Mixed-integer program for the annual sourcing plan: how many tonnes of each ore
body to buy in each month, so that the P2O5 demand of every month is met at the
lowest delivered cost, with the physical constraints of the mine and of the port:

* at most `max_bodies_per_month` bodies in a month (a stock pile is not a blend of
  everything),
* the annual availability of each body,
* a fixed cost per body and month for the campaign change-over.

The integrality is what makes this a MILP: a body is ordered by the shipload.
"""
function sourcing_optimization(c::Campaign; design::PlantDesign = c.design,
    months::Integer = 12, bodies::Vector{Symbol} = ore_bodies(),
    max_bodies_per_month::Integer = 2, fixed_per_body_month::Real = 25_000.0)
    m = _model(HiGHS.Optimizer)
    assays = Dict(b => ore_body(b) for b in bodies)
    p2o5_year = design.site.capacity_t_p2o5_year / max(design.flotation_recovery, 1.0e-6)
    per_month = p2o5_year / months
    ## every body can deliver up to 1.6 times its equal share of the annual need: the
    ## share is what makes the plan feasible at all, because the mine cannot supply the
    ## whole year from one bench
    annual_availability = Dict(b => 1.6 * p2o5_year / (length(bodies) * assays[b][:p2o5])
                               for b in bodies)
    x = Dict{Tuple{Symbol,Int},Any}()
    y = Dict{Tuple{Symbol,Int},Any}()
    for b in bodies, k in 1:months
        x[(b, k)] = JuMP.@variable(m, lower_bound = 0.0,
            upper_bound = annual_availability[b] / 3.0, base_name = string(b, "_", k))
        y[(b, k)] = JuMP.@variable(m, binary = true, base_name = string(b, "_use_", k))
        JuMP.@constraint(m, x[(b, k)] <= annual_availability[b] / 3.0 * y[(b, k)])
    end
    for k in 1:months
        JuMP.@constraint(m, sum(x[(b, k)] * assays[b][:p2o5] for b in bodies) >= per_month)
        JuMP.@constraint(m, sum(y[(b, k)] for b in bodies) <= max_bodies_per_month)
    end
    for b in bodies
        JuMP.@constraint(m, sum(x[(b, k)] for k in 1:months) <= annual_availability[b])
    end
    JuMP.@objective(m, Min, sum(x[(b, k)] * ORE_PRICES[b] for b in bodies for k in 1:months) +
                              fixed_per_body_month * sum(y[(b, k)] for b in bodies for k in 1:months))
    JuMP.optimize!(m)
    status = solve_status(m)
    ok = status === :compliant
    val(pair) = ok ? JuMP.value(x[pair]) : 0.0
    use(pair) = ok ? round(Int, JuMP.value(y[pair])) : 0
    total = sum(val((b, k)) for b in bodies for k in 1:months)
    rows = [Dict{Symbol,Any}(:body => b, :tonnes => sum(val((b, k)) for k in 1:months),
        :share_pct => total > 0 ? 100.0 * sum(val((b, k)) for k in 1:months) / total : 0.0,
        :price => ORE_PRICES[b],
        :cost => sum(val((b, k)) for k in 1:months) * ORE_PRICES[b],
        :months_active => sum(use((b, k)) for k in 1:months),
        :p2o5 => 100.0 * assays[b][:p2o5]) for b in bodies]
    sort!(rows; by = r -> -r[:tonnes])
    month_rows = [Dict{Symbol,Any}(:month => k,
        :p2o5_t => sum(val((b, k)) * assays[b][:p2o5] for b in bodies),
        :bodies => join([string(b) for b in bodies if use((b, k)) == 1], ", "),
        :rock_t => sum(val((b, k)) for b in bodies),
        :cost => sum(val((b, k)) * ORE_PRICES[b] for b in bodies)) for k in 1:months]
    return Dict{Symbol,Any}(:status => status, :rows => rows, :months => month_rows,
        :objective => ok ? JuMP.objective_value(m) : NaN, :tonnes => total,
        :p2o5_t => sum(val((b, k)) * assays[b][:p2o5] for b in bodies for k in 1:months),
        :cost_per_t_p2o5 => ok ? JuMP.objective_value(m) /
                                 max(sum(val((b, k)) * assays[b][:p2o5] for b in bodies
                                         for k in 1:months), 1.0e-9) : NaN,
        :variables => JuMP.num_variables(m), :binaries => length(y),
        :solver => :HiGHS, :basis => "mixed-integer program, a body is bought by the shipload")
end

"""
    optimization_report(campaign, kpi; design, frameworks) -> Dict{Symbol,Any}

Run the three models of the plant and return the bundle the optimisation notebook
and the report are built from: `:blend`, `:operating_point`, `:sourcing`, their
tables and a `:summary` with the status of each solve and the value each one is
worth against the campaign.
"""
function optimization_report(c::Campaign, kpi = nothing; design::PlantDesign = c.design,
    bodies::Vector{Symbol} = ore_bodies())
    blend = blend_optimization(c; design = design, bodies = bodies)
    point = operating_point_optimization(c; design = design)
    sourcing = sourcing_optimization(c; design = design, bodies = bodies)
    current_grade = design.rock_p2o5 * 100.0
    blend_gain = kpi === nothing ? NaN :
                 (blend[:blend_grade] - current_grade) *
                 (kpi[:attack][:p2o5_fed] / 100.0) * ECONOMICS[:merchant_acid_per_t_p2o5]
    point_gain = kpi === nothing ? NaN :
                 point[:objective] * kpi[:period][:operating_hours] -
                 kpi[:cost][:margin] * 1000.0
    return Dict{Symbol,Any}(:blend => blend, :operating_point => point, :sourcing => sourcing,
        :blend_rows => blend[:rows], :operating_rows => vcat(point[:row], point[:controlled_row]),
        :sourcing_rows => sourcing[:rows], :sourcing_months => sourcing[:months],
        :summary => Dict{Symbol,Any}(
            :blend_status => blend[:status], :point_status => point[:status],
            :sourcing_status => sourcing[:status],
            :blend_grade => blend[:blend_grade], :current_grade => current_grade,
            :optimised_margin_per_h => point[:objective],
            :blend_value_per_year => blend_gain,
            :point_value_per_year => point_gain,
            :sourcing_cost_per_t_p2o5 => sourcing[:cost_per_t_p2o5],
            :status => all(s -> s === :compliant,
                (blend[:status], point[:status], sourcing[:status])) ? :compliant : :at_risk),
        :solvers => (blend = :HiGHS, operating_point = :Ipopt, sourcing = :HiGHS))
end





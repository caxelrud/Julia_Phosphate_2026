# =============================================================================
# reconcile.jl -- making the measurements consistent, estimating what was not
# measured, and keeping the twin honest.
#
# Three jobs live here, in the order a plant engineer does them:
#
# 1. `reconcile_measurements` -- the flows of a period are adjusted by weighted
#    least squares so that the stoichiometric balances close, with the gross errors
#    of the instruments caught by the chi-square global test;
# 2. `filter_states` -- a Kalman filter on the linearised twin turns the noisy
#    measurements of the historian into an estimate of the states of the plant,
#    which is what a soft sensor and a controller both need;
# 3. `align_twin` -- the steady state of the twin against the campaign it is meant
#    to describe, with the residuals it has to absorb as a bias.
# =============================================================================

"""Critical value of the chi-square distribution at 95 % for one to twenty degrees of freedom."""
const CHI2_95 = (3.841, 5.991, 7.815, 9.488, 11.070, 12.592, 14.067, 15.507, 16.919,
    18.307, 19.675, 21.026, 22.362, 23.685, 24.996, 26.296, 27.587, 28.869, 30.144, 31.410)

"""
    chi_square_critical(dof; alpha = 0.05) -> Float64

Critical value of the chi-square distribution for the global test. The table covers
one to twenty degrees of freedom at 95 % (standard statistical tables); beyond that
the Wilson-Hilferty approximation is used, which is exact enough for a test.
"""
function chi_square_critical(dof::Integer; alpha::Real = 0.05)
    alpha == 0.05 && 1 <= dof <= length(CHI2_95) && return CHI2_95[dof]
    ## Wilson-Hilferty: chi2_alpha ~ dof (1 - 2/(9 dof) + z sqrt(2/(9 dof)))^3
    z = alpha == 0.05 ? 1.6449 : alpha == 0.01 ? 2.3263 : 1.2816
    return dof * (1.0 - 2.0 / (9.0 * dof) + z * sqrt(2.0 / (9.0 * dof)))^3
end

"""Mean of a flow over the operating intervals (the reconciled rate of the period)."""
masked_mean_or_sum(c::Campaign, tag::Symbol, m) =
    SIGNAL_TAGS[tag].kind === :flow ? masked_sum(c, tag, m) / max(count(m), 1) :
    masked_mean(c, tag, m)

"""
    reconcile_measurements(campaign; tags, sigma) -> Dict{Symbol,Any}

Steady-state data reconciliation of the flows of a campaign. The measured rates are
adjusted as little as possible (in units of their own standard deviation) while the
stoichiometric balances of the reaction section hold exactly:

| Balance | Relation |
|---|---|
| gypsum | `gypsum = 4.042 x P2O5 + 3.070 x free CaO` |
| acid | `H2SO4 = 2.303 x P2O5 x (1 + excess)` |
| sulphur | `S = H2SO4 / (3.06 x conversion)` |
| ammonia | `NH3 = 0.480 x P2O5` on the DAP basis |
| product | `DAP = 0.76 x 0.65 x P2O5 / 0.4605` |

The weighted least squares problem is the quadratic program
`min sum(((x - m)/sigma)^2)` subject to `A x = b`, solved with Ipopt. The result
carries the measured value, the reconciled value, the adjustment in standard
deviations and the global test `sum(((x-m)/sigma)^2)` against the chi-square
critical value, which is how a gross error of an instrument is caught.
"""
function reconcile_measurements(c::Campaign; kpi = nothing,
    tags::Vector{Symbol} = [:P2O5_FEED_RATE, :H2SO4_FLOW, :SULPHUR_FEED, :GYPSUM_FLOW,
        :AMMONIA_FLOW, :PRODUCT_FLOW],
    sigma::Dict{Symbol,Float64} = Dict(:P2O5_FEED_RATE => 0.8, :H2SO4_FLOW => 3.0,
        :SULPHUR_FEED => 1.2, :GYPSUM_FLOW => 4.0, :AMMONIA_FLOW => 0.8,
        :PRODUCT_FLOW => 4.0))
    m = mode_mask(c)
    measured = Dict{Symbol,Float64}(t => masked_mean_or_sum(c, t, m) for t in tags)
    p2o5 = measured[:P2O5_FEED_RATE]
    d = c.design
    assay = upgraded_assay(ore_body(d.ore_body), masked_mean(c, :ROCK_P2O5, m) / 100.0)
    free_cao_rate = free_cao(assay, 1.0) * p2o5 / max(assay[:p2o5], 1.0e-9)
    acid_rate = STOICH.acid * p2o5 * (1.0 + d.acid_excess)
    ammonia_rate = (d.product === :map ? AMMONIA_PER_P2O5_MAP : AMMONIA_PER_P2O5_DAP) *
                   0.76 * p2o5
    b = Float64[STOICH.gypsum * p2o5 + GYPSUM_PER_FREE_CAO * free_cao_rate, acid_rate,
        acid_rate / 3.06 / d.acid_plant_conversion, ammonia_rate, 0.76 * p2o5 / 0.4605]
    n = length(tags)
    A = zeros(5, n)
    idx(t) = findfirst(==(t), tags)
    A[1, idx(:P2O5_FEED_RATE)] = -STOICH.gypsum; A[1, idx(:GYPSUM_FLOW)] = 1.0
    A[2, idx(:P2O5_FEED_RATE)] = -STOICH.acid * (1.0 + d.acid_excess); A[2, idx(:H2SO4_FLOW)] = 1.0
    A[3, idx(:H2SO4_FLOW)] = -1.0 / 3.06 / d.acid_plant_conversion; A[3, idx(:SULPHUR_FEED)] = 1.0
    A[4, idx(:P2O5_FEED_RATE)] = -(d.product === :map ? AMMONIA_PER_P2O5_MAP :
                                   AMMONIA_PER_P2O5_DAP) * 0.76
    A[4, idx(:AMMONIA_FLOW)] = 1.0
    A[5, idx(:P2O5_FEED_RATE)] = -0.76 / 0.4605; A[5, idx(:PRODUCT_FLOW)] = 1.0
    model = _model(Ipopt.Optimizer)
    x = JuMP.@variable(model, x[i = 1:n] >= 0.0, start = measured[tags[i]])


    JuMP.@objective(model, Min, sum(((x[i] - measured[tags[i]]) / sigma[tags[i]])^2 for i in 1:n))
    JuMP.@constraint(model, A * x .== b)
    JuMP.optimize!(model)
    ok = solve_status(model) === :compliant
    reconciled = Dict{Symbol,Float64}(tags[i] => (ok ? JuMP.value(x[i]) : measured[tags[i]])
                                      for i in 1:n)
    statistic = sum(((reconciled[t] - measured[t]) / sigma[t])^2 for t in tags)
    critical = chi_square_critical(length(b))
    rows = [Dict{Symbol,Any}(:tag => t, :measured => measured[t], :reconciled => reconciled[t],
            :adjustment => reconciled[t] - measured[t],
            :adjustment_sigma => (reconciled[t] - measured[t]) / sigma[t],
            :unit => SIGNAL_TAGS[t].unit,
            :gross_error => abs((reconciled[t] - measured[t]) / sigma[t]) > 3.0) for t in tags]
    return Dict{Symbol,Any}(:rows => rows, :measured => measured, :reconciled => reconciled,
        :statistic => statistic, :critical => critical, :dof => length(b),
        :balance_pass => statistic <= critical, :solver => :Ipopt, :variables => n,
        :status => !ok ? :noncompliant : statistic <= critical ? :compliant : :at_risk,
        :summary => Dict{Symbol,Any}(:variables => n, :dof => length(b),
            :chi_square => statistic, :chi_square_critical => critical,
            :balance_pass => statistic <= critical,
            :norm => sqrt(sum(abs2, [measured[t] - reconciled[t] for t in tags])),
            :solver => :Ipopt,
            :status => !ok ? :noncompliant : statistic <= critical ? :compliant : :at_risk),
        :basis => "weighted least squares reconciliation with the stoichiometric balances")
end

"""
    TWIN_TO_TAG

The bridge between the vocabulary of the twin and the instrument register: which
historian tag carries every input and every output of the dynamic model. This is
the table that lets the historian drive the twin, and the twin be compared with the
plant.
"""
const TWIN_TO_TAG = Dict{Symbol,Symbol}(
    :temperature => :ATTACK_TEMP, :acid_strength => :STRONG_ACID_P2O5, :free_so4 => :FREE_SO4,
    :p80 => :CYCLONE_P80, :product_rate => :PRODUCT_FLOW, :filter_rate => :FILTER_RATE,
    :bed_moisture => :PRODUCT_MOISTURE, :acid_strength_weak => :WEAK_ACID_P2O5,
    :acid_flow => :H2SO4_FLOW, :wash_water => :WASH_WATER_FLOW, :steam_flow => :STEAM_FLOW,
    :ammonia_flow => :AMMONIA_FLOW, :mill_feed => :ROM_FEED, :rock_feed => :ROCK_FEED,
    :rock_grade => :ROCK_P2O5, :mill_water => :MILL_FEED_WATER, :fouling => :STACK_F,
)

"""
    kalman_filter(design, linear; process_noise, measurement_noise) -> NamedTuple

A discrete Kalman filter on the linearised twin. The model is in deviation
variables around the operating point of the linearisation, so the filter works on
`dy = y - y_operating_point` and returns `dx`, which is added back to the operating
point to give the estimated state of the plant.
"""
function kalman_filter(d::PlantDesign, linear::Dict{Symbol,Any};
    process_noise::Real = 1.0e-3, measurement_noise::Real = 1.0e-2)
    ## the filter runs on the stable subspace of the linearised twin: the covariance of an
    ## unstable mode grows without bound and makes the innovation matrix singular
    red = linear[:reduced]
    n = size(red.Ar, 1)
    m = size(red.Cr, 1)
    xop = linear[:operating_point].x
    uop = linear[:operating_point].u
    pop = linear[:operating_point].p
    names_p = collect(keys(dynamic_parameters(d)))
    xop_dict = Dict(DYNAMIC_STATES[i] => xop[i] for i in eachindex(DYNAMIC_STATES))
    uop_dict = Dict(linear[:inputs][i] => uop[i] for i in eachindex(linear[:inputs]))
    pop_dict = Dict(names_p[i] => pop[i] for i in eachindex(names_p))
    full_u = merge(dynamic_inputs(d), uop_dict)
    yop = [dynamic_outputs(d, xop_dict, full_u, pop_dict)[o] for o in linear[:outputs]]
    return (; Ad = red.Ar, Bd = red.Br, Cd = red.Cr, Dd = red.Dr, V = red.V,
        dropped = red.dropped, full_states = length(DYNAMIC_STATES),
        Q = Matrix{Float64}(I, n, n) * Float64(process_noise),
        R = Matrix{Float64}(I, m, m) * Float64(measurement_noise),
        P = Matrix{Float64}(I, n, n), x = zeros(n), xop = xop, yop = yop, uop = uop,
        outputs = linear[:outputs], inputs = linear[:inputs], Ts = linear[:Ts])
end

"""
    filter_states(design, campaign, linear; from, to, process_noise, measurement_noise)
        -> Dict{Symbol,Any}

Run the Kalman filter of the twin over a window of the historian: at every interval
the filter predicts with the inputs the plant recorded and corrects itself with the
measurements the instruments reported. The result is an estimate of the eleven states
of the twin -- including the ones nobody measures, such as the fouling or the holdup
of the mills -- with the innovation of every measurement, which is what a soft
sensor is built on.
"""
function filter_states(d::PlantDesign, c::Campaign, linear::Dict{Symbol,Any};
    from::Integer = 1, to::Integer = 0, process_noise::Real = 1.0e-3,
    measurement_noise::Real = 1.0e-2)
    kf = kalman_filter(d, linear; process_noise = process_noise,
        measurement_noise = measurement_noise)

    n = length(c.schedule[:mode])
    last_hour = to <= 0 ? n : min(to, n)
    tags_u = [get(TWIN_TO_TAG, i, :none) for i in kf.inputs]
    tags_y = [get(TWIN_TO_TAG, o, :none) for o in kf.outputs]
    rows = Vector{Dict{Symbol,Any}}()
    x = copy(kf.x)
    P = copy(kf.P)
    for k in max(1, from):last_hour
        ## the inputs the plant recorded, as deviations from the operating point
        du = zeros(length(kf.inputs))
        for (i, t) in enumerate(tags_u)
            t === :none && continue
            s = c.book[t]
            du[i] = (isfinite(s.values[k]) ? s.values[k] : kf.uop[i]) - kf.uop[i]
        end
        ## predict
        x = kf.Ad * x + kf.Bd * du
        P = kf.Ad * P * kf.Ad' + kf.Q
        ## correct with what the instruments reported
        dy = zeros(length(kf.outputs))
        for (i, t) in enumerate(tags_y)
            t === :none && continue
            s = c.book[t]
            value = s.qualities[k] in OK_QUALITY && isfinite(s.values[k]) ? s.values[k] : kf.yop[i]
            dy[i] = value - kf.yop[i]
        end
        yhat = kf.Cd * x + kf.Dd * du
        innovation = dy - yhat
        S = kf.Cd * P * kf.Cd' + kf.R
        K = P * kf.Cd' / S
        x = x + K * innovation
        P = (I - K * kf.Cd) * P
        row = Dict{Symbol,Any}(:hour => k, :stamp => c.book[first(signal_tags())].stamps[k])
        full = kf.V * x
        for (i, s) in enumerate(DYNAMIC_STATES)
            row[Symbol(s, :_estimate)] = kf.xop[i] + full[i]
        end
        for (i, o) in enumerate(kf.outputs)
            row[Symbol(o, :_measured)] = dy[i] + kf.yop[i]
            row[Symbol(o, :_estimate)] = yhat[i] + kf.yop[i]
            row[Symbol(o, :_innovation)] = innovation[i]
        end
        push!(rows, row)
    end
    return Dict{Symbol,Any}(:rows => rows, :states => collect(DYNAMIC_STATES),
        :outputs => kf.outputs, :inputs => kf.inputs, :window => (max(1, from), last_hour),
        :rmse => _filter_rmse(rows, kf.outputs),
        :dropped_poles => kf.dropped, :reduced_states => length(kf.x),
        :status => isempty(rows) ? :not_assessed : (isempty(kf.dropped) ? :compliant : :at_risk),
        :basis => isempty(kf.dropped) ?
                  "Kalman filter on the linearised twin over the historian" :
                  "Kalman filter on the stable subspace of the linearised twin over the historian")
end

"""Root-mean-square innovation of every measured output of the filter."""
function _filter_rmse(rows::Vector{Dict{Symbol,Any}}, outputs::Vector{Symbol})
    out = Dict{Symbol,Any}()
    for o in outputs
        isempty(rows) && continue
        v = [r[Symbol(o, :_innovation)] for r in rows]
        out[o] = Dict{Symbol,Any}(:rmse => sqrt(sum(abs2, v) / length(v)),
            :bias => sum(v) / length(v), :n => length(v))
    end
    return out
end

"""
    operating_parameters(design, campaign) -> Dict{Symbol,Float64}

Parameters of the steady-state twin at the operating point the campaign *actually* ran
at: the ore rate and grade, the acid and the wash water the historian recorded. A twin
validated at its own design rates is not being validated, it is being compared with a
different plant; a twin validated at equal inputs separates a wrong model from a year
that simply ran at another load.
"""
function operating_parameters(d::PlantDesign = default_design(),
    c::Campaign = generate_campaign(d))
    m = mode_mask(c)
    hours = max(count(m), 1)
    values = steady_state_parameters(d)
    measured = Dict{Symbol,Float64}(
        :rock_feed => masked_sum(c, :ROCK_FEED, m) / hours,
        :rock_grade => masked_mean(c, :ROCK_P2O5, m) / 100.0,
        :acid_flow => masked_sum(c, :H2SO4_FLOW, m) / hours,
        :wash_water => masked_sum(c, :WASH_WATER_FLOW, m) / hours,
    )
    for (k, v) in measured
        (isfinite(v) && v > 0.0) && (values[k] = v)
    end
    values[:free_cao_rate] = free_cao(ore_body(d.ore_body), values[:rock_feed])
    return values
end

"""
    align_twin(design, campaign, kpi) -> Dict{Symbol,Any}

Compare the steady state of the twin with the campaign it is meant to describe: one
row per variable, with the value of the twin, the value the plant measured, the
residual in per cent, the bias the twin would have to absorb and the verdict of the
comparison.

A twin is only useful when this table is short. The bias column is what a real
commissioning does -- it absorbs the systematic differences (a grade the analyser
reads differently, a heat loss nobody modelled) and keeps the physics of the twin.
"""
function align_twin(d::PlantDesign = default_design(), c::Campaign = generate_campaign(d);
    kpi = nothing, parameters::Dict{Symbol,Float64} = operating_parameters(d, c))
    ss = solve_steady_state(d; parameters = parameters)[:solution]
    m = mode_mask(c)
    hours = max(count(m), 1)
    ##                      twin unknown,        plant measurement,        unit, tolerance %
    ## the tolerances are the screening agreement a grey-box twin has to hold to be used
    ## for decisions: the historian is seeded with the faults the detectors have to find,
    ## so a perfect match is not the expectation
    pairs = [
        (:p2o5_fed, masked_sum(c, :P2O5_FEED_RATE, m) / hours, :t_ph, 10.0),
        (:gypsum, masked_sum(c, :GYPSUM_FLOW, m) / hours, :t_ph, 12.0),
        (:steam, masked_sum(c, :STEAM_FLOW, m) / hours, :t_ph, 25.0),
        (:ammonia, masked_sum(c, :AMMONIA_FLOW, m) / hours, :t_ph, 25.0),
        (:product, masked_sum(c, :PRODUCT_FLOW, m) / hours, :t_ph, 25.0),
        (:merchant_p2o5, masked_sum(c, :MERCHANT_ACID_FLOW, m) / hours *
                         masked_mean(c, :STRONG_ACID_P2O5, m) / 100.0, :t_ph, 20.0),
        (:temperature, masked_mean(c, :ATTACK_TEMP, m), :deg_c, 5.0),
        (:free_so4, masked_mean(c, :FREE_SO4, m), :wt_pct, 15.0),
        (:acid_strength_weak, masked_mean(c, :WEAK_ACID_P2O5, m), :wt_pct, 8.0),
    ]

    rows = Vector{Dict{Symbol,Any}}()
    for (name, measured, unit, tolerance) in pairs
        haskey(ss, name) || continue
        twin_value = ss[name]
        residual = measured == 0 ? NaN : 100.0 * (twin_value - measured) / measured
        push!(rows, Dict{Symbol,Any}(:variable => name, :twin => twin_value,
            :measured => measured, :unit => unit, :residual_pct => residual,
            :tolerance_pct => tolerance,
            :bias => measured == 0 ? NaN : measured / twin_value, :bias_percent => 0.0,
            :status => !isfinite(residual) ? :not_assessed :
                       abs(residual) <= tolerance ? :compliant :
                       abs(residual) <= 2.0 * tolerance ? :at_risk : :noncompliant))
    end
    residuals = [abs(r[:residual_pct]) for r in rows if isfinite(r[:residual_pct])]
    score = isempty(residuals) ? 0.0 : clamp(100.0 - sum(residuals) / length(residuals), 0.0, 100.0)
    return Dict{Symbol,Any}(:rows => rows, :twin => ss, :parameters => parameters,
        :validity_score => score,
        :status => score >= 95.0 ? :compliant : score >= 85.0 ? :at_risk : :noncompliant,
        :basis => "steady state of the twin against the operating averages of the campaign")
end

"""Apply a bias vector of an alignment to the parameters of the twin (commissioning)."""
function apply_bias(parameters::Dict{Symbol,Float64}, alignment::Dict{Symbol,Any})
    out = copy(parameters)
    for r in alignment[:rows]
        r[:variable] === :p2o5_fed && isfinite(r[:bias]) &&
            (out[:acid_flow] = out[:acid_flow] * r[:bias])
        r[:variable] === :temperature && isfinite(r[:measured]) &&
            (out[:temperature_design] = r[:measured])
        r[:variable] === :acid_strength_weak && isfinite(r[:measured]) &&
            (out[:merchant_grade] = out[:merchant_grade] * 100.0 / r[:measured] * 0.52)
    end
    return out
end

"""
    reconciliation_report(design, campaign, kpi, linear) -> Dict{Symbol,Any}

The three jobs of this file in one bundle: the reconciled flows, the state
estimation of the window of the historian and the alignment of the twin, plus the
status that summarises them.
"""
function reconciliation_report(d::PlantDesign = default_design(),
    c::Campaign = generate_campaign(d), kpi = nothing,
    linear::Dict{Symbol,Any} = linearize_twin(d))
    reconciliation = reconcile_measurements(c)
    estimation = filter_states(d, c, linear; from = 1, to = 336)
    alignment = align_twin(d, c; kpi = kpi)
    return Dict{Symbol,Any}(:reconciliation => reconciliation, :estimation => estimation,
        :alignment => alignment, :rows => reconciliation[:rows],
        :estimation_rows => estimation[:rows], :alignment_rows => alignment[:rows],
        :status => reconciliation[:status] === :compliant &&
                  alignment[:status] === :compliant ? :compliant : :at_risk,
        :summary => Dict{Symbol,Any}(:chi_square => reconciliation[:statistic],
            :chi_square_critical => reconciliation[:critical],
            :gross_errors => count(r -> r[:gross_error], reconciliation[:rows]),
            :twin_validity => alignment[:validity_score],
            :filter_rmse => estimation[:rmse]))
end




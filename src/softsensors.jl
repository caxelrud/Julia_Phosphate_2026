# =============================================================================
# softsensors.jl -- inferential sensors: the instruments the plant does not have.
#
# A soft sensor is a model that turns what *is* measured into what is not: the
# strength of the merchant acid from its density and temperature, the free P2O5 of
# the cake from the wash ratio and the filter rate, the grind from the power of the
# mill, the grade of the concentrate from a photograph of the froth and the load of
# the mill from the sound it makes.
#
# Every sensor of this file is the same object: a linear model of the inputs with
# its own validation numbers, its own applicability range and its own health. The
# validation numbers are what makes it usable in a report: a soft sensor without an
# `R2` and an `RMSE` is an opinion.
# =============================================================================

"""
    SoftSensor

One inferential sensor: the `target` it infers, the `unit` it reports, the
`kind` of measurement it uses (see [`SENSOR_KINDS`](@ref)), the `inputs` it needs,
the linear model it was fitted with, and the numbers that say whether it may be
used at all:

* `r2` and `rmse` -- validation quality on a holdout that was never used to fit it
* `bias` -- the systematic error of the validation set
* `range` -- the applicability domain of every input: outside it the sensor reports
  `:degraded` instead of a number, which is the whole point of a soft sensor
"""
struct SoftSensor
    id::Symbol
    target::Symbol
    unit::Symbol
    kind::Symbol
    inputs::Vector{Symbol}
    coefs::Vector{Float64}
    intercept::Float64
    r2::Float64
    rmse::Float64
    bias::Float64
    range::Dict{Symbol,Tuple{Float64,Float64}}
    trained_on::Int
    meta::Dict{Symbol,Any}
end

"""Value a soft sensor predicts for one input vector."""
predict(s::SoftSensor, x::AbstractVector{<:Real}) = s.intercept + dot(s.coefs, x)

"""`true` when an input vector is inside the domain the sensor was validated on."""
function in_domain(s::SoftSensor, x::AbstractVector{<:Real})
    for (i, name) in enumerate(s.inputs)
        lo, hi = get(s.range, name, (-Inf, Inf))
        lo <= x[i] <= hi || return false
    end
    return true
end

"""Status of a prediction: usable, extrapolated or unavailable."""
sensor_status(s::SoftSensor, x::AbstractVector{<:Real}) = in_domain(s, x) ? :healthy : :degraded

"""
    fit_linear(X, y; names) -> (; coefs, intercept, r2, rmse)

Ordinary least squares of a target on a matrix of inputs, with the intercept, the
coefficient of determination and the residual error. The system is solved with a QR
factorisation (no normal equations, so the conditioning of the inputs does not
square).
"""
function fit_linear(X::AbstractMatrix{<:Real}, y::AbstractVector{<:Real})
    n, p = size(X)
    A = [ones(n) X]
    F = qr(A)
    coefs = F \ collect(Float64, y)
    yhat = A * coefs
    resid = collect(Float64, y) - yhat
    sst = sum(abs2, collect(Float64, y) .- sum(y) / n)
    r2 = sst == 0 ? 0.0 : 1.0 - sum(abs2, resid) / sst
    rmse = sqrt(sum(abs2, resid) / n)
    return (; intercept = coefs[1], coefs = coefs[2:end], r2 = r2, rmse = rmse,
        residuals = resid)
end

"""
    design_matrix(campaign, inputs, target, hours) -> (X, y, index)

The regression data of a soft sensor: one row per usable interval of the historian,
with the inputs as columns and the target as the response. An interval with a
missing or faulty reading of any input or of the target is left out of the fit
rather than filled, which is the only honest way to fit a sensor on a historian
that has gaps.
"""
function design_matrix(c::Campaign, inputs::Vector{Symbol}, target::Symbol,
    hours::AbstractVector{<:Integer})
    rows = Int[]
    for k in hours
        keep = c.book[target].qualities[k] in OK_QUALITY && isfinite(c.book[target].values[k])
        keep && for t in inputs
            keep &= c.book[t].qualities[k] in OK_QUALITY && isfinite(c.book[t].values[k])
            keep || break
        end
        keep && push!(rows, k)
    end
    X = zeros(length(rows), length(inputs))
    y = zeros(length(rows))
    for (r, k) in enumerate(rows)
        for (j, t) in enumerate(inputs)
            X[r, j] = c.book[t].values[k]
        end
        y[r] = c.book[target].values[k]
    end
    return X, y, rows
end

"""
    train_soft_sensor(campaign, target, inputs; kind, holdout, seed, hours)
        -> SoftSensor

Fit an inferential sensor on the historian and validate it on a holdout that was
never used in the fit: the fit reports `R2`, `RMSE` and `bias` of the holdout, and
the applicability range of every input, which is what the sensor uses to refuse to
answer outside the conditions it knows.
"""
function train_soft_sensor(c::Campaign, target::Symbol, inputs::Vector{Symbol};
    kind::Symbol = :process, holdout::Real = 0.4, seed::Integer = 20260101,
    hours::Union{Nothing,AbstractVector{<:Integer}} = nothing, unit::Symbol = :count,
    note::AbstractString = "")
    hs = hours === nothing ? findall(mode_mask(c)) : collect(hours)
    X, y, rows = design_matrix(c, inputs, target, hs)
    size(X, 1) >= 20 || throw(ArgumentError(string("not enough usable intervals to train ",
        code_string(target), " (", size(X, 1), " rows)")))
    rng = MersenneTwister(seed)
    order = randperm(rng, size(X, 1))
    ntest = max(5, round(Int, holdout * size(X, 1)))
    test = order[1:ntest]
    train = order[(ntest + 1):end]
    fit = fit_linear(X[train, :], y[train])
    pred = fit.intercept .+ X[test, :] * fit.coefs
    resid = y[test] - pred
    sst = sum(abs2, y[test] .- sum(y[test]) / length(test))
    r2 = sst == 0 ? 0.0 : 1.0 - sum(abs2, resid) / sst
    range = Dict{Symbol,Tuple{Float64,Float64}}(inputs[j] =>
        (minimum(X[:, j]), maximum(X[:, j])) for j in eachindex(inputs))
    return SoftSensor(Symbol(kind, :_, target), target, unit, kind, inputs, fit.coefs,
        fit.intercept, r2, sqrt(sum(abs2, resid) / length(resid)), sum(resid) / length(resid),
        range, size(X, 1), Dict{Symbol,Any}(:note => note, :seed => seed,
            :holdout_pct => 100.0 * holdout, :rows => length(rows), :fit => fit))
end

"""Predictions of a soft sensor over a set of intervals of the historian."""
function predict_series(s::SoftSensor, c::Campaign; hours::Union{Nothing,AbstractVector{<:Integer}} = nothing)
    hs = hours === nothing ? findall(mode_mask(c)) : collect(hours)
    stamps = c.book[first(s.inputs)].stamps
    reads_historian(s) ||
        return Series(Symbol(s.id, :_soft), :hourly, s.unit, DateTime[], Float64[], Symbol[],
            Dict{Symbol,Any}())
    out = Float64[]
    idx = Int[]
    flags = Symbol[]
    for k in hs
        x = [c.book[t].values[k] for t in s.inputs]
        any(v -> !isfinite(v), x) && continue
        push!(out, predict(s, x))
        push!(idx, k)
        push!(flags, sensor_status(s, x))
    end
    return Series(Symbol(s.id, :_soft), :hourly, s.unit, stamps[idx], out, flags, Dict{Symbol,Any}())
end

"""
    reads_historian(sensor) -> Bool

`true` when every input of a sensor is an instrument tag of the register. A process
sensor reads the historian; a visual or acoustic sensor reads features rendered from
the plant, so the tables and figures that walk the historian skip it.
"""
reads_historian(s::SoftSensor) = all(i -> haskey(SIGNAL_TAGS, i), s.inputs)

"""
    sensor_parity_rows(sensors, campaign; hours) -> Vector{Dict{Symbol,Any}}

Measured against predicted, hour by hour, for the parity figures of the report.
"""
function sensor_parity_rows(sensors::Vector{SoftSensor}, c::Campaign; hours::Integer = 48)
    m = findall(mode_mask(c))
    window = m[max(1, length(m) - hours + 1):end]
    rows = Vector{Dict{Symbol,Any}}()
    for s in sensors
        reads_historian(s) || continue
        for k in window
            x = [c.book[t].values[k] for t in s.inputs]
            any(v -> !isfinite(v), x) && continue
            y = c.book[s.target].values[k]
            isfinite(y) || continue
            push!(rows, Dict{Symbol,Any}(:sensor => s.id, :hour => k, :unit => s.unit,
                :measured => y, :predicted => predict(s, x)))
        end
    end
    return rows
end

"""Elasticity of every input of a sensor at the mean operating point, for the report."""
function sensor_elasticity(s::SoftSensor, c::Campaign)
    reads_historian(s) ||
        return Dict{Symbol,Any}(i => NaN for i in s.inputs)
    values = [masked_mean(c, t, mode_mask(c)) for t in s.inputs]
    yhat = predict(s, values)
    return Dict{Symbol,Any}(t => (yhat == 0 ? NaN : 100.0 * s.coefs[i] * values[i] / yhat)
                            for (i, t) in enumerate(s.inputs))
end

"""Health of a sensor over the campaign: the share of hours it can answer, and its drift."""
function sensor_health(s::SoftSensor, c::Campaign)
    tags = [i for i in s.inputs if haskey(SIGNAL_TAGS, i)]
    if length(tags) != length(s.inputs)
        ## a visual or acoustic sensor reads features rendered from the plant rather than
        ## historian tags, so its health is the validation score of the sensor itself
        return Dict{Symbol,Any}(:sensor => s.id, :hours => s.trained_on,
            :in_domain_pct => NaN, :residual_mean => 0.0, :residual_rmse => s.rmse,
            :status => s.r2 >= 0.75 ? :healthy : :degraded)
    end
    hs = findall(mode_mask(c))
    in_domain_hours = 0
    usable = 0
    resid = Float64[]
    for k in hs
        x = [c.book[t].values[k] for t in s.inputs]
        any(v -> !isfinite(v), x) && continue
        usable += 1
        in_domain(s, x) && (in_domain_hours += 1)
        target = c.book[s.target].values[k]
        isfinite(target) && push!(resid, target - predict(s, x))
    end
    drift = isempty(resid) ? NaN : sum(resid) / length(resid)
    return Dict{Symbol,Any}(:sensor => s.id, :hours => usable,
        :in_domain_pct => usable == 0 ? 0.0 : 100.0 * in_domain_hours / usable,
        :residual_mean => drift, :residual_rmse => isempty(resid) ? NaN :
                          sqrt(sum(abs2, resid) / length(resid)),
        :status => usable == 0 ? :offline : abs(drift) > 2.0 * s.rmse ? :degraded : :healthy)
end

"""
    PROCESS_SENSOR_SPECS

The process soft sensors of the plant, `(id, target, inputs, unit, note)`: every one
of them infers a variable that is measured slowly (in a laboratory), intermittently
or not at all, from instruments that report every hour.
"""
const PROCESS_SENSOR_SPECS = (
    (:merchant_acid_strength, :STRONG_ACID_P2O5, [:EVAP_TEMP, :STEAM_FLOW, :EVAP_VACUUM],
        :wt_pct, "the boiling point of the acid, the vacuum and the steam: the virtual analyser of the evaporator house"),
    (:weak_acid_strength, :WEAK_ACID_P2O5, [:SLURRY_SG, :ATTACK_TEMP, :FREE_SO4, :WASH_WATER_FLOW],
        :wt_pct, "the slurry specific gravity carries the strength of the filtrate"),
    (:cake_free_p2o5, :GYPSUM_FREE_P2O5, [:FILTER_RATE, :FILTER_VACUUM, :WASH_WATER_FLOW,
            :WEAK_ACID_P2O5],
        :wt_pct, "the water-soluble loss against the wash and the vacuum"),
    (:grind_size, :CYCLONE_P80, [:MILL_POWER, :SLURRY_DENSITY, :CYCLONE_PRESSURE,
            :MILL_FEED_WATER],
        :um, "the grind from the power of the mill and the cyclone"),
    (:mill_load, :MILL_POWER, [:ROM_FEED, :SLURRY_DENSITY, :MILL_FEED_WATER],
        :kw, "virtual redundancy of the mill power, for the fault detector"),
    (:product_nitrogen, :PRODUCT_N, [:AMMONIA_FLOW, :PRODUCT_FLOW, :MELT_DENSITY],
        :wt_pct, "the nitrogen of the bagged product between two laboratory samples"),
    (:filter_productivity, :FILTER_RATE, [:FILTER_VACUUM, :WEAK_ACID_P2O5, :SLURRY_SG,
            :GYPSUM_FREE_P2O5],
        :t_per_m2_d, "the rate of the filter from the vacuum and the slurry"),
    (:flotation_grade, :CONC_P2O5, [:FLOT_FEED_P2O5, :CYCLONE_P80, :REAGENT_FLOW],
        :wt_pct, "the two-product formula as a virtual analyser of the concentrate"),
    (:reactor_temperature, :ATTACK_TEMP, [:H2SO4_FLOW, :ROCK_FEED, :RECYCLE_ACID_FLOW,
            :SLURRY_SG],
        :deg_c, "the heat of the attack against the flows that carry it away"),
    (:evaporator_load, :STEAM_FLOW, [:EVAP_FEED_FLOW, :STRONG_ACID_P2O5, :EVAP_VACUUM],
        :t_ph, "the steam the evaporator should need for the acid it is making"),
)

"""
    train_process_sensors(campaign; specs, seed) -> Vector{SoftSensor}

Train every process soft sensor of the catalogue on a campaign, in one call.
"""
function train_process_sensors(c::Campaign; specs = PROCESS_SENSOR_SPECS,
    seed::Integer = 20260101)
    sensors = SoftSensor[]
    for (id, target, inputs, unit, note) in specs
        haskey(c.book, target) || continue
        all(t -> haskey(c.book, t), inputs) || continue
        push!(sensors, train_soft_sensor(c, target, inputs; kind = :process, unit = unit,
            seed = seed, note = note))
    end
    return sensors
end

"""Row per sensor for the register table of the report."""
function sensor_table(sensors::Vector{SoftSensor}, c::Campaign)
    rows = Vector{Dict{Symbol,Any}}()
    for s in sensors
        health = sensor_health(s, c)
        push!(rows, Dict{Symbol,Any}(:sensor => s.id, :target => s.target, :kind => s.kind,
            :unit => s.unit, :inputs => join(string.(s.inputs), ", "), :r2 => s.r2,
            :rmse => s.rmse, :bias => s.bias, :rows => s.trained_on,
            :in_domain_pct => health[:in_domain_pct], :drift => health[:residual_mean],
            :status => health[:status], :note => s.meta[:note]))
    end
    sort!(rows; by = r -> -r[:r2])
    return rows
end

"""
    sensor_estimate_table(sensors, campaign; hours) -> Vector{Dict{Symbol,Any}}

The estimates of every sensor against the value the plant measured over the last
`hours` intervals: the table an operator actually looks at, because it answers the
question "what does the sensor say, against what the laboratory says".
"""
function sensor_estimate_table(sensors::Vector{SoftSensor}, c::Campaign; hours::Integer = 24)
    m = findall(mode_mask(c))
    window = m[max(1, length(m) - hours + 1):end]
    rows = Vector{Dict{Symbol,Any}}()
    for s in sensors
        reads_historian(s) || continue
        preds = Float64[]
        measured = Float64[]
        for k in window
            x = [c.book[t].values[k] for t in s.inputs]
            any(v -> !isfinite(v), x) && continue
            push!(preds, predict(s, x))
            y = c.book[s.target].values[k]
            isfinite(y) && push!(measured, y)
        end
        isempty(preds) && continue
        p = sum(preds) / length(preds)
        mm = isempty(measured) ? NaN : sum(measured) / length(measured)
        push!(rows, Dict{Symbol,Any}(:sensor => s.id, :target => s.target, :unit => s.unit,
            :estimate => p, :measured => mm, :difference => p - mm,
            :difference_pct => isfinite(mm) && mm != 0 ? 100.0 * (p - mm) / mm : NaN,
            :rmse => s.rmse,
            :status => !isfinite(mm) ? :not_assessed :
                      abs(p - mm) <= 2.0 * s.rmse ? :compliant : :at_risk))
    end
    return rows
end

"""
    soft_sensor_report(campaign; sensors, seed) -> Dict{Symbol,Any}

The soft-sensing bundle of a campaign: the sensors (the process ones trained here,
plus any vision or acoustic sensor the caller passes in), their register, the
estimates of the last day against what the plant measured, the health of every
sensor and the elasticity of its inputs.
"""
function soft_sensor_report(c::Campaign; sensors::Vector{SoftSensor} = SoftSensor[],
    seed::Integer = 20260101)
    ss = isempty(sensors) ? train_process_sensors(c; seed = seed) : sensors
    estimates = sensor_estimate_table(ss, c)
    return Dict{Symbol,Any}(:sensors => ss, :rows => sensor_table(ss, c),
        :estimates => estimates, :parity => sensor_parity_rows(ss, c),
        :health => [Dict{Symbol,Any}(:sensor => s.id, sensor_health(s, c)...) for s in ss],
        :elasticity => [Dict{Symbol,Any}(:sensor => s.id, :target => s.target,
                (k => v for (k, v) in sensor_elasticity(s, c))...) for s in ss],
        :summary => Dict{Symbol,Any}(:sensors => length(ss),
            :median_r2 => isempty(ss) ? NaN : median([s.r2 for s in ss]),
            :best => isempty(ss) ? nothing : first(sort(ss; by = s -> -s.r2)).id,
            :features => count(s -> s.kind !== :process, ss),
            :status => all(s -> s.r2 >= 0.80, ss) ? :compliant : :at_risk),
        :basis => "linear inferential models validated on a holdout of the campaign")
end




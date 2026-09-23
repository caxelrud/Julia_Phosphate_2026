# =============================================================================
# fdd.jl -- fault detection and diagnostics.
#
# Twenty rules watch the historian the way a plant engineer would: a value against
# its registered reference, a specific consumption against the stoichiometric
# expectation, a cross-signal balance (the two-product flotation balance, the
# nitrogen balance of the granulator) and a permit limit. A rule raises a
# `Finding` when the rolling mean of its metric stays outside its reference for a
# minimum number of intervals, and every finding carries the money at stake, so
# the list can be sorted by what it is worth acting on.
# =============================================================================

"""One diagnostic finding: the rule, the tag, the measured value and its impact."""
struct Finding
    id::Symbol
    rule::Symbol
    area::Symbol
    severity::Symbol
    tag::Symbol
    role::Symbol
    value::Float64
    reference::Float64
    unit::Symbol
    deviation_pct::Float64
    from::DateTime
    to::DateTime
    intervals::Int
    cost_at_stake::Float64
    note::String
end

"""Symbol-keyed row of a finding, for the tables and the JSON payloads."""
finding_row(f::Finding) = Dict{Symbol,Any}(:id => f.id, :rule => f.rule, :area => f.area,
    :severity => f.severity, :tag => f.tag, :role => f.role, :metric => f.value,
    :reference => f.reference, :unit => f.unit, :deviation_pct => f.deviation_pct,
    :from => f.from, :to => f.to, :intervals => f.intervals,
    :cost_at_stake => f.cost_at_stake, :note => f.note)

"""
    RULE_CATALOGUE

The rules of the detector: `rule => (title, area, severity, tag, role, comparator,
reference, unit, window_hours, minimum_hours, basis)`. The reference is the
registered operating value or limit of the metric, and `comparator` is the
direction the metric may not cross (`:le`, `:ge`, or `:within` for a deviation
from another signal).
"""
const RULE_CATALOGUE = Dict{Symbol,NamedTuple}(
    :reactor_temperature_high => (title = "Attack temperature above the window",
        area = :attack, severity = :warning, tag = :ATTACK_TEMP, role = :reactor_temperature,
        comparator = :le, reference = 83.0, unit = :deg_c, window_hours = 12, minimum_hours = 6,
        basis = "a dihydrate attack tank above 83 C loses the gypsum crystal form"),
    :sulfate_deficit => (title = "Free sulphate below the crystallisation window",
        area = :attack, severity = :critical, tag = :FREE_SO4, role = :sulfate_ratio,
        comparator = :ge, reference = 1.20, unit = :wt_pct, window_hours = 8, minimum_hours = 4,
        basis = "below 1.2 wt% free SO4 the slurry turns monocalcic and blinds the cloth"),
    :grind_coarse => (title = "Grind coarser than the liberation target",
        area = :beneficiation, severity = :warning, tag = :CYCLONE_P80, role = :grind_p80,
        comparator = :le, reference = 185.0, unit = :um, window_hours = 24, minimum_hours = 12,
        basis = "a coarse grind costs flotation recovery and raises the reagent demand"),
    :concentrate_grade_low => (title = "Concentrate grade below the attack specification",
        area = :flotation, severity = :critical, tag = :CONC_P2O5, role = :concentrate_grade,
        comparator = :ge, reference = 29.5, unit = :wt_pct, window_hours = 12, minimum_hours = 6,
        basis = "a lower grade drags the acidulation balance and the product with it"),
    :reagent_demand_high => (title = "Reagent dose above the registered value",
        area = :flotation, severity = :info, tag = :REAGENT_FLOW, role = :reagent_flow,
        comparator = :le, reference = 336.0, unit = :l_ph, window_hours = 24, minimum_hours = 12,
        basis = "the dose rises when the ore is oxidised or the grind is coarse"),
    :filter_rate_low => (title = "Filter productivity below the design rate",
        area = :filtration, severity = :warning, tag = :FILTER_RATE, role = :filtration_rate,
        comparator = :ge, reference = 4.00, unit = :t_per_m2_d, window_hours = 12,
        minimum_hours = 6, basis = "a blinded cloth or a monocalcic slurry shows up as rate"),
    :water_soluble_loss_high => (title = "Water-soluble P2O5 above the target",
        area = :filtration, severity = :warning, tag = :GYPSUM_FREE_P2O5,
        role = :gypsum_free_p2o5, comparator = :le, reference = 1.00, unit = :wt_pct,
        window_hours = 12, minimum_hours = 6,
        basis = "the wash ratio, the vacuum or the crystal size has moved"),
    :vacuum_low => (title = "Filter vacuum below the working range",
        area = :filtration, severity = :info, tag = :FILTER_VACUUM, role = :filter_vacuum,
        comparator = :ge, reference = 200.0, unit = :mmwc, window_hours = 6, minimum_hours = 3,
        basis = "vacuum loss is a compressor, a seal or a cloth problem"),
    :steam_excess => (title = "Evaporator steam above the duty",
        area = :evaporation, severity = :warning, tag = :STEAM_FLOW, role = :steam_flow,
        comparator = :le, reference = 110.0, unit = :t_ph, window_hours = 24, minimum_hours = 12,
        basis = "scale on the tubes costs steam long before it costs production"),
    :acid_strength_low => (title = "Merchant acid weaker than specification",
        area = :evaporation, severity = :critical, tag = :STRONG_ACID_P2O5,
        role = :acid_strength, comparator = :ge, reference = 50.50, unit = :wt_pct,
        window_hours = 12, minimum_hours = 6,
        basis = "52 % P2O5 is the merchant specification; weaker acid is discounted"),
    :stack_fluoride_high => (title = "Fluorine at the stack above the permit",
        area = :filtration, severity = :critical, tag = :STACK_F, role = :stack_fluoride,
        comparator = :le, reference = 5.00, unit = :count, window_hours = 6, minimum_hours = 3,
        basis = "the permit limit of the site; a breakthrough is a reportable event"),
    :stack_dust_high => (title = "Dust at the stack above the permit",
        area = :granulation, severity = :warning, tag = :STACK_DUST, role = :stack_dust,
        comparator = :le, reference = 30.0, unit = :count, window_hours = 6, minimum_hours = 3,
        basis = "the scrubber or the dryer cyclones have lost efficiency"),
    :scrubber_ph_low => (title = "Scrubber pH below the absorption window",
        area = :granulation, severity = :warning, tag = :SCRUBBER_PH, role = :scrubber_ph,
        comparator = :ge, reference = 5.60, unit = :count, window_hours = 6, minimum_hours = 3,
        basis = "the ammoniacal scrubber absorbs fluorine and dust only above pH 5.6"),
    :mill_power_excess => (title = "Mill power above the Bond expectation",
        area = :beneficiation, severity = :warning, tag = :MILL_POWER, role = :mill_load,
        comparator = :le, reference = 4600.0, unit = :kw, window_hours = 24, minimum_hours = 12,
        basis = "liner wear and a coarse feed both raise the specific grinding energy"),
    :pump_vibration_high => (title = "Vibration above the machinery limit",
        area = :utilities, severity = :warning, tag = :PUMP_VIBRATION, role = :pump_vibration,
        comparator = :le, reference = 6.00, unit = :count, window_hours = 6, minimum_hours = 3,
        basis = "cavitation and bearing wear are the two causes on this train"),
    :product_nitrogen_low => (title = "Product nitrogen below specification",
        area = :granulation, severity = :critical, tag = :PRODUCT_N, role = :product_n,
        comparator = :ge, reference = 17.40, unit = :wt_pct, window_hours = 12, minimum_hours = 6,
        basis = "DAP is sold at 18-46-0; nitrogen below 17.4 is off-specification"),
    :product_nitrogen_high => (title = "Product nitrogen above specification",
        area = :granulation, severity = :warning, tag = :PRODUCT_N, role = :product_n,
        comparator = :le, reference = 19.20, unit = :wt_pct, window_hours = 12, minimum_hours = 6,
        basis = "over-ammoniation wastes ammonia and softens the granule"),
    :oversize_high => (title = "Oversize above the recycle capability",
        area = :granulation, severity = :info, tag = :OVERSIZE_PCT, role = :oversize_pct,
        comparator = :le, reference = 16.0, unit = :pct, window_hours = 24, minimum_hours = 12,
        basis = "the oversize crusher gap and the recycle ratio set this number"),
    :slurry_density_high => (title = "Mill discharge heavier than the pump window",
        area = :beneficiation, severity = :warning, tag = :SLURRY_DENSITY,
        role = :slurry_density, comparator = :le, reference = 44.0, unit = :wt_pct,
        window_hours = 12, minimum_hours = 6,
        basis = "heavy slurry means cyclone roping and a coarse flotation feed"),
    :rock_grade_deviation => (title = "Rock grade inconsistent with the flotation result",
        area = :attack, severity = :info, tag = :ROCK_P2O5, role = :rock_grade,
        comparator = :within, reference = 1.20, unit = :wt_pct, window_hours = 24,
        minimum_hours = 12,
        basis = "an analyser drift shows as a gap between the rock and the concentrate"),
)

"""Rules of the catalogue, in a stable order."""
rule_ids() = sort(collect(keys(RULE_CATALOGUE)); by = String)

"""The deviation the detector expects to see for a role is injected as a bias."""
const ROLE_TO_FAULT = Dict{Symbol,Symbol}(
    :reactor_temperature => :cooling_fouling, :sulfate_ratio => :sulfate_deficit,
    :grind_p80 => :grind_coarse, :concentrate_grade => :reagent_starvation,
    :filtration_rate => :filter_cloth_blinding, :steam_flow => :evaporator_fouling,
    :acid_strength => :acid_strength_loss, :stack_fluoride => :scrubber_breakthrough,
    :mill_load => :mill_liner_wear, :pump_vibration => :pump_cavitation,
    :product_n => :sparger_blockage, :oversize_pct => :crusher_gap_drift,
    :rock_grade => :rock_grade_drift, :slurry_density => :cyclone_roping,
    :ammonia_flow => :ammonia_overfeed,
)

"""Rules whose metric is a cross-signal balance rather than a single tag."""
const BALANCE_RULES = (:flotation_mass_balance, :nitrogen_balance, :evaporator_economy)

"""Rule that the detector expects to fire for each injected fault."""
const RULE_TO_FAULT = Dict{Symbol,Symbol}(
    :reactor_temperature_high => :cooling_fouling, :sulfate_deficit => :sulfate_deficit,
    :grind_coarse => :grind_coarse, :concentrate_grade_low => :reagent_starvation,
    :filter_rate_low => :filter_cloth_blinding, :vacuum_low => :filter_cloth_blinding,
    :water_soluble_loss_high => :filter_cloth_blinding, :steam_excess => :evaporator_fouling,
    :acid_strength_low => :acid_strength_loss, :stack_fluoride_high => :scrubber_breakthrough,
    :mill_power_excess => :mill_liner_wear, :pump_vibration_high => :pump_cavitation,
    :product_nitrogen_low => :sparger_blockage, :product_nitrogen_high => :ammonia_overfeed,
    :oversize_high => :crusher_gap_drift, :rock_grade_deviation => :rock_grade_drift,
    :slurry_density_high => :cyclone_roping, :reagent_demand_high => :reagent_starvation,
    :stack_dust_high => :sparger_blockage, :scrubber_ph_low => :scrubber_breakthrough,
)

"""Rolling mean of a series over the last `w` intervals, ignoring unusable ones."""
function rolling_mean(v::Vector{Float64}, w::Integer)
    n = length(v)
    out = fill(NaN, n)
    w = max(1, w)
    for i in 1:n
        lo = max(1, i - w + 1)
        s = 0.0
        c = 0
        for j in lo:i
            x = v[j]
            if isfinite(x)
                s += x
                c += 1
            end
        end
        c >= max(1, w ÷ 4) && (out[i] = s / c)
    end
    return out
end

"""Metric each rule watches: a tag, or a cross-signal balance computed per interval."""
function rule_metric(c::Campaign, rule::Symbol)
    spec = RULE_CATALOGUE[rule]
    s = c.book[spec.tag]
    if rule === :flotation_mass_balance || (spec.comparator === :within && rule === :rock_grade_deviation)
        ## |rock grade - concentrate grade| is the analyser consistency check
        return abs.(c.book[:ROCK_P2O5].values .- c.book[:CONC_P2O5].values)
    elseif spec.comparator === :within
        return abs.(s.values .- c.book[:ROCK_P2O5].values)
    end
    return copy(s.values)
end

"""Per-interval value of the three balance rules, which combine several tags."""
function balance_metric(c::Campaign, rule::Symbol)
    n = length(c.schedule[:mode])
    if rule === :flotation_mass_balance
        mf, c1, t1 = c.book[:ROM_FEED].values, c.book[:CONC_P2O5].values,
        c.book[:TAIL_P2O5].values
        mc = c.book[:ROCK_FEED].values ./ 0.985
        out = fill(NaN, n)
        for i in 1:n
            mf[i] > 0 || continue
            ## concentrate/feed from the two-product balance against the measured ratio
            feed_grade = c.book[:FLOT_FEED_P2O5].values[i]
            balance_ratio = (feed_grade - t1[i]) / (c1[i] - t1[i])
            measured_ratio = mc[i] / mf[i]
            out[i] = 100.0 * 2.0 * abs(balance_ratio - measured_ratio) /
                     (balance_ratio + measured_ratio + 1.0e-9)
        end
        return out

    elseif rule === :nitrogen_balance
        nh3 = c.book[:AMMONIA_FLOW].values
        prod = c.book[:PRODUCT_FLOW].values
        measured = c.book[:PRODUCT_N].values
        out = fill(NaN, n)
        for i in 1:n
            prod[i] > 0 || continue
            predicted = 100.0 * nh3[i] * (14.006 / 17.031) / prod[i]
            out[i] = abs(predicted - measured[i])
        end
        return out
    end
    return fill(NaN, n)
end

"""
    fault_cost(rule, excess, kpi) -> Float64

Annualised money at stake for a rule, in the site currency, from the deviation
`excess` of its metric in the direction that hurts. The registered unit costs of
[`ECONOMICS`](@ref) turn every rule into money: lost P2O5 recovery is valued at the
merchant acid price, extra steam at the steam value, off-specification nitrogen at
the product penalty, and so on.
"""
function fault_cost(rule::Symbol, excess::Real, kpi)
    excess <= 0 && return 0.0
    hours = 8000.0
    p2o5_tph = kpi === nothing ? 150.0 : max(kpi[:attack][:p2o5_fed] / 8000.0, 1.0)
    product_tph = kpi === nothing ? 268.0 : max(kpi[:product][:tonnes] / 8000.0, 1.0)
    acid_price = ECONOMICS[:merchant_acid_per_t_p2o5]
    if rule === :reactor_temperature_high
        return 0.0025 * excess * p2o5_tph * hours * acid_price
    elseif rule === :sulfate_deficit
        return 0.0080 * excess * p2o5_tph * hours * acid_price
    elseif rule === :grind_coarse || rule === :slurry_density_high
        return 0.0015 * excess * p2o5_tph * hours * acid_price
    elseif rule === :concentrate_grade_low || rule === :rock_grade_deviation
        return excess * 0.01 * p2o5_tph * hours * acid_price
    elseif rule === :filter_rate_low
        ref = 5.40
        value = max(ref - excess, 0.0)
        return 0.35 * (1.0 - value / ref) * p2o5_tph * hours * acid_price
    elseif rule === :water_soluble_loss_high
        return excess * 0.01 * p2o5_tph * hours * acid_price
    elseif rule === :steam_excess
        return excess * hours * ECONOMICS[:steam_per_t] * 0.55
    elseif rule === :acid_strength_low
        return excess * product_tph * hours * 1.20
    elseif rule === :stack_fluoride_high
        return excess * hours * 240.0
    elseif rule === :stack_dust_high
        return excess * hours * 110.0
    elseif rule === :scrubber_ph_low
        return excess * hours * 180.0
    elseif rule === :mill_power_excess
        return excess * hours * ECONOMICS[:electricity_per_kwh]
    elseif rule === :pump_vibration_high
        return excess * 1250.0
    elseif rule === :product_nitrogen_low
        return excess * 0.01 * product_tph * hours * 8.00
    elseif rule === :product_nitrogen_high
        return excess * 0.01 * product_tph * hours * ECONOMICS[:ammonia_per_t] * 0.24
    elseif rule === :oversize_high
        return excess * 0.01 * product_tph * hours * 0.40 * ECONOMICS[:electricity_per_kwh]
    elseif rule === :vacuum_low
        return excess * hours * 0.6
    elseif rule === :reagent_demand_high
        return excess * hours * ECONOMICS[:reagent_per_t] / 1000.0 * 0.05
    end
    return 0.0
end

"""
    detect_rule(campaign, rule; kpi) -> Vector{Finding}

Apply one rule: take the rolling mean of its metric over the rule's window, find
the runs where it stays outside the reference for at least the rule's minimum
number of intervals, and turn every run into a [`Finding`](@ref) that carries the
observed value, the window and the money at stake.
"""
function detect_rule(c::Campaign, rule::Symbol; kpi = nothing)
    spec = RULE_CATALOGUE[rule]
    metric = rule in BALANCE_RULES ? balance_metric(c, rule) : rule_metric(c, rule)
    roll = rolling_mean(metric, spec.window_hours)
    stamps = c.book[spec.tag].stamps
    findings = Finding[]
    n = length(roll)
    i = 1
    while i <= n
        bad = isfinite(roll[i]) && (spec.comparator === :le ? roll[i] > spec.reference :
                                    spec.comparator === :ge ? roll[i] < spec.reference :
                                    roll[i] > spec.reference)
        if bad
            j = i
            while j < n && isfinite(roll[j + 1]) &&
                  (spec.comparator === :le ? roll[j + 1] > spec.reference :
                   spec.comparator === :ge ? roll[j + 1] < spec.reference :
                   roll[j + 1] > spec.reference)
                j += 1
            end
            if j - i + 1 >= spec.minimum_hours
                vals = [roll[k] for k in i:j if isfinite(roll[k])]
                value = isempty(vals) ? NaN : sum(vals) / length(vals)
                excess = spec.comparator === :ge ? spec.reference - value : value - spec.reference
                push!(findings, Finding(Symbol(rule, :_, i), rule, spec.area, spec.severity,
                    spec.tag, spec.role, value, spec.reference, spec.unit,
                    iszero(spec.reference) ? NaN : 100.0 * excess / abs(spec.reference),
                    stamps[i], stamps[j], j - i + 1, fault_cost(rule, excess, kpi),
                    spec.title * " -- " * spec.basis))
            end
            i = j + 1
        else
            i += 1
        end
    end
    return findings
end

"""
    detect_faults(campaign; rules, kpi) -> Vector{Finding}

Run every rule of the catalogue (or the ones listed in `rules`) and return the
findings ordered by what they are worth: critical first, then the largest value at
stake.
"""
function detect_faults(c::Campaign; rules::Vector{Symbol} = rule_ids(), kpi = nothing)
    findings = Finding[]
    for r in rules
        append!(findings, detect_rule(c, r; kpi = kpi))
    end
    severity_rank(s) = findfirst(==(s), SEVERITIES)
    return sort(findings; by = f -> (-severity_rank(f.severity), -f.cost_at_stake, f.from))
end

"""Row per rule of the catalogue, for the rule register of the report."""
rules_table() = [Dict{Symbol,Any}(:rule => r, :title => RULE_CATALOGUE[r].title,
    :area => RULE_CATALOGUE[r].area, :severity => RULE_CATALOGUE[r].severity,
    :tag => RULE_CATALOGUE[r].tag, :role => RULE_CATALOGUE[r].role,
    :comparator => RULE_CATALOGUE[r].comparator, :reference => RULE_CATALOGUE[r].reference,
    :unit => RULE_CATALOGUE[r].unit, :window_hours => RULE_CATALOGUE[r].window_hours,
    :minimum_hours => RULE_CATALOGUE[r].minimum_hours, :basis => RULE_CATALOGUE[r].basis)
                 for r in rule_ids()]

"""Counts of findings by severity, area and rule."""
function diagnostics_summary(findings::Vector{Finding})
    by_severity = Dict{Symbol,Int}(s => 0 for s in SEVERITIES)
    by_area = Dict{Symbol,Int}(a => 0 for a in AREAS)
    by_rule = Dict{Symbol,Int}()
    for f in findings
        by_severity[f.severity] = get(by_severity, f.severity, 0) + 1
        by_area[f.area] = get(by_area, f.area, 0) + 1
        by_rule[f.rule] = get(by_rule, f.rule, 0) + 1
    end
    stake = sum(f.cost_at_stake for f in findings; init = 0.0)
    return Dict{Symbol,Any}(:count => length(findings), :by_severity => by_severity,
        :by_area => Dict{Symbol,Any}(a => v for (a, v) in by_area if v > 0),
        :by_rule => Dict{Symbol,Any}(r => v for (r, v) in by_rule),
        :cost_at_stake => stake, :hours_in_alarm => sum(f.intervals for f in findings; init = 0),
        :worst => isempty(findings) ? nothing : first(findings),
        :status => by_severity[:critical] > 0 ? :action_required :
                  by_severity[:warning] > 0 ? :attention : :healthy)
end

"""
    verify_detection(findings, deviations; tolerance_hours) -> Dict{Symbol,Any}

Score the detector against the deviations the campaign actually injected: a
deviation counts as detected when a finding of the expected rule overlaps its
window (within a tolerance). The report can therefore state the detection rate
instead of claiming it.
"""
function verify_detection(findings::Vector{Finding}, deviations::Vector{Deviation};
    tolerance_hours::Integer = 48)
    rows = Vector{Dict{Symbol,Any}}()
    detected = 0
    for d in deviations
        hits = [f for f in findings
                if get(RULE_TO_FAULT, f.rule, :none) === d.id &&
                   f.intervals > 0 && _hour_index(d, f) <= tolerance_hours]

        ok = !isempty(hits)
        ok && (detected += 1)
        push!(rows, Dict{Symbol,Any}(:fault => d.id, :role => d.role, :kind => d.kind,
            :magnitude => d.magnitude, :unit => d.unit, :from_hour => d.from_hour,
            :to_hour => d.to_hour, :hours => d.to_hour - d.from_hour + 1, :detected => ok,
            :rule => isempty(hits) ? :none : hits[1].rule, :findings => length(hits),
            :stake => isempty(hits) ? 0.0 : sum(f.cost_at_stake for f in hits)))
    end
    return Dict{Symbol,Any}(:rows => rows, :injected => length(deviations), :detected => detected,
        :detection_rate_pct => isempty(deviations) ? 100.0 : 100.0 * detected / length(deviations),
        :status => detected == length(deviations) ? :compliant :
                  detected >= 0.8 * length(deviations) ? :at_risk : :noncompliant)
end

"""Distance in hours between a finding and a deviation window (0 when they overlap)."""
function _hour_index(d::Deviation, f::Finding)
    origin = Dates.Date(campaign_start())
    f_start = 24 * Dates.value(Dates.Date(f.from) - origin) + Dates.hour(f.from)
    f_stop = 24 * Dates.value(Dates.Date(f.to) - origin) + Dates.hour(f.to)
    (f_stop < d.from_hour) && return d.from_hour - f_stop
    (f_start > d.to_hour) && return f_start - d.to_hour
    return 0
end

"""
    fault_detection_report(campaign, kpi; rules) -> Dict{Symbol,Any}

Run the detector, score it against the injected deviations and return the bundle
the report and the JSON payload are built from: `:findings`, `:rows`, `:summary`,
`:verification`, `:rules` and `:by_area`.
"""
function fault_detection_report(c::Campaign, kpi = nothing; rules::Vector{Symbol} = rule_ids())
    findings = detect_faults(c; rules = rules, kpi = kpi)
    return Dict{Symbol,Any}(:findings => findings, :rows => finding_row.(findings),
        :summary => diagnostics_summary(findings), :verification => verify_detection(findings,
            c.deviations), :rules => rules_table(), :rules_checked => length(rules),
        :by_area => begin
            out = Dict{Symbol,Any}()
            for a in AREAS
                fs = [f for f in findings if f.area === a]
                isempty(fs) && continue
                out[a] = diagnostics_summary(fs)
            end
            out
        end)
end

"""The worst findings of a report, in a table ready for the printout."""
worst_findings(fdd::Dict{Symbol,Any}, n::Integer = 12) =
    finding_row.(first(fdd[:findings], min(n, length(fdd[:findings]))))





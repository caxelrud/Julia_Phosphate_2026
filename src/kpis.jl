# =============================================================================
# kpis.jl -- the performance bundle of a campaign.
#
# One symbol-keyed dictionary holds every figure the plant is judged on: the
# metallurgical balance of the beneficiation plant, the acidulation ratios of the
# reaction section, the steam and power specific consumptions, the quality of the
# product, the emissions, the cost and the carbon. Every entry is computed from the
# historian of `plantdata.jl` over the *operating* intervals of the campaign, so a
# planned outage never dilutes a specific consumption.
# =============================================================================

"""Target of every performance metric, with its unit and its direction."""
const PERFORMANCE_TARGETS = Dict{Symbol,NamedTuple}(
    :flotation_recovery => (target = 86.0, unit = :pct, comparator = :ge,
        basis = "registered recoveries of the rougher-cleaner circuit"),
    :plant_p2o5_recovery => (target = 84.0, unit = :pct, comparator = :ge,
        basis = "P2O5 in the product plus the merchant acid over the P2O5 in the flotation feed"),
    :grind_p80 => (target = 150.0, unit = :um, comparator = :le,
        basis = "liberation size of the blend"),
    :acid_consumption => (target = 2.85, unit = :t_ph, comparator = :le,
        basis = "t H2SO4 per t P2O5, stoichiometric demand plus the registered excess"),
    :sulphur_consumption => (target = 0.95, unit = :t_ph, comparator = :le,
        basis = "t sulphur per t P2O5 at 99.7% conversion"),
    :ammonia_consumption => (target = 0.490, unit = :t_ph, comparator = :le,
        basis = "t NH3 per t P2O5 of DAP"),
    :steam_consumption => (target = 0.65, unit = :t_ph, comparator = :le,
        basis = "t steam per t P2O5 fed, weak acid at 28.5 % raised to 52 % at an economy of 3.0"),
    :electricity_consumption => (target = 210.0, unit = :kwh_per_t, comparator = :le,
        basis = "kWh per t P2O5, mine to bagged product"),
    :specific_energy => (target = 3.50, unit = :gj_per_t, comparator = :le,
        basis = "GJ per t P2O5: steam of the evaporators, fuel of the dryers and power"),
    :filtration_rate => (target = 5.00, unit = :t_per_m2_d, comparator = :ge,
        basis = "t P2O5 per m2 of filter per day"),
    :water_soluble_loss => (target = 2.00, unit = :pct, comparator = :le,
        basis = "water-soluble P2O5 lost with the gypsum, per cent of the P2O5 fed"),
    :acid_strength => (target = 52.0, unit = :wt_pct, comparator = :ge,
        basis = "P2O5 in the merchant acid"),
    :acid_p2o5_yield => (target = 96.5, unit = :pct, comparator = :ge,
        basis = "P2O5 reaching the filters over the P2O5 fed to the attack"),
    :acid_concentration_yield => (target = 97.0, unit = :pct, comparator = :ge,
        basis = "P2O5 in the merchant acid over the P2O5 the evaporators concentrate: a closure check at three per cent of meter slack"),
    :acid_so4 => (target = 1.50, unit = :wt_pct, comparator = :le,
        basis = "sulphate of the merchant acid: the specification limit of the grade"),
    :acid_f => (target = 0.50, unit = :wt_pct, comparator = :le,
        basis = "fluorine of the merchant acid: the specification limit of the grade"),
    :acid_solids => (target = 0.50, unit = :wt_pct, comparator = :le,
        basis = "solids of the merchant acid: the specification limit of the grade"),
    :acid_steam => (target = 0.62, unit = :t_ph, comparator = :le,
        basis = "t steam per t P2O5 concentrated, at an economy of 3.0"),
    :acid_electricity => (target = 75.0, unit = :kwh_per_t, comparator = :le,
        basis = "kWh per t P2O5 concentrated, blower of the acid plant and evaporator set"),
    :acid_cost => (target = 600.0, unit = :usd_per_t, comparator = :le,
        basis = "variable cost per t P2O5 sold as merchant acid: feed by acid share, concentration in full"),
    :product_moisture => (target = 2.00, unit = :wt_pct, comparator = :le,
        basis = "moisture of the bagged product"),
    :product_wsp => (target = 85.0, unit = :wt_pct, comparator = :ge,
        basis = "water-soluble P2O5 of the product"),
    :stack_fluoride => (target = 5.0, unit = :count, comparator = :le,
        basis = "mg F per Nm3 at the stack, the permitted limit"),
    :stack_dust => (target = 30.0, unit = :count, comparator = :le,
        basis = "mg dust per Nm3 at the stack, the permitted limit"),
    :completeness => (target = 98.0, unit = :pct, comparator = :ge,
        basis = "usable intervals of the historian"),
    :availability => (target = 92.0, unit = :pct, comparator = :ge,
        basis = "hours the reaction section was available"),
    :variable_cost => (target = 400.0, unit = :usd_per_t, comparator = :le,
        basis = "variable cost per tonne of DAP"),
    :carbon_intensity => (target = 145.0, unit = :kg_ph, comparator = :le,
        basis = "kgCO2e per t P2O5, scope 1 and 2"),
)

"""Emission factors of the site: the CO2 of each energy carrier and of the process."""
const EMISSION_FACTORS = (
    grid_electricity_kg_per_kwh = 0.371,
    natural_gas_kg_per_gj = 50.29,
    process_co2_kg_per_kg_caco3 = CO2_PER_CACO3,
    sulphuric_acid_kg_per_t = 0.120,
    ammonia_kg_per_t = 1.830,
)

## ---- masked aggregation over the historian ------------------------------------

"""Intervals of the campaign that are usable *and* inside the mask."""
function active_indices(c::Campaign, tag::Symbol, mask::AbstractVector{Bool})
    s = c.book[tag]
    return [i for i in eachindex(s.values)
            if mask[i] && s.qualities[i] in OK_QUALITY && isfinite(s.values[i])]
end

"""Sum of a signal over the operating intervals (a flow, in its own unit)."""
function masked_sum(c::Campaign, tag::Symbol, mask::AbstractVector{Bool})
    s = c.book[tag]
    return sum(s.values[i] for i in active_indices(c, tag, mask); init = 0.0)
end

"""Mean of a signal over the operating intervals (a level, in its own unit)."""
function masked_mean(c::Campaign, tag::Symbol, mask::AbstractVector{Bool})
    idx = active_indices(c, tag, mask)
    isempty(idx) && return NaN
    s = c.book[tag]
    return sum(s.values[i] for i in idx) / length(idx)
end

"""Largest and smallest value of a signal over the operating intervals."""
function masked_extrema(c::Campaign, tag::Symbol, mask::AbstractVector{Bool})
    idx = active_indices(c, tag, mask)
    isempty(idx) && return (max = NaN, min = NaN)
    s = c.book[tag]
    v = s.values[idx]
    return (max = maximum(v), min = minimum(v))
end

"""Number of operating intervals with a usable reading of the signal."""
masked_hours(c::Campaign, tag::Symbol, mask::AbstractVector{Bool}) =
    length(active_indices(c, tag, mask))

"""Per cent of the operating intervals of a signal that carry a usable reading."""
function masked_completeness(c::Campaign, tag::Symbol, mask::AbstractVector{Bool})
    n = count(mask)
    return n == 0 ? 0.0 : 100.0 * masked_hours(c, tag, mask) / n
end

"""Status of a metric against its target: compliant, at risk or non-compliant."""
function target_status(value::Real, target::Real, comparator::Symbol; band::Real = 0.10)
    (!isfinite(value) || !isfinite(target)) && return :not_assessed
    if comparator === :ge
        value >= target && return :compliant
        value >= target * (1.0 - band) && return :at_risk
        return :noncompliant
    elseif comparator === :le
        value <= target && return :compliant
        value <= target * (1.0 + band) && return :at_risk
        return :noncompliant
    end
    return abs(value - target) <= band * abs(target) ? :compliant : :at_risk
end

"""Margin of a metric to its target, in per cent of the target (positive is good)."""
function target_margin(value::Real, target::Real, comparator::Symbol)
    (!isfinite(value) || !isfinite(target) || target == 0.0) && return NaN
    m = 100.0 * (value - target) / abs(target)
    return comparator === :ge ? m : -m
end

"""One row of the target register: `(metric, actual, target, unit, comparator, ...)`."""
function target_row(metric::Symbol, value::Real, mask = nothing)
    t = PERFORMANCE_TARGETS[metric]
    unit = t.unit === :pct ? :pct : t.unit
    return Dict{Symbol,Any}(:metric => metric, :actual => value, :target => t.target,
        :unit => unit, :comparator => t.comparator, :basis => t.basis,
        :status => target_status(value, t.target, t.comparator),
        :margin_pct => target_margin(value, t.target, t.comparator))
end

## ---- the KPI bundle ------------------------------------------------------------

"""Total of a tag over the mask: summed for a flow, averaged for a level."""
tag_total(c::Campaign, tag::Symbol, mask::AbstractVector{Bool}) =
    SIGNAL_TAGS[tag].kind === :flow ? masked_sum(c, tag, mask) : masked_mean(c, tag, mask)

"""
    site_kpis(campaign; mask, baseline_months, design) -> Dict{Symbol,Any}

The performance bundle of a campaign, computed over the operating intervals
(`:production` and `:startup` by default):

* `:period` -- window, operating hours and availability
* `:ore`, `:beneficiation`, `:attack`, `:filtration`, `:evaporation`, `:granulation`
  -- the section balances and their specific figures
* `:energy` -- steam, power, fuel and the specific energy of the product
* `:product` -- tonnage, grade, nitrogen, moisture and solubility
* `:losses` -- the P2O5 that did not become product, by cause
* `:cost`, `:carbon`, `:emissions`, `:water` -- the economic and environmental views
* `:quality` -- completeness of the historian, gaps and defects
* `:targets` -- the metric register with its status against [`PERFORMANCE_TARGETS`](@ref)
* `:by_area` -- the section cards used by the report
"""
function site_kpis(c::Campaign; mask::AbstractVector{Bool} = mode_mask(c),
    baseline_months::Integer = 6, design::PlantDesign = c.design)
    m = mask
    book = c.book
    hours = count(m)
    total_hours = length(c.schedule[:mode])
    outage_hours = count(==(0.0), c.schedule[:frac])
    ## ---- production chain, section by section
    rom_t = masked_sum(c, :ROM_FEED, m)
    feed_grade = masked_mean(c, :FLOT_FEED_P2O5, m)
    conc_grade = masked_mean(c, :CONC_P2O5, m)
    tail_grade = masked_mean(c, :TAIL_P2O5, m)
    concentrate_t = masked_sum(c, :ROCK_FEED, m) / 0.985
    p2o5_ore = rom_t * feed_grade / 100.0
    p2o5_concentrate = concentrate_t * conc_grade / 100.0
    p2o5_tailings = (rom_t - concentrate_t) * tail_grade / 100.0
    mill_kwh = masked_sum(c, :MILL_POWER, m) + masked_sum(c, :CRUSHER_POWER, m)
    rock_t = masked_sum(c, :ROCK_FEED, m)
    p2o5_fed = masked_sum(c, :P2O5_FEED_RATE, m)
    acid_t = masked_sum(c, :H2SO4_FLOW, m)
    sulphur_t = masked_sum(c, :SULPHUR_FEED, m)
    gypsum_t = masked_sum(c, :GYPSUM_FLOW, m)
    free_p2o5 = masked_mean(c, :GYPSUM_FREE_P2O5, m)
    water_soluble = gypsum_t * free_p2o5 / 100.0
    wash_t = masked_sum(c, :WASH_WATER_FLOW, m)
    steam_t = masked_sum(c, :STEAM_FLOW, m)
    product_t = masked_sum(c, :PRODUCT_FLOW, m)
    ammonia_t = masked_sum(c, :AMMONIA_FLOW, m)
    merchant_t = masked_sum(c, :MERCHANT_ACID_FLOW, m)
    strength = masked_mean(c, :STRONG_ACID_P2O5, m)
    p2o5_product = product_t * 0.4605
    p2o5_merchant = merchant_t * strength / 100.0
    p2o5_recovery = p2o5_ore > 0 ? (p2o5_product + p2o5_merchant) / p2o5_ore : NaN
    ## ---- energy and water
    electricity_kwh = mill_kwh + 0.42 * hours + 1.9 * product_t
    turbine_mwh = masked_sum(c, :TURBINE_POWER, m)
    fuel_gj = masked_sum(c, :DRYER_FUEL_FLOW, m)
    steam_gj = steam_t * 2.769
    energy_gj = steam_gj + fuel_gj + electricity_kwh * 0.0036
    water_m3 = masked_sum(c, :PROCESS_WATER_FLOW, m)
    cooling_evap = cooling_tower_evaporation(design.cooling_circulation_m3ph,
        design.cooling_range_k) * hours
    cooling_drift = cooling_tower_drift(design.cooling_circulation_m3ph) * hours
    cooling_blowdown = cooling_tower_blowdown(cooling_evap / max(hours, 1.0),
        design.cooling_cycles) * hours
    ## ---- losses, cost, carbon and emissions
    p2o5_recovery = p2o5_ore > 0 ? (p2o5_product + p2o5_merchant) / p2o5_ore : NaN
    flotation_recovery = p2o5_ore > 0 ? p2o5_concentrate / p2o5_ore : NaN
    unreacted_t = p2o5_concentrate - p2o5_fed
    gas_gj = fuel_gj
    process_co2_t = carbonate_co2(rock_t, upgraded_assay(blend_assay(c.schedule[:ore][1]),
        masked_mean(c, :ROCK_P2O5, m) / 100.0)) / 1000.0
    scope_1 = gas_gj * EMISSION_FACTORS.natural_gas_kg_per_gj / 1000.0 + process_co2_t
    scope_2 = electricity_kwh * EMISSION_FACTORS.grid_electricity_kg_per_kwh / 1000.0
    scope_3 = (sulphur_t / 1000.0 * EMISSION_FACTORS.sulphuric_acid_kg_per_t +
               ammonia_t / 1000.0 * EMISSION_FACTORS.ammonia_kg_per_t +
               water_m3 * 0.34 / 1000.0)
    f_released = hf_release(rock_t, upgraded_assay(blend_assay(c.schedule[:ore][1]),
        masked_mean(c, :ROCK_P2O5, m) / 100.0); release = 0.45) / 1000.0
    cost = _cost_items(c, m; rom_t, rock_t, p2o5_fed, acid_t, sulphur_t, ammonia_t,
        electricity_kwh, fuel_gj, water_m3, gypsum_t, product_t, p2o5_product)
    revenue = product_t * ECONOMICS[:dap_per_t] + merchant_t * ECONOMICS[:merchant_acid_per_t_p2o5] *
              strength / 100.0
    ## ---- the acid route, evaluated as a product in its own right
    reagent_t = masked_sum(c, :REAGENT_FLOW, m) / 1000.0
    acid = acid_evaluation(c, m; design = design, rock_t = rock_t, reagent_t = reagent_t,
        p2o5_fed = p2o5_fed, strength = strength, merchant_t = merchant_t, steam_t = steam_t,
        sulphur_t = sulphur_t, acid_t = acid_t, water_m3 = water_m3, gypsum_t = gypsum_t,
        gypsum_free_p2o5 = free_p2o5, hours = hours)
    ## ---- targets
    targets = Dict{Symbol,Any}()
    metric_values = Dict{Symbol,Any}(
        :flotation_recovery => 100.0 * flotation_recovery,
        :plant_p2o5_recovery => 100.0 * p2o5_recovery,
        :grind_p80 => masked_mean(c, :CYCLONE_P80, m),
        :acid_consumption => p2o5_fed > 0 ? acid_t / p2o5_fed : NaN,
        :sulphur_consumption => p2o5_fed > 0 ? sulphur_t / p2o5_fed : NaN,
        :ammonia_consumption => p2o5_fed > 0 ? ammonia_t / p2o5_fed : NaN,
        :steam_consumption => p2o5_fed > 0 ? steam_t / p2o5_fed : NaN,
        :electricity_consumption => p2o5_fed > 0 ? electricity_kwh / p2o5_fed : NaN,
        :specific_energy => p2o5_fed > 0 ? energy_gj / p2o5_fed : NaN,
        :filtration_rate => masked_mean(c, :FILTER_RATE, m),
        :water_soluble_loss => p2o5_fed > 0 ? 100.0 * water_soluble / p2o5_fed : NaN,
        :acid_strength => strength,
        :product_moisture => masked_mean(c, :PRODUCT_MOISTURE, m),
        :product_wsp => masked_mean(c, :PRODUCT_WSP, m),
        :stack_fluoride => masked_mean(c, :STACK_F, m),
        :stack_dust => masked_mean(c, :STACK_DUST, m),
        :completeness => book_completeness(book),
        :availability => 100.0 * (total_hours - outage_hours) / max(total_hours, 1),
        :variable_cost => product_t > 0 ? (sum(values(cost)) * 1.0e3) / product_t : NaN,
        :acid_p2o5_yield => acid[:summary][:filtration_yield_pct],
        :acid_concentration_yield => acid[:summary][:concentration_yield_pct],
        :acid_so4 => get(acid[:quality][:values], :so4, NaN),
        :acid_f => get(acid[:quality][:values], :f, NaN),
        :acid_solids => get(acid[:quality][:values], :solids, NaN),
        :acid_steam => acid[:summary][:steam_per_p2o5],
        :acid_electricity => acid[:summary][:electricity_per_p2o5],
        :acid_cost => acid[:summary][:cost_per_t_p2o5],
        :carbon_intensity => p2o5_fed > 0 ? 1000.0 * (scope_1 + scope_2) / p2o5_fed : NaN)
    for (metric, value) in metric_values
        targets[metric] = target_row(metric, value)
    end
    ## ---- the quality of the historian itself
    quality = _quality_report(c, m)
    ## ---- the bundle
    kpi = Dict{Symbol,Any}(
        :site => Dict{Symbol,Any}(:id => design.site.id, :name => design.site.name,
            :country => design.site.country, :currency => design.site.currency,
            :product => design.product, :capacity_t_p2o5_year => design.site.capacity_t_p2o5_year),
        :period => Dict{Symbol,Any}(:from => book.context[:from], :to => book.context[:to],
            :days => c.meta[:days], :hours => total_hours, :operating_hours => hours,
            :outage_hours => outage_hours,
            :availability_pct => 100.0 * (total_hours - outage_hours) / max(total_hours, 1),
            :mode_split => mode_split(c), :baseline_months => baseline_months),
        :meta => Dict{Symbol,Any}(:source => :synthetic_campaign, :seed => c.meta[:seed],
            :generated_at => c.meta[:generated_at], :basis => c.meta[:basis]),
        :acid => acid,
        :ore => Dict{Symbol,Any}(:rom_t => rom_t, :rock_t => rock_t, :concentrate_t => concentrate_t,
            :feed_grade => feed_grade, :concentrate_grade => conc_grade,
            :tailings_grade => tail_grade, :p2o5_ore => p2o5_ore, :p2o5_feed => p2o5_concentrate,
            :p2o5_tailings => p2o5_tailings, :tailings_loss_pct => p2o5_ore > 0 ?
                100.0 * p2o5_tailings / p2o5_ore : NaN),
        :beneficiation => Dict{Symbol,Any}(:recovery_pct => 100.0 * flotation_recovery,
            :grind_p80 => masked_mean(c, :CYCLONE_P80, m),
            :slurry_density => masked_mean(c, :SLURRY_DENSITY, m),
            :mill_kwh => mill_kwh, :mill_kwh_per_t => rom_t > 0 ? mill_kwh / rom_t : NaN,
            :reagent_t => reagent_t,
            :reagent_kg_per_t => rom_t > 0 ? masked_sum(c, :REAGENT_FLOW, m) / rom_t : NaN,
            :mill_sound_db => masked_mean(c, :MILL_SOUND_DB, m),
            :mass_balance_residual_pct => p2o5_ore > 0 ?
                100.0 * (p2o5_concentrate + p2o5_tailings - p2o5_ore) / p2o5_ore : NaN),
    )
    return merge(kpi, _kpi_sections(c, m; design, rock_t, p2o5_fed, acid_t, sulphur_t, gypsum_t,
        free_p2o5, water_soluble, wash_t, steam_t, product_t, ammonia_t, merchant_t,
        strength, p2o5_product, p2o5_merchant, p2o5_recovery, electricity_kwh, turbine_mwh,
        fuel_gj, energy_gj, water_m3, cooling_evap, cooling_drift, cooling_blowdown, cost,
        revenue, scope_1, scope_2, scope_3, f_released, process_co2_t, targets, quality, hours,
        target_hours = count(mode_mask(c, (:production, :startup, :upset)))))
end

"""Cost of the campaign by item, in thousands of the site currency."""
function _cost_items(c::Campaign, m; rom_t, rock_t, p2o5_fed, acid_t, sulphur_t, ammonia_t,
    electricity_kwh, fuel_gj, water_m3, gypsum_t, product_t, p2o5_product)
    reagent_t = masked_sum(c, :REAGENT_FLOW, m) / 1000.0
    outage_hours = count(==(0.0), c.schedule[:frac])
    return Dict{Symbol,Float64}(
        :rock => rock_t * ECONOMICS[:rock_per_t] / 1000.0,
        :sulphur => sulphur_t * ECONOMICS[:sulphur_per_t] / 1000.0,
        :ammonia => ammonia_t * ECONOMICS[:ammonia_per_t] / 1000.0,
        :electricity => electricity_kwh * ECONOMICS[:electricity_per_kwh] / 1000.0,
        :fuel => fuel_gj * ECONOMICS[:natural_gas_per_gj] / 1000.0,
        :water => water_m3 * ECONOMICS[:process_water_per_m3] / 1000.0,
        :reagents => reagent_t * ECONOMICS[:reagent_per_t] / 1000.0,
        :grinding_media => rom_t * ECONOMICS[:grinding_media_per_t] / 1000.0,
        :gypsum_disposal => gypsum_t * ECONOMICS[:gypsum_disposal_per_t] / 1000.0,
        :maintenance => product_t * ECONOMICS[:maintenance_per_t] / 1000.0,
        :packaging => product_t * ECONOMICS[:packaging_per_t] / 1000.0,
        :labour => count(m) * ECONOMICS[:labour_per_h] / 1000.0,
        :downtime => 0.35 * outage_hours * ECONOMICS[:unscheduled_downtime_per_h] / 1000.0,
    )
end

"""Quality of the historian: completeness, defect runs and the worst signals."""
function _quality_report(c::Campaign, m)
    rows = Vector{Dict{Symbol,Any}}()
    defects = Any[]
    counts = Dict{Symbol,Int}(q => 0 for q in QUALITY_FLAGS)
    for t in signal_tags()
        s = c.book[t]
        for q in s.qualities
            counts[q] = get(counts, q, 0) + 1
        end
        for r in bad_intervals(s)
            push!(defects, Dict{Symbol,Any}(:tag => t, :from => r.from, :to => r.to,
                :intervals => r.count, :quality => r.quality))
        end
        push!(rows, Dict{Symbol,Any}(:tag => t, :area => s.meta[:area],
            :intervals => length(s), :completeness_pct => completeness(s),
            :measured => count(==(:measured), s.qualities),
            :faulty => count(==(:faulty), s.qualities),
            :missing => count(==(:missing), s.qualities),
            :substituted => count(==(:substituted), s.qualities),
            :worst => worst_quality(s.qualities)))
    end
    sort!(rows; by = x -> x[:completeness_pct])
    sort!(defects; by = x -> x[:from])
    return Dict{Symbol,Any}(:intervals => length(c.schedule[:mode]),
        :operating_intervals => count(m),
        :completeness_pct => book_completeness(c.book),
        :defect_runs => length(defects), :defect_intervals => sum(d[:intervals] for d in defects;
                                                                 init = 0),
        :by_kind => Dict{Symbol,Any}(k => v for (k, v) in counts if v > 0),
        :by_signal => rows, :defects => defects,
        :status => target_status(book_completeness(c.book), 98.0, :ge))
end

"""Sections of the KPI bundle: attack, filtration, evaporation, granulation, energy, cost."""
function _kpi_sections(c::Campaign, m; design, rock_t, p2o5_fed, acid_t, sulphur_t, gypsum_t,
    free_p2o5, water_soluble, wash_t, steam_t, product_t, ammonia_t, merchant_t,
    strength, p2o5_product, p2o5_merchant, p2o5_recovery, electricity_kwh, turbine_mwh, fuel_gj,
    energy_gj, water_m3, cooling_evap, cooling_drift, cooling_blowdown, cost, revenue, scope_1,
    scope_2, scope_3, f_released, process_co2_t, targets, quality, hours, target_hours)
    per_t = (x, base) -> base > 0 ? x / base : NaN
    cost_total = sum(values(cost))
    thermal_gj = steam_t * 2.769 + fuel_gj
    sections = Dict{Symbol,Any}(
        :attack => Dict{Symbol,Any}(:p2o5_fed => p2o5_fed, :rock_t => rock_t,
            :acid_t => acid_t, :acid_per_p2o5 => per_t(acid_t, p2o5_fed),
            :sulphur_t => sulphur_t, :sulphur_per_p2o5 => per_t(sulphur_t, p2o5_fed),
            :temperature => masked_mean(c, :ATTACK_TEMP, m),
            :free_so4 => masked_mean(c, :FREE_SO4, m),
            :slurry_sg => masked_mean(c, :SLURRY_SG, m),
            :reactor_level => masked_mean(c, :REACTOR_LEVEL, m),
            :gypsum_t => gypsum_t, :gypsum_per_p2o5 => per_t(gypsum_t, p2o5_fed),
            :acid_excess_pct => 100.0 * design.acid_excess),
        :filtration => Dict{Symbol,Any}(:rate => masked_mean(c, :FILTER_RATE, m),
            :free_p2o5 => free_p2o5, :water_soluble_t => water_soluble,
            :water_soluble_pct => p2o5_fed > 0 ? 100.0 * water_soluble / p2o5_fed : NaN,
            :wash_ratio => per_t(wash_t, p2o5_fed), :vacuum => masked_mean(c, :FILTER_VACUUM, m),
            :weak_strength => masked_mean(c, :WEAK_ACID_P2O5, m),
            :free_acid_wash => masked_mean(c, :F_WASH_WATER, m),
            :filter_area_m2 => design.filter_area_m2),
        :evaporation => Dict{Symbol,Any}(:steam_t => steam_t,
            :steam_per_p2o5 => per_t(steam_t, p2o5_fed), :strength => strength,
            :density => masked_mean(c, :EVAP_DENSITY, m),
            :temperature => masked_mean(c, :EVAP_TEMP, m),
            :vacuum => masked_mean(c, :EVAP_VACUUM, m),
            :economy => steam_t > 0 ? evaporated_water(c, m, p2o5_fed, strength) / steam_t : NaN,
            :economy_target => design.evaporator_economy,
            :merchant_t => merchant_t, :merchant_p2o5 => p2o5_merchant),
        :granulation => Dict{Symbol,Any}(:product_t => product_t,
            :ammonia_t => ammonia_t, :ammonia_per_p2o5 => per_t(ammonia_t, p2o5_fed),
            :ammoniation_ratio => p2o5_fed > 0 ?
                (ammonia_t / MOLAR_MASSES.nh3) / (2.0 * p2o5_fed / MOLAR_MASSES.p2o5) : NaN,
            :n => masked_mean(c, :PRODUCT_N, m),
            :moisture => masked_mean(c, :PRODUCT_MOISTURE, m),
            :wsp => masked_mean(c, :PRODUCT_WSP, m),
            :recycle_ratio => masked_mean(c, :RECYCLE_RATIO, m),
            :granulator_temperature => masked_mean(c, :GRAN_BED_TEMP, m),
            :dryer_temperature => masked_mean(c, :DRYER_OUTLET_TEMP, m),
            :cooler_temperature => masked_mean(c, :COOLER_OUTLET_TEMP, m),
            :oversize_pct => masked_mean(c, :OVERSIZE_PCT, m),
            :fines_pct => masked_mean(c, :FINES_PCT, m)),
    )
    return merge(sections, _kpi_sections_2(c, m; design, p2o5_fed, p2o5_product, p2o5_merchant,
        product_t, merchant_t, p2o5_recovery, electricity_kwh, turbine_mwh, fuel_gj, energy_gj,
        thermal_gj, water_m3, cooling_evap, cooling_drift, cooling_blowdown, cost, cost_total,
        revenue, scope_1, scope_2, scope_3, f_released, process_co2_t, targets, quality, hours,
        target_hours))
end

"""Second half of the KPI sections: product, losses, energy, water, cost and carbon."""
function _kpi_sections_2(c::Campaign, m; design, p2o5_fed, p2o5_product, p2o5_merchant,
    product_t, merchant_t, p2o5_recovery, electricity_kwh, turbine_mwh, fuel_gj, energy_gj,
    thermal_gj, water_m3, cooling_evap, cooling_drift, cooling_blowdown, cost, cost_total,
    revenue, scope_1, scope_2, scope_3, f_released, process_co2_t, targets, quality, hours,
    target_hours)
    per_t = (x, base) -> base > 0 ? x / base : NaN
    tailings_loss = masked_mean(c, :TAIL_P2O5, m) *
                    max(masked_sum(c, :ROM_FEED, m) - masked_sum(c, :ROCK_FEED, m), 0.0) / 100.0
    water_soluble = masked_mean(c, :GYPSUM_FREE_P2O5, m) * masked_sum(c, :GYPSUM_FLOW, m) / 100.0
    ## the waste-heat boiler of the acid plant makes steam in proportion to the sulphur burnt,
    ## the same relation the historian uses; the ratio to the evaporator draw is the heat recovery
    steam_t = masked_sum(c, :STEAM_FLOW, m)
    steam_gen = design.waste_heat_steam_tph * masked_sum(c, :SULPHUR_FEED, m) /
                signal_spec(:SULPHUR_FEED).nominal
    unreacted = max(0.0, p2o5_fed - p2o5_product)
    losses = [Dict{Symbol,Any}(:cause => cause, :tonnes => value,
        :share_pct => p2o5_fed > 0 ? 100.0 * value / p2o5_fed : NaN)
              for (cause, value) in (:flotation_tailings => tailings_loss,
                  :water_soluble => water_soluble, :unprocessed => unreacted)]
    return Dict{Symbol,Any}(
        :product => Dict{Symbol,Any}(:tonnes => product_t, :grade_p2o5 => 46.05,
            :n_pct => masked_mean(c, :PRODUCT_N, m),
            :moisture_pct => masked_mean(c, :PRODUCT_MOISTURE, m),
            :wsp_pct => masked_mean(c, :PRODUCT_WSP, m), :merchant_acid_t => merchant_t,
            :p2o5_product => p2o5_product, :p2o5_merchant => p2o5_merchant,
            :p2o5_recovery_pct => 100.0 * p2o5_recovery, :product => design.product),
        :losses => Dict{Symbol,Any}(:p2o5_fed => p2o5_fed, :p2o5_product => p2o5_product,
            :total_t => p2o5_fed - p2o5_product, :by_cause => losses),
        :energy => Dict{Symbol,Any}(:electricity_kwh => electricity_kwh,
            :electricity_per_p2o5 => per_t(electricity_kwh, p2o5_fed),
            :turbine_mwh => turbine_mwh, :fuel_gj => fuel_gj, :thermal_gj => thermal_gj,
            :steam_gj => steam_t * 2.769,
            :steam_t => steam_t, :steam_generated_t => steam_gen,
            :heat_recovery_pct => steam_t > 0 ? 100.0 * steam_gen / steam_t : NaN,
            :total_gj => energy_gj, :specific_gj_per_p2o5 => per_t(energy_gj, p2o5_fed),
            :specific_gj_per_product => per_t(energy_gj, product_t),
            :fuel_gj_per_product => per_t(fuel_gj, product_t)),
        :water => Dict{Symbol,Any}(:process_water_m3 => water_m3,
            :water_per_p2o5 => per_t(water_m3, p2o5_fed),
            :wash_water_m3 => masked_sum(c, :WASH_WATER_FLOW, m),
            :cooling_evaporation_m3 => cooling_evap, :cooling_drift_m3 => cooling_drift,
            :cooling_blowdown_m3 => cooling_blowdown,
            :effluent_ph => masked_mean(c, :EFFLUENT_PH, m)),
        :emissions => Dict{Symbol,Any}(:stack_fluoride => masked_mean(c, :STACK_F, m),
            :stack_dust => masked_mean(c, :STACK_DUST, m),
            :fluoride_limit => design.stack_fluoride_limit_mg_per_nm3,
            :dust_limit => design.stack_dust_limit_mg_per_nm3,
            :f_released_t => f_released, :process_co2_t => process_co2_t,
            :scrubber_ph => masked_mean(c, :SCRUBBER_PH, m)),
        :carbon => Dict{Symbol,Any}(:scope_1_t => scope_1, :scope_2_t => scope_2,
            :scope_3_t => scope_3, :total_t => scope_1 + scope_2 + scope_3,
            :intensity_kg_per_p2o5 => p2o5_fed > 0 ? 1000.0 * (scope_1 + scope_2) / p2o5_fed : NaN,
            :factors => Dict{Symbol,Any}(
                :grid_electricity => EMISSION_FACTORS.grid_electricity_kg_per_kwh,
                :natural_gas => EMISSION_FACTORS.natural_gas_kg_per_gj,
                :sulphuric_acid => EMISSION_FACTORS.sulphuric_acid_kg_per_t,
                :ammonia => EMISSION_FACTORS.ammonia_kg_per_t),
            :basis => :ghg_protocol),
        :cost => Dict{Symbol,Any}(:items => cost, :total_ksite => cost_total,
            :total => cost_total * 1000.0, :currency => design.site.currency,
            :per_t_product => per_t(cost_total * 1000.0, product_t),
            :per_t_p2o5 => per_t(cost_total * 1000.0, p2o5_fed),
            :revenue => revenue * 1000.0, :margin => (revenue - cost_total) * 1000.0,
            :margin_per_t => per_t((revenue - cost_total) * 1000.0, product_t)),
        :quality => quality, :targets => targets,
        :production => Dict{Symbol,Any}(:rom_t => masked_sum(c, :ROM_FEED, m),
            :product_t => product_t, :hours => hours, :target_hours => target_hours,
            :rate_utilisation_pct => 100.0 * hours / max(target_hours, 1),
            :design_p2o5_tph => design_p2o5_tph(design),
            :actual_p2o5_tph => per_t(p2o5_product, hours)),
    )
end

"""Water the evaporator had to remove to lift the acid to its measured grade."""
function evaporated_water(c::Campaign, m, p2o5_fed, strength)
    p2o5_acid = p2o5_fed
    x_in = masked_mean(c, :WEAK_ACID_P2O5, m) / 100.0
    x_out = max(strength / 100.0, 1.0e-6)
    (x_in <= 0 || x_out <= x_in) && return NaN
    return p2o5_acid * (1.0 / x_in - 1.0 / x_out)
end

## ---- the acid route --------------------------------------------------------------

"""Instrument that evidences one row of the acid specification."""
ACID_SPECS_TAG(spec::Symbol) = get(ACID_SPEC_TAGS, spec, :none)

"""A figure per tonne of P2O5, `NaN` when the acid production is zero."""
per_p2o5(value, p2o5) = p2o5 > 0 ? value / p2o5 : NaN

"""
    acid_quality(campaign, mask) -> Dict{Symbol,Any}

The merchant acid against its specification, row by row: what the instrument of each
row of [`ACID_SPECIFICATIONS`](@ref) recorded over the window, the limit, the margin
and the verdict. The status of the acid is the worst row, so a single failure is a
failed specification rather than an average that hides it.
"""
function acid_quality(c::Campaign, mask::AbstractVector{Bool})
    rows = Vector{Dict{Symbol,Any}}()
    values = Dict{Symbol,Float64}()
    for spec in sort(collect(keys(ACID_SPECIFICATIONS)); by = String)
        s = ACID_SPECIFICATIONS[spec]
        tag = ACID_SPECS_TAG(spec)
        value = tag === :none ? NaN : masked_mean(c, tag, mask)
        values[spec] = value
        push!(rows, Dict{Symbol,Any}(:spec => spec, :tag => tag, :value => value,
            :limit => s.limit, :unit => s.unit, :comparator => s.comparator,
            :margin_pct => target_margin(value, s.limit, s.comparator),
            :status => target_status(value, s.limit, s.comparator), :basis => s.basis))
    end
    statuses = [r[:status] for r in rows]
    status = :noncompliant in statuses ? :noncompliant :
             :at_risk in statuses ? :at_risk :
             all(==(:not_assessed), statuses) ? :not_assessed : :compliant
    failures = [r[:spec] for r in rows if r[:status] === :noncompliant]
    return Dict{Symbol,Any}(:values => values, :rows => rows, :failures => failures,
        :specification => ACID_SPECIFICATIONS, :status => status,
        :grade => acid_grade_of(get(values, :p2o5, 0.0)),
        :basis => "the merchant acid against the specification of the traded grade")
end

"""
    acid_evaluation(campaign, mask; design, ...) -> Dict{Symbol,Any}

The evaluation of the acid route as a product in its own right: the P2O5 balance from
the attack to the merchant acid, the yield of the filtration and of the concentration,
the specification of the grade, what a tonne of P2O5 costs as acid and what the acid
is worth. Every figure is read from the historian, so the acid evaluation cannot drift
away from the plant it describes.
"""
function acid_evaluation(c::Campaign, m; design::PlantDesign = c.design, rock_t::Real = 0.0,
    reagent_t::Real = 0.0, p2o5_fed::Real = 0.0, strength::Real = NaN, merchant_t::Real = 0.0,
    steam_t::Real = 0.0, sulphur_t::Real = 0.0, acid_t::Real = 0.0, water_m3::Real = 0.0,
    gypsum_t::Real = 0.0, gypsum_free_p2o5::Real = 0.0, hours::Integer = 0)
    ## the P2O5 that reaches the filters is what the acid plant can concentrate
    gypsum_loss = gypsum_t * gypsum_free_p2o5 / 100.0
    to_filters = max(p2o5_fed - gypsum_loss, 0.0)
    merchant_p2o5 = merchant_t * strength / 100.0
    share = to_filters > 0 ? clamp(merchant_p2o5 / to_filters, 0.0, 1.0) : 0.0
    merchant_h3po4 = merchant_p2o5 * H3PO4_PER_P2O5
    grade_h3po4 = merchant_t > 0 ? 100.0 * merchant_h3po4 / merchant_t : NaN
    ## the concentration step: the water the evaporators had to remove, and the economy
    weak_strength = masked_mean(c, :WEAK_ACID_P2O5, m)
    feed_m3 = masked_sum(c, :EVAP_FEED_FLOW, m)
    feed_t = feed_m3 * acid_density(weak_strength, masked_mean(c, :EVAP_TEMP, m))
    x_in = weak_strength / 100.0
    x_out = max(strength / 100.0, x_in + 1.0e-6)
    water_evaporated = feed_t * (1.0 - x_in / x_out)
    economy = steam_t > 0 ? water_evaporated / steam_t : NaN
    expected_merchant = design.acid_merchant_split * to_filters
    concentration_yield = expected_merchant > 0 ? 100.0 * merchant_p2o5 / expected_merchant : NaN
    ## the power the acid train carries: the blower of the plant and the evaporator set
    electricity = sulphur_t * ACID_POWER_KWH_PER_T_SULPHUR + feed_m3 * ACID_POWER_KWH_PER_M3_FEED
    ## the cost of a tonne of P2O5 as acid: the plant costs are the plant's, the feed is
    ## allocated to the acid route by the share of the P2O5 that leaves as merchant acid
    items = Dict{Symbol,Float64}(
        :rock => rock_t * ECONOMICS[:rock_per_t] * share,
        :reagents => reagent_t * ECONOMICS[:reagent_per_t] * share,
        :sulphur => sulphur_t * ECONOMICS[:sulphur_per_t] * share,
        :gypsum_disposal => gypsum_t * ECONOMICS[:gypsum_disposal_per_t] * share,
        :steam => steam_t * ECONOMICS[:steam_per_t],
        :electricity => electricity * ECONOMICS[:electricity_per_kwh],
        :water => (feed_m3 + 0.35 * masked_sum(c, :WASH_WATER_FLOW, m) * share) *
                  ECONOMICS[:process_water_per_m3])
    cost_total = sum(values(items)) / 1000.0      ## k of the site currency, like the KPI cost
    revenue = merchant_p2o5 * ECONOMICS[:merchant_acid_per_t_p2o5]
    ## the P2O5 that did not leave as merchant acid: the fertiliser route and the losses
    balance = [
        Dict{Symbol,Any}(:destination => :merchant_acid, :p2o5_t => merchant_p2o5,
            :share_pct => p2o5_fed > 0 ? 100.0 * merchant_p2o5 / p2o5_fed : NaN,
            :note => "to the acid storage, the grade the customer buys"),
        Dict{Symbol,Any}(:destination => :fertiliser_route,
            :p2o5_t => max(to_filters - merchant_p2o5, 0.0),
            :share_pct => p2o5_fed > 0 ? 100.0 * max(to_filters - merchant_p2o5, 0.0) / p2o5_fed : NaN,
            :note => "to the granulation line as concentrated acid"),
        Dict{Symbol,Any}(:destination => :gypsum_cake, :p2o5_t => gypsum_loss,
            :share_pct => p2o5_fed > 0 ? 100.0 * gypsum_loss / p2o5_fed : NaN,
            :note => "water-soluble P2O5 that left with the phosphogypsum"),
        Dict{Symbol,Any}(:destination => :unaccounted,
            :p2o5_t => max(p2o5_fed - merchant_p2o5 - max(to_filters - merchant_p2o5, 0.0) -
                           gypsum_loss, 0.0),
            :share_pct => p2o5_fed > 0 ? 100.0 * max(p2o5_fed - to_filters - gypsum_loss, 0.0) /
                                         p2o5_fed : NaN,
            :note => "sampling and rounding of the balance, targets zero")]
    steps = [
        Dict{Symbol,Any}(:step => :attack_and_filtration, :in_t => p2o5_fed, :out_t => to_filters,
            :loss_t => gypsum_loss, :yield_pct => p2o5_fed > 0 ? 100.0 * to_filters / p2o5_fed : NaN,
            :note => "the cake carries the free P2O5 out of the circuit"),
        Dict{Symbol,Any}(:step => :concentration, :in_t => to_filters,
            :out_t => design.acid_merchant_split * to_filters, :loss_t => 0.0,
            :yield_pct => concentration_yield,
            :note => "the closure of the evaporation against the registered merchant split"),
        Dict{Symbol,Any}(:step => :merchant_acid, :in_t => design.acid_merchant_split * to_filters,
            :out_t => merchant_p2o5, :loss_t => 0.0, :yield_pct => concentration_yield,
            :note => string("the ", round(100.0 * share, digits = 1), " % of the filtered P2O5 the storage tank receives"))]
    consumption = [
        Dict{Symbol,Any}(:metric => :rock, :value => per_p2o5(rock_t * share, merchant_p2o5),
            :unit => :t_ph, :basis => :per_p2o5_sold,
            :note => "t of rock per t P2O5 sold as acid, allocated by the acid share"),
        Dict{Symbol,Any}(:metric => :sulphuric_acid,
            :value => per_p2o5(acid_t * share, merchant_p2o5), :unit => :t_ph,
            :basis => :per_p2o5_sold, :note => "t of H2SO4 per t P2O5 sold as acid"),
        Dict{Symbol,Any}(:metric => :sulphur, :value => per_p2o5(sulphur_t * share, merchant_p2o5),
            :unit => :t_ph, :basis => :per_p2o5_sold,
            :note => "t of sulphur burnt per t P2O5 sold as acid"),
        Dict{Symbol,Any}(:metric => :steam, :value => per_p2o5(steam_t, to_filters),
            :unit => :t_ph, :basis => :per_p2o5_concentrated,
            :note => "t of steam per t P2O5 the evaporators concentrate, both products included"),
        Dict{Symbol,Any}(:metric => :electricity, :value => per_p2o5(electricity, to_filters),
            :unit => :kwh_per_t, :basis => :per_p2o5_concentrated,
            :note => "kWh per t P2O5 concentrated: blower of the acid plant and evaporator set"),
        Dict{Symbol,Any}(:metric => :water, :value => per_p2o5(feed_m3, to_filters),
            :unit => :m3_ph, :basis => :per_p2o5_concentrated,
            :note => "m3 of evaporator feed per t P2O5 concentrated"),
        Dict{Symbol,Any}(:metric => :thermal_energy, :value => per_p2o5(steam_t * 2.769, to_filters),
            :unit => :gj_per_t, :basis => :per_p2o5_concentrated,
            :note => "GJ of steam per t P2O5 concentrated"),
        Dict{Symbol,Any}(:metric => :gypsum, :value => per_p2o5(gypsum_t * share, merchant_p2o5),
            :unit => :t_ph, :basis => :per_p2o5_sold, :note => "t of phosphogypsum per t P2O5")]
    quality = acid_quality(c, m)
    cost_rows = [Dict{Symbol,Any}(:item => k, :value => v / 1000.0, :unit => :usd,
        :share_pct => cost_total > 0 ? 100.0 * (v / 1000.0) / cost_total : NaN,
        :per_t_p2o5 => per_p2o5(v / 1000.0, merchant_p2o5))
        for (k, v) in sort(collect(items); by = x -> -x[2])]
    filtration_yield = p2o5_fed > 0 ? 100.0 * to_filters / p2o5_fed : NaN
    targets = Dict{Symbol,Any}(m2 => target_row(m2, v) for (m2, v) in (
        :acid_p2o5_yield => filtration_yield, :acid_concentration_yield => concentration_yield,
        :acid_so4 => get(quality[:values], :so4, NaN), :acid_f => get(quality[:values], :f, NaN),
        :acid_solids => get(quality[:values], :solids, NaN), :acid_strength => strength,
        :acid_steam => per_p2o5(steam_t, to_filters),
        :acid_electricity => per_p2o5(electricity, to_filters),
        :acid_cost => per_p2o5(cost_total * 1000.0, merchant_p2o5)))
    acid_statuses = [r[:status] for r in values(targets)]
    status = quality[:status] === :noncompliant || :noncompliant in acid_statuses ? :noncompliant :
             quality[:status] === :at_risk || :at_risk in acid_statuses ? :at_risk : :compliant
    summary = Dict{Symbol,Any}(
        :merchant_kt => merchant_t / 1000.0, :merchant_p2o5_kt => merchant_p2o5 / 1000.0,
        :merchant_h3po4_kt => merchant_h3po4 / 1000.0,
        :grade_p2o5 => strength, :grade_h3po4 => grade_h3po4,
        :grade => acid_grade_of(strength), :share_of_filters_pct => 100.0 * share,
        :filtration_yield_pct => filtration_yield,
        :concentration_yield_pct => concentration_yield,
        :water_evaporated_t => water_evaporated, :economy => economy,
        :steam_per_p2o5 => per_p2o5(steam_t, to_filters),
        :electricity_per_p2o5 => per_p2o5(electricity, to_filters),
        :water_per_p2o5 => per_p2o5(feed_m3, to_filters),
        :thermal_gj_per_p2o5 => per_p2o5(steam_t * 2.769, to_filters),
        :cost_per_t_p2o5 => per_p2o5(cost_total * 1000.0, merchant_p2o5),
        :cost_per_t_acid => merchant_t > 0 ? cost_total * 1000.0 / merchant_t : NaN,
        :margin_per_t_p2o5 => per_p2o5(revenue - cost_total * 1000.0, merchant_p2o5),
        :revenue_per_t_p2o5 => ECONOMICS[:merchant_acid_per_t_p2o5],
        :quality_status => quality[:status], :quality_failures => quality[:failures],
        :hours => hours, :status => status)
    return Dict{Symbol,Any}(
        :balance => balance, :steps => steps, :consumption => consumption,
        :quality => quality, :targets => targets,
        :cost => Dict{Symbol,Any}(:items => items, :rows => cost_rows,
            :total => cost_total * 1000.0, :currency => design.site.currency,
            :allocation_pct => 100.0 * share, :revenue => revenue * 1000.0,
            :margin => revenue - cost_total * 1000.0,
            :per_t_p2o5 => per_p2o5(cost_total * 1000.0, merchant_p2o5),
            :per_t_acid => merchant_t > 0 ? cost_total * 1000.0 / merchant_t : NaN),
        :merchant => Dict{Symbol,Any}(:acid_t => merchant_t, :acid_kt => merchant_t / 1000.0,
            :p2o5_t => merchant_p2o5, :h3po4_t => merchant_h3po4,
            :grade_p2o5 => strength, :grade_h3po4 => grade_h3po4,
            :grade => acid_grade_of(strength), :filtration_yield_pct => filtration_yield,
            :concentration_yield_pct => concentration_yield,
            :water_evaporated_t => water_evaporated, :economy => economy,
            :electricity_kwh => electricity, :to_filters_t => to_filters,
            :gypsum_loss_t => gypsum_loss),
        :summary => summary, :status => status,
        :basis => "the historian rolled up over the operating intervals, read as the acid route")
end

"""The targets of a bundle as the rows of the register table, sorted by metric."""
function target_table(kpi::Dict{Symbol,Any})
    rows = [r for (_, r) in kpi[:targets]]
    return sort(rows; by = x -> String(x[:metric]))
end

"""Counts of the target register by status."""
function target_counts(kpi::Dict{Symbol,Any})
    counts = Dict{Symbol,Int}(s => 0 for s in STATUSES)
    for (_, r) in kpi[:targets]
        counts[r[:status]] = get(counts, r[:status], 0) + 1
    end
    return counts
end

"""Symbol-keyed summary of a KPI bundle, the payload the pipeline writes to JSON."""
function kpi_summary(kpi::Dict{Symbol,Any})
    return Dict{Symbol,Any}(:site => kpi[:site][:name], :product => kpi[:site][:product],
        :period => kpi[:period], :production => kpi[:production], :ore => kpi[:ore],
        :beneficiation => kpi[:beneficiation], :attack => kpi[:attack],
        :filtration => kpi[:filtration], :evaporation => kpi[:evaporation],
        :granulation => kpi[:granulation], :product_quality => kpi[:product],
        :energy => kpi[:energy], :water => kpi[:water], :emissions => kpi[:emissions],
        :carbon => kpi[:carbon], :cost => kpi[:cost][:items],
        :cost_total => kpi[:cost][:total], :quality => kpi[:quality][:completeness_pct],
        :targets => target_counts(kpi))
end

"""Section cards of the KPI bundle: one row per area, for the report cards."""
function area_cards(kpi::Dict{Symbol,Any})
    cards = NamedTuple[]
    push!(cards, (; label = "Ore processed", value = fmt_value(kpi[:ore][:rom_t] / 1000.0),
        unit = "kt", status = nothing,
        note = string(fmt_value(kpi[:ore][:feed_grade]), " % P2O5 feed")))
    push!(cards, (; label = "Concentrate", value = fmt_value(kpi[:ore][:concentrate_t] / 1000.0),
        unit = "kt", status = nothing,
        note = string(fmt_value(kpi[:ore][:concentrate_grade]), " % P2O5, recovery ",
            fmt_value(kpi[:beneficiation][:recovery_pct], digits = 1), " %")))
    push!(cards, (; label = "P2O5 to attack", value = fmt_value(kpi[:attack][:p2o5_fed] / 1000.0),
        unit = "kt", status = target_status(kpi[:filtration][:water_soluble_pct], 2.0, :le),
        note = string("acid ", fmt_value(kpi[:attack][:acid_per_p2o5]), " t/t")))
    push!(cards, (; label = "Acid strength", value = fmt_value(kpi[:evaporation][:strength]),
        unit = "% P2O5", status = target_status(kpi[:evaporation][:strength], 52.0, :ge),
        note = string("steam ", fmt_value(kpi[:evaporation][:steam_per_p2o5]), " t/t")))
    push!(cards, (; label = "Product", value = fmt_value(kpi[:product][:tonnes] / 1000.0),
        unit = "kt", status = target_status(kpi[:granulation][:moisture], 2.0, :le),
        note = string(fmt_value(kpi[:granulation][:n]), " % N, ",
            fmt_value(kpi[:granulation][:wsp], digits = 1), " % WSP")))
    push!(cards, (; label = "P2O5 recovery", value = fmt_value(kpi[:product][:p2o5_recovery_pct]),
        unit = "%", status = target_status(kpi[:product][:p2o5_recovery_pct], 94.0, :ge),
        note = string("plant, mine to bag")))
    push!(cards, (; label = "Specific energy", value = fmt_value(kpi[:energy][:specific_gj_per_p2o5]),
        unit = "GJ/t P2O5", status = target_status(kpi[:energy][:specific_gj_per_p2o5], 12.5, :le),
        note = string(fmt_value(kpi[:energy][:electricity_per_p2o5], digits = 1), " kWh/t")))
    push!(cards, (; label = "Variable cost", value = fmt_value(kpi[:cost][:per_t_product]),
        unit = "USD/t", status = target_status(kpi[:cost][:per_t_product], 400.0, :le),
        note = string("margin ", fmt_value(kpi[:cost][:margin_per_t]), " USD/t")))
    push!(cards, (; label = "Carbon", value = fmt_value(kpi[:carbon][:intensity_kg_per_p2o5]),
        unit = "kgCO2e/t", status = target_status(kpi[:carbon][:intensity_kg_per_p2o5], 145.0, :le),
        note = string("scope 1+2, ", fmt_value(kpi[:carbon][:total_t], digits = 0), " t total")))
    push!(cards, (; label = "Historian", value = fmt_value(kpi[:quality][:completeness_pct]),
        unit = "% usable", status = kpi[:quality][:status],
        note = string(kpi[:quality][:defect_runs], " defect runs")))
    return cards
end








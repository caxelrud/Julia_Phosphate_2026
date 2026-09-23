# =============================================================================
# plantdata.jl -- the synthetic campaign: what the instruments recorded.
#
# The historian is not noise around a constant: it is produced by walking the
# flowsheet hour by hour with a mass balance that closes at every step, driven by
# a production schedule, an ore blend and a weather profile that are all seeded.
# The deviations the plant suffers (a fouled cooler, a blinded filter cloth, a
# worn mill liner) are injected on purpose and recorded in `deviations`, so the
# fault detector can be scored against a known truth.
# =============================================================================

"""
    Deviation

A deviation injected in the campaign: the `role` it affects, the `window` of
intervals it lasts, its `magnitude` and the `kind` of the effect (`:bias`,
`:drift`, `:gain`, `:noise`). Recorded so that the fault detector can be scored.
"""
struct Deviation
    id::Symbol
    role::Symbol
    from_hour::Int
    to_hour::Int
    kind::Symbol
    magnitude::Float64
    unit::Symbol
    note::String
end

"""`true` when the deviation is active during an interval index."""
is_active(d::Deviation, i::Integer) = d.from_hour <= i <= d.to_hour

"""Fraction of the way through the deviation window (0 at the start, 1 at the end)."""
function progress(d::Deviation, i::Integer)
    d.to_hour <= d.from_hour && return 1.0
    return clamp((i - d.from_hour) / (d.to_hour - d.from_hour), 0.0, 1.0)
end

"""Activation factor of a deviation at an interval: `bias` and `gain` step, `drift` ramps."""
function activation(d::Deviation, i::Integer)
    is_active(d, i) || return 0.0
    return d.kind === :drift ? progress(d, i) : 1.0
end

"""
    Campaign

One campaign of the plant: the historian (`book`), the design it ran under, the
production schedule, the deviations it suffered and the symbol-keyed metadata that
makes every number reproducible.
"""
struct Campaign
    book::SignalBook
    design::PlantDesign
    deviations::Vector{Deviation}
    schedule::Dict{Symbol,Any}
    meta::Dict{Symbol,Any}
end

Base.length(c::Campaign) = length(c.book)

"""Symbol-keyed summary of a campaign for the cover page of the report."""
function campaign_summary(c::Campaign)
    book = c.book
    return Dict{Symbol,Any}(
        :site => c.design.site.name, :product => c.design.product,
        :signals => length(book), :intervals => length(first(values(book.signals))),
        :from => get(book.context, :from, nothing), :to => get(book.context, :to, nothing),
        :days => get(c.meta, :days, 0), :seed => get(c.meta, :seed, 0),
        :bodies => join(string.(get(c.schedule, :bodies, Symbol[])), ", "),
        :ore => join([string(k, " ", round(100 * v, digits = 1), "%") for (k, v) in
                      sort(collect(last(c.schedule[:ore])); by = x -> String(x[1]))], ", "),
        :deviations => length(c.deviations), :coverage_pct => book_completeness(book),
        :generated_at => get(c.meta, :generated_at, ""))
end

## ---- schedules ----------------------------------------------------------------

"""
    production_profile(days; start, rng) -> (; frac, mode, planned_outage)

Hourly production fraction of the campaign: a weekly pattern (the mine and the
mills run seven days, the granulation line is trimmed at the weekend), a seasonal
summer derate on the evaporators, and three planned outages of three days.
"""
function production_profile(days::Integer; start::DateTime = campaign_start(),
    rng::AbstractRNG = MersenneTwister(1), outages::Integer = 3)
    n = 24 * days
    frac = fill(1.0, n)
    mode = fill(:production, n)
    ## the planned outages are spread over the year; a short campaign gets a single one
    window = 30:max(30, days - 10)
    outage_days = sort(rand(rng, window, days >= 45 ? outages : 1))
    for i in 1:n
        t = start + Hour(i - 1)
        h = Dates.hour(t)
        weekday = Dates.dayofweek(t)
        ## weekly trim: the dryer and the granulator run 6 days a week
        weekday >= 7 && (frac[i] *= 0.82)
        ## night shift is thinner on the mine side, thicker on the acid side
        frac[i] *= 0.97 + 0.05 * sin(2π * (h - 4) / 24)
        ## summer derate of the cooling-limited sections
        m = Dates.month(t)
        (m in (6, 7, 8)) && (frac[i] *= 0.96)
        d = Dates.dayofyear(t)
        if any(od -> od <= d <= od + 2, outage_days)
            frac[i] = 0.0
            mode[i] = :shutdown
        elseif any(od -> od == d - 1, outage_days)
            frac[i] = 0.35
            mode[i] = :startup
        end
    end
    return (frac = frac, mode = mode, outage_days = outage_days)
end

"""
    ore_schedule(days, bodies; rng) -> Vector{Dict{Symbol,Float64}}

Blend of ore bodies fed to the plant, constant within a week and stepped between
weeks: the mine delivers campaigns of a single body, and the mill blends two.
"""
function ore_schedule(days::Integer, bodies::Vector{Symbol} = [:khouribga, :boucraa, :gafsa];
    rng::AbstractRNG = MersenneTwister(2))
    schedule = Vector{Dict{Symbol,Float64}}(undef, days)
    current = _random_blend(bodies, rng)
    for d in 1:days
        if (d - 1) % 7 == 0 && d > 1 && rand(rng) < 0.35
            current = _random_blend(bodies, rng)
        end
        schedule[d] = copy(current)
    end
    return schedule
end

"""Two- or three-body blend of the available ore bodies, summing to one."""
function _random_blend(bodies::Vector{Symbol}, rng::AbstractRNG)
    k = min(length(bodies), rand(rng, 2:3))
    chosen = bodies[randperm(rng, length(bodies))[1:k]]
    w = rand(rng, k) .+ 0.6
    w ./= sum(w)
    return Dict{Symbol,Float64}(c => w[i] for (i, c) in enumerate(chosen))
end

"""Assay of the blend fed in one week, from the ore-body assays and the schedule."""
function blend_assay(schedule::Dict{Symbol,Float64})
    comps = [ore_body(k) for k in sort(collect(keys(schedule)); by = String)]
    weights = [schedule[k] for k in sort(collect(keys(schedule)); by = String)]
    return blend(comps, weights)
end

## ---- deviations the plant suffers ---------------------------------------------

"""
    default_deviations(days; seed) -> Vector{Deviation}

The deviations injected in a campaign: one per fault the detector is expected to
find, spread over the year in windows of a few days. Each entry names the `role`
of the variable it moves, so the detection can be scored role by role.
"""
function default_deviations(days::Integer = 365; seed::Integer = 20260101)
    rng = MersenneTwister(seed)
    specs = [
        (:cooling_fouling, :reactor_temperature, :drift, 6.2, :deg_c,
            "cooler fouling raises the attack temperature"),
        (:sulfate_deficit, :sulfate_ratio, :bias, -1.7, :wt_pct,
            "sulphuric acid starvation, free SO4 collapses"),
        (:grind_coarse, :grind_p80, :bias, 42.0, :um,
            "cyclone roping sends coarse slurry to flotation"),
        (:reagent_starvation, :concentrate_grade, :bias, -1.5, :wt_pct,
            "fatty-acid dose below the setpoint"),
        (:filter_cloth_blinding, :filtration_rate, :drift, -1.9, :t_per_m2_d,
            "blinded cloth drops the filter rate"),
        (:evaporator_fouling, :steam_flow, :drift, 13.5, :t_ph,
            "scale on the evaporator tubes costs steam"),
        (:acid_strength_loss, :acid_strength, :drift, -1.6, :wt_pct,
            "the same scale dilutes the merchant acid"),
        (:scrubber_breakthrough, :stack_fluoride, :bias, 2.4, :count,
            "scrubber pH excursion, fluorine to the stack"),
        (:mill_liner_wear, :mill_load, :drift, 430.0, :kw,
            "worn liners demand more power for the same grind"),
        (:pump_cavitation, :pump_vibration, :bias, 3.6, :count,
            "cavitating filtrate pump"),
        (:sparger_blockage, :product_n, :bias, -1.2, :wt_pct,
            "blocked ammonia sparger starves the product"),
        (:crusher_gap_drift, :oversize_pct, :bias, 6.5, :pct,
            "the oversize crusher gap has opened"),
        (:rock_grade_drift, :rock_grade, :drift, 1.3, :wt_pct,
            "analyser drift on the rock grade"),
        (:cyclone_roping, :slurry_density, :bias, 6.4, :wt_pct,
            "cyclone roping thickens the mill discharge"),
        (:ammonia_overfeed, :product_n, :bias, 1.1, :wt_pct,
            "ammonia overfeed after a controller retune"),
    ]
    n = 24 * days
    deviations = Deviation[]
    start = 30
    step = max(6, div(max(days - 60, 60), length(specs) + 1))
    for (k, (id, role, kind, magnitude, unit, note)) in enumerate(specs)
        d0 = start + (k - 1) * step + rand(rng, 0:3)
        d0 + 16 > days - 5 && (d0 = max(5, days - 25 - 16 * (length(specs) - k)))
        window = rand(rng, 7:16)
        push!(deviations, Deviation(id, role, 24 * d0 + 1, min(n, 24 * (d0 + window)), kind,
            magnitude, unit, note))
    end
    return deviations
end

"""Row per deviation for the table that documents what the campaign contains."""
deviation_table(deviations::AbstractVector) = [Dict{Symbol,Any}(
    :fault => d.id, :role => d.role, :kind => d.kind, :magnitude => d.magnitude,
    :unit => d.unit, :from_hour => d.from_hour, :to_hour => d.to_hour,
    :hours => d.to_hour - d.from_hour + 1, :note => d.note) for d in deviations]

"""
    initial_plant_state(d, assay) -> Dict{Symbol,Float64}

Starting state of the hour-by-hour model: one entry per instrument tag (the tag in
lower case, so `:MILL_POWER` is `:mill_power`) plus the bookkeeping of the section
holdups and of the production counters. It is a symbol-keyed dictionary, like
every other container of the package, so the stepping functions, the fault
detector and the report speak one vocabulary.

`missing_state_keys` proves that the register and the state agree, which is the
first test of the campaign model.
"""
function initial_plant_state(d::PlantDesign, assay::Composition)
    return Dict{Symbol,Float64}(
        # ore preparation and beneficiation
        :rom_feed => design_ore_tph(d), :crusher_power => 2.0 * d.ore_tph,
        :mill_power => d.mill_power_kw, :mill_sound_db => 88.0,
        :mill_feed_water => d.mill_water_m3ph, :cyclone_pressure => 1.15,
        :cyclone_p80 => d.grind_p80_um, :slurry_density => 38.0,
        # flotation
        :flot_feed_p2o5 => 100.0 * assay[:p2o5] * 0.78, :conc_p2o5 => 100.0 * d.flotation_grade,
        :tail_p2o5 => 3.9, :reagent_flow => d.ore_tph * d.reagent_kg_per_t,
        :froth_ph => 9.4, :froth_image_index => 0.55, :froth_bubble_px => 42.0,
        # attack
        :rock_feed => design_concentrate_tph(d), :rock_p2o5 => 100.0 * d.flotation_grade,
        :p2o5_feed_rate => d.flotation_grade * design_concentrate_tph(d),

        :h2so4_flow => STOICH.acid * design_p2o5_tph(d) * 1.02, :recycle_acid_flow => 640.0,
        :attack_temp => d.digestion_temperature_k - 273.15, :reactor_level => 74.0,
        :free_so4 => 2.6, :slurry_sg => 1.52,
        # filtration
        :filter_vacuum => 250.0, :filter_rate => 5.4, :weak_acid_p2o5 => 28.5,
        :gypsum_free_p2o5 => 0.65, :wash_water_flow => 195.0, :f_wash_water => 1.2,
        :gypsum_flow => 0.0,

        # acid plant and evaporation
        :sulphur_feed => STOICH.acid * design_p2o5_tph(d) / 3.06,
        :so2_conc => 11.0, :converter_temp => 420.0, :steam_flow => d.evaporator_steam_tph,
        :evap_feed_flow => 320.0, :evap_density => 1.52, :evap_temp => 92.0,
        :strong_acid_p2o5 => 100.0 * P2O5_MERCHANT_ACID, :evap_vacuum => 480.0,
        :merchant_acid_flow => 0.0,

        # granulation and finishing
        :ammonia_flow => AMMONIA_PER_P2O5_DAP * design_p2o5_tph(d), :melt_density => 1.62,
        :product_flow => 0.0,

        :granulator_torque => 62.0, :gran_bed_temp => 96.0,
        :recycle_ratio => granulator_recycle_ratio(d.melt_moisture, d.bed_moisture),
        :dryer_outlet_temp => 82.0, :dryer_fuel_flow => 112.0, :product_moisture => 1.75,
        :product_wsp => 88.5, :product_n => 18.1, :cooler_outlet_temp => 45.0,
        :oversize_pct => 11.0, :fines_pct => 22.0, :scrubber_ph => 6.4, :stack_dust => 18.0,
        :stack_f => 2.6,
        # utilities and environment
        :turbine_power => 11.4, :cooling_return_t => 38.5, :cooling_supply_t => 29.2,
        :process_water_flow => 420.0, :effluent_ph => 7.4, :pump_vibration => 2.4,
        # section holdups and production counters
        :h3po4_holdup => 11800.0, :h2so4_holdup => 860.0, :p2o5_fed => 0.0,
        :p2o5_conc => 0.0, :p2o5_attack => 0.0, :acid_produced => 0.0,
        :gypsum_produced => 0.0, :product_produced => 0.0, :steam_consumed => 0.0,
        :electricity_consumed => 0.0, :hours => 0.0,
    )
end

"""Instrument tags that have no entry in a state dictionary (must be empty)."""
missing_state_keys(st::AbstractDict) =
    [t for t in signal_tags() if !haskey(st, Symbol(lowercase(String(t))))]

"""Total modification of a role at one interval: the sum of the active deviations."""
function role_bias(deviations::AbstractVector, role::Symbol, i::Integer)
    total = 0.0
    for d in deviations
        d.role === role || continue
        total += activation(d, i) * d.magnitude
    end
    return total
end

"""Multiplicative measurement noise of a signal (a fraction of its value)."""
jitter(rng::AbstractRNG, sigma::Real) = 1.0 + sigma * randn(rng)

"""
    CampaignContext

What the stepping functions read while the campaign advances: the design, the
blend assay of the week, the injected deviations, the production profile and the
seeded generator.
"""
mutable struct CampaignContext
    design::PlantDesign
    assay::Composition
    deviations::Vector{Deviation}
    rng::MersenneTwister
    frac::Vector{Float64}
    mode::Vector{Symbol}
end

"""
    upgraded_assay(ore, p2o5_fraction) -> Composition

Assay of a concentrate of a given P2O5 grade obtained from an ore assay by
rejecting gangue in proportion to the grade lift — the screening assumption of the
beneficiation model, which keeps the balance of every other species closed.
"""
function upgraded_assay(ore::Composition, p2o5_fraction::Real)
    p = ore[:p2o5]
    p2o5_fraction >= p && return normalize_composition(ore)
    scale = (1.0 - p2o5_fraction) / max(1.0 - p, 1.0e-9)
    return Composition(Dict{Symbol,Float64}(
        s => (s === :p2o5 ? p2o5_fraction : ore[s] * scale) for s in SPECIES))
end


"""Two-product formula: tailings grade implied by feed grade, concentrate grade and recovery."""
function tailings_grade(feed::Real, concentrate::Real, recovery::Real)
    num = feed * (1.0 - recovery)
    den = 1.0 - recovery * feed / max(concentrate, 1.0e-9)
    return den <= 0 ? feed : num / den
end

"""
    step_ore!(st, ctx, i)

Ore preparation, grinding and flotation of one interval: the ROM feed drives the
crushers and the mill, Bond's law sets the grinding power for the target P80, and
the flotation recovery follows the reagent dose, the grind and the feed grade. The
concentrate grade is measured, the tailings grade is *derived* from the
two-product formula, so the flotation balance closes by construction.
Returns the concentrate rate and the concentrate assay.
"""
function step_ore!(st::Dict{Symbol,Float64}, ctx::CampaignContext, i::Integer)
    d, rng, dev = ctx.design, ctx.rng, ctx.deviations
    frac = ctx.frac[i]
    ## ROM feed, crushing and grinding
    st[:rom_feed] = max(0.0, 1.02 * design_ore_tph(d) * frac * jitter(rng, 0.012))
    target_p80 = clamp(d.grind_p80_um + role_bias(dev, :grind_p80, i), 70.0, 260.0)
    w_specific = bond_mill_power(d.bond_wi, d.grind_f80_um, target_p80, 1.0)
    st[:mill_power] = max(0.0, w_specific * st[:rom_feed] * jitter(rng, 0.012) +
                               role_bias(dev, :mill_load, i))
    st[:mill_sound_db] = clamp(74.0 + 0.0042 * st[:mill_power] + 1.6 * randn(rng), 74.0, 102.0)
    st[:crusher_power] = max(0.0, 2.1 * st[:rom_feed] * jitter(rng, 0.02) +
                                  role_bias(dev, :crusher_load, i))
    st[:mill_feed_water] = max(0.0, d.mill_water_m3ph * (0.55 + 0.45 * frac) * jitter(rng, 0.02))
    ## classification: pressure rises with tonnage, falls as the cut gets coarser
    st[:cyclone_p80] = clamp(target_p80 + 4.5 * randn(rng), 70.0, 280.0)
    st[:cyclone_pressure] = clamp(1.15 + 0.00085 * (st[:rom_feed] - d.ore_tph) -
                                  0.00035 * (st[:cyclone_p80] - d.grind_p80_um) + 0.018 * randn(rng),
        0.85, 1.55)
    st[:slurry_density] = clamp(38.0 + role_bias(dev, :slurry_density, i) + 0.45 * randn(rng),
        24.0, 52.0)
    ## flotation: recovery follows reagent dose, grind and feed grade
    st[:flot_feed_p2o5] = clamp(80.0 * ctx.assay[:p2o5] + 0.11 * randn(rng), 12.0, 34.0)
    dose = d.reagent_kg_per_t * (1.0 + 0.06 * randn(rng))
    st[:reagent_flow] = max(0.0, dose * st[:rom_feed] * (0.85 + 0.15 * frac))
    shortfall = max(0.0, d.reagent_kg_per_t - dose)
    recovery = 100.0 * d.flotation_recovery -
               9.0 * shortfall +
               0.55 * (st[:flot_feed_p2o5] - 24.5) -
               0.16 * (st[:cyclone_p80] - d.grind_p80_um) +
               0.9 * randn(rng)
    st[:flot_feed_p2o5] > 26.0 && (recovery += 0.6)
    ## a coarse grind and a barren feed also lose recovery to the tailings
    recovery = clamp(recovery, 55.0, 96.5)
    st[:conc_p2o5] = clamp(st[:flot_feed_p2o5] + 6.9 - 0.075 * (st[:cyclone_p80] - d.grind_p80_um) +
                           role_bias(dev, :concentrate_grade, i) + 0.16 * randn(rng), 20.0, 37.0)
    r = recovery / 100.0
    st[:tail_p2o5] = clamp(tailings_grade(st[:flot_feed_p2o5], st[:conc_p2o5], r), 0.5, 12.0)
    st[:froth_ph] = clamp(9.4 - 0.0022 * (d.reagent_kg_per_t - dose) * 1000.0 + 0.05 * randn(rng),
        8.2, 10.6)
    st[:froth_bubble_px] = clamp(42.0 + 0.62 * (st[:conc_p2o5] - d.flotation_grade * 100.0) -
                                 0.28 * (st[:reagent_flow] - d.ore_tph * d.reagent_kg_per_t) / 10.0 +
                                 1.8 * randn(rng), 6.0, 95.0)
    st[:froth_image_index] = clamp(0.55 + 0.028 * (st[:conc_p2o5] - 31.2) + 0.02 * randn(rng),
        0.0, 1.0)
    ## the two-product balance gives the concentrate rate
    concentrate_rate = st[:flot_feed_p2o5] <= 0 ? 0.0 :
                       st[:rom_feed] * r * st[:flot_feed_p2o5] / max(st[:conc_p2o5], 1.0e-9)
    return (rate = concentrate_rate, grade = st[:conc_p2o5], recovery = recovery,
        tailings = st[:tail_p2o5])
end

"""
    step_attack!(st, ctx, i, concentrate; dt = 1.0) -> (; rock, p2o5, gypsum, acid, ...)

Attack section of one interval. The dry rock rate follows the concentrate rate,
the sulphuric acid follows the stoichiometric demand of the concentrate assay, the
temperature relaxes towards a heat-balance target with a first-order lag, and the
digestion efficiency follows the temperature, the free sulphate and the grind. The
`gypsum` and `p2o5` returned are the rates the reaction produces, so the balance of
the reaction section closes exactly.
"""
function step_attack!(st::Dict{Symbol,Float64}, ctx::CampaignContext, i::Integer,
    concentrate; dt::Real = 1.0)
    d, rng, dev = ctx.design, ctx.rng, ctx.deviations
    frac = ctx.frac[i]
    ## the design concentrate rate is the reference of every load term of the section
    concentrate_reference = design_concentrate_tph(d)
    ## dry concentrate to the attack tanks (dryer and conveyor losses)
    rock = max(0.0, concentrate.rate * 0.985 * jitter(rng, 0.006))
    st[:rock_feed] = rock
    st[:rock_p2o5] = concentrate.grade
    assay = upgraded_assay(ctx.assay, concentrate.grade / 100.0)
    p2o5_rock = rock * assay[:p2o5]
    st[:p2o5_feed_rate] = p2o5_rock

    ## sulphuric acid: the stoichiometric demand of the assay plus the registered excess
    req = acid_requirement(rock, assay; excess = d.acid_excess)
    st[:h2so4_flow] = max(0.0, req.total * jitter(rng, 0.005))
    excess_actual = st[:h2so4_flow] / max(req.stoich + req.carbonate, 1.0e-9) - 1.0
    st[:recycle_acid_flow] = max(0.0, d.reactor_volume_m3 / 3.0 * (0.55 + 0.45 * frac) *
                                     jitter(rng, 0.02))
    ## free sulphate and the first-order temperature lag
    free_ss = 2.6 + 30.0 * (excess_actual - d.acid_excess) +
              0.14 * (st[:rock_p2o5] - 31.2)
    st[:free_so4] = clamp(st[:free_so4] + (free_ss - st[:free_so4]) * dt / 0.8, 0.2, 7.0)
    heat = HEAT_OF_ATTACK_KJ_PER_KG_P2O5 * p2o5_rock
    slurry = max(rock + st[:h2so4_flow] + 0.30 * st[:recycle_acid_flow], 1.0)
    t_ss = 62.0 + heat / (slurry * SLURRY_CP_KJ_PER_KG_K) * HEAT_RETENTION_SLURRY +
           0.35 * (st[:free_so4] - 2.6) +
           role_bias(dev, :reactor_temperature, i)
    st[:attack_temp] = clamp(st[:attack_temp] + (t_ss - st[:attack_temp]) * dt / 0.45 *
                             (1.0 + 0.15 * randn(rng)), 55.0, 95.0)
    ## digestion efficiency and the unreacted loss
    efficiency = clamp(0.985 + 0.0045 * (st[:attack_temp] - 78.5) -
                       0.0025 * (st[:free_so4] - 2.6) -
                       0.0006 * max(0.0, st[:cyclone_p80] - d.grind_p80_um), 0.88, 0.998)
    st[:slurry_sg] = clamp(1.52 + 0.004 * (st[:free_so4] - 2.6) +
                           0.0006 * (rock - concentrate_reference) + 0.003 * randn(rng),
        1.38, 1.68)
    level_ss = 74.0 + 0.09 * (rock - concentrate_reference) + 1.2 * (st[:free_so4] - 2.6)
    st[:reactor_level] = clamp(st[:reactor_level] + (level_ss - st[:reactor_level]) * dt / 2.5,
        45.0, 92.0)
    st[:h3po4_holdup] = clamp(st[:h3po4_holdup] +
                              (0.60 * d.reactor_volume_m3 * 1.45 - st[:h3po4_holdup]) * dt / 3.0,
        0.0, 1.0e5)
    st[:h2so4_holdup] = clamp(st[:h2so4_holdup] +
                              (st[:free_so4] * 0.006 * d.reactor_volume_m3 - st[:h2so4_holdup]) * dt / 0.6,
        0.0, 1.0e5)
    ## the reaction: P2O5 digested, acid consumed, gypsum produced
    p2o5_digested = p2o5_rock * efficiency
    gypsum = STOICH.gypsum * p2o5_digested + GYPSUM_PER_FREE_CAO * free_cao(assay, rock)
    st[:p2o5_attack] += p2o5_digested * dt
    return (; rock = rock, p2o5 = p2o5_digested, unreacted = p2o5_rock - p2o5_digested,
        gypsum = gypsum, acid = st[:h2so4_flow], assay = assay, excess = excess_actual)
end

"""
    step_filtration!(st, ctx, i, reaction; dt = 1.0) -> (; p2o5, free_loss, gypsum, ...)

Filtration section of one interval. The strength of the weak acid responds to the
wash-water ratio, the free sulphate and the rock rate as a linearised response
around the design point (the first-principles water balance lives in the
steady-state twin), the filter rate follows the vacuum and the cloth condition,
and the water-soluble loss follows the wash ratio and the rate.
"""
function step_filtration!(st::Dict{Symbol,Float64}, ctx::CampaignContext, i::Integer,
    reaction; dt::Real = 1.0)
    d, rng, dev = ctx.design, ctx.rng, ctx.deviations
    frac = ctx.frac[i]
    st[:filter_vacuum] = clamp(250.0 * (0.9 + 0.1 * frac) + 3.0 * randn(rng), 140.0, 340.0)
    st[:wash_water_flow] = max(0.0, d.filter_area_m2 * 0.61 * (0.75 + 0.25 * frac) *
                                    jitter(rng, 0.02))
    wash_ratio = st[:wash_water_flow] / max(reaction.p2o5, 1.0e-9)
    ## the design concentrate rate, the reference of the load terms below
    concentrate_reference = design_concentrate_tph(d)
    strength_ss = 100.0 * d.weak_acid_p2o5 -
                  0.021 * (st[:wash_water_flow] - 195.0) +
                  0.30 * (st[:free_so4] - 2.6) -
                  0.008 * (st[:rock_feed] - concentrate_reference)
    st[:weak_acid_p2o5] = clamp(st[:weak_acid_p2o5] +
                                (strength_ss - st[:weak_acid_p2o5]) * dt / 1.8 *
                                (1.0 + 0.05 * randn(rng)), 20.0, 35.0)
    rate_ss = 24.0 * reaction.p2o5 * (st[:filter_vacuum] / 250.0)^0.35 /
              max(d.filter_area_m2, 1.0)
    st[:filter_rate] = clamp(st[:filter_rate] +
                             (rate_ss + role_bias(dev, :filtration_rate, i) - st[:filter_rate]) *
                             dt / 0.6, 1.5, 9.5)
    free_ss = 100.0 * d.gypsum_free_p2o5 * (1.6 / max(wash_ratio, 0.4))^0.85 *
              (5.4 / max(st[:filter_rate], 1.0))^0.35
    st[:gypsum_free_p2o5] = clamp(0.85 * st[:gypsum_free_p2o5] + 0.15 * free_ss *
                                  (1.0 + 0.05 * randn(rng)), 0.1, 3.5)
    st[:f_wash_water] = clamp(1.2 + 0.55 * (st[:free_so4] - 2.6) + 0.05 * randn(rng), 0.0, 8.0)
    ## the water-soluble P2O5 loss is the free P2O5 carried out with the gypsum
    free_loss = reaction.gypsum * st[:gypsum_free_p2o5] / 100.0
    st[:gypsum_flow] = reaction.gypsum
    st[:gypsum_produced] += reaction.gypsum * dt

    return (; p2o5 = reaction.p2o5 - free_loss, free_loss = free_loss,
        gypsum = reaction.gypsum, strength = st[:weak_acid_p2o5],
        wash_ratio = wash_ratio, unreacted = reaction.unreacted)
end

"""
    step_acid_plant!(st, ctx, i; dt = 1.0) -> (; acid, steam_generated)

Sulphur burning, conversion and absorption of one interval: the sulphur feed
follows the acid the attack section demands, the SO2 concentration and the
converter temperature follow it, and the waste-heat boiler raises steam in
proportion to the sulphur burnt.
"""
function step_acid_plant!(st::Dict{Symbol,Float64}, ctx::CampaignContext, i::Integer;
    dt::Real = 1.0)
    d, rng = ctx.design, ctx.rng
    acid_demand = st[:h2so4_flow]
    st[:sulphur_feed] = max(0.0, acid_demand / 3.06 / max(d.acid_plant_conversion, 1.0e-6) *
                                 jitter(rng, 0.008))
    st[:so2_conc] = clamp(11.0 + 0.05 * (st[:sulphur_feed] - 58.0) / 10.0 + 0.05 * randn(rng),
        7.5, 13.5)
    st[:converter_temp] = clamp(420.0 + 3.2 * (st[:so2_conc] - 11.0) -
                                0.35 * (st[:cooling_supply_t] - 29.2) + 1.1 * randn(rng),
        378.0, 468.0)
    steam_generated = d.waste_heat_steam_tph * (st[:sulphur_feed] / 58.0)
    st[:steam_generated] = steam_generated
    return (; acid = acid_demand, steam_generated = steam_generated)
end

"""
    step_evaporation!(st, ctx, i, filtrate; dt = 1.0) -> (; acid, steam, merchant)

Evaporation of one interval: the water of the weak acid that has to leave to reach
merchant grade sets the steam demand through the registered economy of the set, and
the strength of the product acid follows the steam actually delivered and the
vacuum. The P2O5 that is not concentrated returns to the attack tanks as recycle
acid or leaves as merchant acid.
"""
function step_evaporation!(st::Dict{Symbol,Float64}, ctx::CampaignContext, i::Integer,
    filtrate; dt::Real = 1.0)
    d, rng, dev = ctx.design, ctx.rng, ctx.deviations
    frac = ctx.frac[i]
    p2o5_acid = filtrate.p2o5
    duty = evaporation_duty(p2o5_acid / max(filtrate.strength / 100.0, 1.0e-6),
        filtrate.strength / 100.0, P2O5_MERCHANT_ACID)
    st[:evap_feed_flow] = max(0.0, duty.feed / 1.163 * (0.85 + 0.15 * frac) * jitter(rng, 0.02))
    st[:evap_vacuum] = clamp(480.0 + 5.0 * randn(rng), 300.0, 620.0)
    economy = d.evaporator_economy * (1.0 - 0.004 * (st[:evap_vacuum] - 480.0) / 20.0)
    st[:steam_flow] = clamp(steam_for_evaporation(duty.water, economy) +
                            role_bias(dev, :steam_flow, i) + 0.6 * randn(rng), 20.0, 170.0)
    strength_ss = 100.0 * P2O5_MERCHANT_ACID -
                  0.09 * (st[:steam_flow] - d.evaporator_steam_tph) -
                  0.02 * (st[:evap_vacuum] - 480.0) +
                  role_bias(dev, :acid_strength, i)
    st[:strong_acid_p2o5] = clamp(st[:strong_acid_p2o5] +
                                  (strength_ss - st[:strong_acid_p2o5]) * dt / 2.2 +
                                  0.12 * randn(rng), 45.0, 56.0)
    st[:evap_density] = clamp(acid_density(st[:strong_acid_p2o5], st[:evap_temp]) +
                              0.004 * randn(rng), 1.30, 1.66)
    st[:evap_temp] = clamp(88.0 + 0.6 * (st[:steam_flow] / d.evaporator_steam_tph - 1.0) * 10.0 -
                           0.02 * (480.0 - st[:evap_vacuum]) + 0.4 * randn(rng), 76.0, 112.0)
    st[:acid_produced] += duty.product * dt
    st[:merchant_acid_flow] = 0.24 * duty.product
    st[:steam_consumed] += st[:steam_flow] * dt

    return (; acid = duty.product, steam = st[:steam_flow], merchant = 0.24 * duty.product,
        recycle = 0.76 * duty.product, strength = st[:strong_acid_p2o5])
end

"""
    step_granulation!(st, ctx, i, evaporation; dt = 1.0) -> (; product, p2o5, n)

Granulation section of one interval: the acid that the storage tank sends to the
sparger sets the ammonia demand through the ammoniation ratio, the product rate
follows the P2O5 balance at the grade of the product, and the nitrogen of the
product is computed from the *ammonia actually sparged*, so the nitrogen balance of
the section closes exactly.
"""
function step_granulation!(st::Dict{Symbol,Float64}, ctx::CampaignContext, i::Integer,
    evaporation; dt::Real = 1.0)
    d, rng, dev = ctx.design, ctx.rng, ctx.deviations
    frac = ctx.frac[i]
    p2o5_plant = 0.76 * evaporation.acid * (evaporation.strength / 100.0)
    ratio = d.product === :map ? AMMONIA_PER_P2O5_MAP : AMMONIA_PER_P2O5_DAP
    ammonia_required = ratio * p2o5_plant
    bias = role_bias(dev, :ammonia_flow, i)
    st[:ammonia_flow] = max(0.0, ammonia_required * (1.0 + bias / 100.0) * jitter(rng, 0.01))
    product_grade = d.product === :map ? 0.52 : 0.46
    product = p2o5_plant / product_grade
    st[:product_n] = clamp(100.0 * st[:ammonia_flow] * (MOLAR_MASSES.nh3 > 0 ? 14.006 / 17.031 : 0.0) /
                           max(product, 1.0e-9) + role_bias(dev, :product_n, i) + 0.04 * randn(rng),
        13.0, 21.0)
    st[:melt_density] = clamp(1.62 + 0.005 * (st[:product_n] - 18.1) + 0.002 * randn(rng),
        1.45, 1.78)
    recycle_ss = granulator_recycle_ratio(d.melt_moisture, d.bed_moisture) *
                 (1.0 + 0.02 * (st[:product_n] - 18.1))
    st[:recycle_ratio] = clamp(st[:recycle_ratio] + (recycle_ss - st[:recycle_ratio]) * dt / 1.5,
        0.8, 7.0)
    st[:granulator_torque] = clamp(62.0 + 6.5 * (st[:recycle_ratio] - 2.8) * (0.7 + 0.3 * frac) +
                                   0.5 * randn(rng), 32.0, 95.0)
    st[:gran_bed_temp] = clamp(96.0 + 1.4 * (st[:ammonia_flow] / max(ammonia_required, 1.0e-9) - 1.0) * 10.0 +
                               0.2 * (st[:melt_density] - 1.62) * 10.0 + 0.5 * randn(rng), 78.0, 118.0)
    st[:dryer_fuel_flow] = clamp(d.dryer_fuel_gj_per_t * product * (0.9 + 0.1 * frac) *
                                 jitter(rng, 0.02), 20.0, 220.0)
    st[:dryer_outlet_temp] = clamp(82.0 - 0.11 * (st[:product_moisture] - 1.75) * 10.0 +
                                   0.9 * randn(rng), 60.0, 100.0)
    st[:product_moisture] = clamp(1.75 - 0.075 * (st[:dryer_outlet_temp] - 82.0) +
                                  0.045 * randn(rng), 0.4, 4.2)
    st[:product_wsp] = clamp(88.5 + 0.5 * (st[:ammonia_flow] / max(ammonia_required, 1.0e-9) - 1.0) * 10.0 -
                             2.6 * (st[:product_moisture] - 1.75) + 0.2 * randn(rng), 74.0, 96.0)
    st[:cooler_outlet_temp] = clamp(45.0 - 0.25 * (st[:process_water_flow] / 420.0 - 1.0) * 4.0 +
                                    0.5 * randn(rng), 28.0, 68.0)
    st[:oversize_pct] = clamp(11.0 + role_bias(dev, :oversize_pct, i) -
                              1.1 * (st[:recycle_ratio] - 2.8) + 0.2 * randn(rng), 2.5, 24.0)
    st[:fines_pct] = clamp(22.0 + 1.5 * (st[:recycle_ratio] - 2.8) + 0.25 * randn(rng), 6.0, 38.0)
    st[:scrubber_ph] = clamp(6.4 + 0.25 * randn(rng) - 0.03 * (st[:stack_f] - 2.6), 4.0, 9.0)
    st[:stack_f] = clamp(2.6 + 3.6 * (6.4 - st[:scrubber_ph]) * 0.4 +
                         role_bias(dev, :stack_fluoride, i) + 0.12 * randn(rng), 0.15, 9.0)
    st[:stack_dust] = clamp(18.0 + 6.0 * (st[:fines_pct] - 22.0) / 10.0 +
                            0.7 * randn(rng), 3.0, 55.0)
    st[:product_produced] += product * dt
    st[:product_flow] = product
    st[:p2o5_conc] += p2o5_plant * dt

    return (; product = product, p2o5 = p2o5_plant, ammonia = st[:ammonia_flow],
        n = st[:product_n], grade = 100.0 * product_grade)
end

"""
    step_utilities!(st, ctx, i; dt = 1.0)

Utility headers of one interval: the turbine converts the high-pressure steam into
power and condensate, the cooling tower sets the supply and return temperatures,
and the water and effluent figures follow the load of the plant.
"""
function step_utilities!(st::Dict{Symbol,Float64}, ctx::CampaignContext, i::Integer;
    dt::Real = 1.0)
    d, rng = ctx.design, ctx.rng
    frac = ctx.frac[i]
    st[:turbine_power] = clamp(11.4 * (st[:steam_flow] / d.evaporator_steam_tph) *
                               (0.8 + 0.2 * frac) + 0.12 * randn(rng), 3.0, 20.0)
    st[:cooling_return_t] = clamp(38.5 + 0.09 * (st[:attack_temp] - 78.5) +
                                  0.35 * randn(rng), 28.0, 52.0)
    st[:cooling_supply_t] = clamp(29.2 + 0.04 * (st[:cooling_return_t] - 38.5) -
                                  0.25 * (d.cooling_cycles - 4.5) * 0.4 + 0.2 * randn(rng), 20.0, 42.0)
    st[:process_water_flow] = clamp(420.0 * (0.7 + 0.3 * frac) + 3.0 * randn(rng), 150.0, 640.0)
    st[:effluent_ph] = clamp(7.4 + 0.05 * (st[:scrubber_ph] - 6.4) + 0.04 * randn(rng), 5.6, 9.4)
    st[:pump_vibration] = clamp(2.4 + 0.5 * (st[:filter_rate] / 5.4) +
                                role_bias(ctx.deviations, :pump_vibration, i) + 0.09 * randn(rng),
        0.3, 12.0)
    st[:electricity_consumed] += ((st[:mill_power] + st[:crusher_power]) / 1000.0 +
                                  0.8 * st[:process_water_flow] / 420.0) * dt
    st[:hours] += dt
    return nothing
end

"""
    zero_plant!(st, ctx, i, dt)

One interval of a planned outage: every flow reads zero and every state relaxes
towards its standby value, which is what the historian of a stopped line looks
like. The interval is flagged `:standby` in the schedule, so the KPIs can leave it
out.
"""
function zero_plant!(st::Dict{Symbol,Float64}, ctx::CampaignContext, i::Integer, dt::Real)
    for t in signal_tags()
        s = SIGNAL_TAGS[t]
        key = Symbol(lowercase(String(t)))
        if s.kind === :flow
            st[key] = 0.0
        else
            target = s.low + 0.12 * (s.nominal - s.low)
            st[key] = st[key] + (target - st[key]) * dt / 5.0
        end
    end
    st[:hours] += dt
    return nothing
end

"""
    step_plant!(st, ctx, i; dt = 1.0)

One interval of the whole complex, in process order: ore, reaction, filtration,
acid plant, evaporation, granulation and the utility headers. Every section is
driven by the one before it, so the campaign is mass-consistent by construction;
during a planned outage the plant is stepped with `zero_plant!` instead.
"""
function step_plant!(st::Dict{Symbol,Float64}, ctx::CampaignContext, i::Integer;
    dt::Real = 1.0)
    ctx.frac[i] <= 0.0 && return zero_plant!(st, ctx, i, dt)
    concentrate = step_ore!(st, ctx, i)
    reaction = step_attack!(st, ctx, i, concentrate; dt = dt)
    filtrate = step_filtration!(st, ctx, i, reaction; dt = dt)
    step_acid_plant!(st, ctx, i; dt = dt)
    evaporation = step_evaporation!(st, ctx, i, filtrate; dt = dt)
    step_granulation!(st, ctx, i, evaporation; dt = dt)
    step_utilities!(st, ctx, i; dt = dt)
    return nothing
end

## ---- the data-quality defects the historian contains ---------------------------

"""
    defect_windows(tags, hours; seed, count, min_hours, max_hours) -> Dict{Symbol,Vector}

Windows of unusable data per signal: a stalled transmitter (`:faulty`), a gap
(`:missing`) or a drifting analyser (`:substituted`). Deterministic for a seed, so
the data-quality section of the report is reproducible.
"""
function defect_windows(tags::Vector{Symbol}, hours::Integer; seed::Integer = 20260101,
    count::Integer = 6, min_hours::Integer = 3, max_hours::Integer = 14)
    rng = MersenneTwister(seed + 7)
    out = Dict{Symbol,Vector{Any}}()
    kinds = (:faulty, :missing, :substituted)
    for tag in tags
        n = rand(rng, 0:count)
        windows = Any[]
        for _ in 1:n
            start = rand(rng, 24:(max(25, hours - 24)))
            span = rand(rng, min_hours:max_hours)
            push!(windows, (start = start, stop = min(hours, start + span - 1),
                quality = kinds[rand(rng, 1:length(kinds))]))
        end
        isempty(windows) || (out[tag] = windows)
    end
    return out
end

"""Apply a defect window to a signal buffer: `:missing` blanks, `:faulty` freezes."""
function apply_defect!(values::Vector{Float64}, qualities::Vector{Symbol}, w)
    w.quality === :missing || w.quality === :substituted || (values[w.start] = NaN)
    for i in w.start:w.stop
        if w.quality === :missing
            values[i] = NaN
        elseif w.quality === :faulty
            i == w.start || (values[i] = values[w.start])
        else
            values[i] = values[i] * 1.02 + 0.5
        end
        qualities[i] = w.quality
    end
    return nothing
end

"""
    generate_campaign(d = default_design(); days, seed, faults, start, ore, defects)

Run the plant model for `days` days and return the [`Campaign`](@ref): the
historian of every instrument tag, the schedule it followed and the deviations it
suffered.

Everything is a function of `seed`, so the readings, the KPIs, the fault findings
and the PDF of a report are reproducible from the seed alone. `defects` injects the
transmitter stalls, gaps and analyser drifts that the data-quality section of the
report accounts for.
"""
function generate_campaign(d::PlantDesign = default_design(); days::Integer = 365,
    seed::Integer = 20260101, faults::Bool = true, defects::Bool = true,
    start::DateTime = campaign_start(), ore::Vector{Symbol} = [:khouribga, :boucraa, :gafsa])
    rng = MersenneTwister(seed)
    stamps = hourly_stamps(days; start = start)
    profile = production_profile(days; start = start, rng = MersenneTwister(seed + 1))
    ore_sched = ore_schedule(days, ore; rng = MersenneTwister(seed + 2))
    deviations = faults ? default_deviations(days; seed = seed) : Deviation[]
    assay = blend_assay(ore_sched[1])
    ctx = CampaignContext(d, assay, deviations, rng, profile.frac, profile.mode)
    st = initial_plant_state(d, assay)
    tags = signal_tags()
    buffers = Dict{Symbol,Vector{Float64}}(t => zeros(length(stamps)) for t in tags)
    qualities = Dict{Symbol,Vector{Symbol}}(t => fill(:measured, length(stamps)) for t in tags)
    n = length(stamps)
    for i in 1:n
        if (i - 1) % 24 == 0
            week = min(length(ore_sched), div(i - 1, 24) + 1)
            ctx.assay = blend_assay(ore_sched[week])
        end
        step_plant!(st, ctx, i)
        for t in tags
            buffers[t][i] = st[Symbol(lowercase(String(t)))]
        end
    end
    if defects
        windows = defect_windows(tags, n; seed = seed)
        for (t, ws) in windows, w in ws
            apply_defect!(buffers[t], qualities[t], w)
        end
    end
    signals = Dict{Symbol,Series}()
    for t in tags
        s = SIGNAL_TAGS[t]
        signals[t] = Series(t, :hourly, s.unit, stamps, buffers[t], qualities[t],
            Dict{Symbol,Any}(:area => s.area, :stream => s.stream, :kind => s.kind,
                :nominal => s.nominal, :low => s.low, :high => s.high, :role => s.role,
                :description => to_string(t)))
    end
    book = SignalBook(signals, Dict{Symbol,Any}(:from => first(stamps), :to => last(stamps),
        :mode => profile.mode, :frac => profile.frac, :site => d.site.id))
    schedule = Dict{Symbol,Any}(:mode => profile.mode, :frac => profile.frac,
        :outages => profile.outage_days, :ore => ore_sched, :bodies => ore)
    meta = Dict{Symbol,Any}(:seed => seed, :days => days, :intervals => n,
        :generated_at => string(now()), :basis => :screening_plant_model,
        :note => "the historian is a seeded grey-box model of the registered design; " *
                 "the first-principles balances live in the digital twin")
    return Campaign(book, d, deviations, schedule, meta)
end

"""The series of one instrument tag of a campaign."""
signal(c::Campaign, tag::Symbol) = c.book[tag]

"""Values of one instrument tag, as recorded."""
values_of(c::Campaign, tag::Symbol) = c.book[tag].values

"""Mean of the first tag that watches a role (`:reactor_temperature`, ...)."""
function mean_of_role(c::Campaign, role::Symbol; mask = nothing)
    tags = signals_for(role)
    isempty(tags) && return NaN
    s = c.book[tags[1]]
    vals = s.values[good_intervals(s)]
    mask === nothing && return mean(vals)
    keep = (1:length(s))[good_intervals(s)][mask[good_intervals(s)]]
    isempty(keep) && return NaN
    return sum(s.values[keep]) / length(keep)
end

"""Intervals whose operating mode is one of `modes`."""
function mode_mask(c::Campaign, modes = (:production,))
    return BitVector(m in modes for m in c.schedule[:mode])
end

"""Fraction of the campaign spent in each operating mode."""
function mode_split(c::Campaign)
    out = Dict{Symbol,Any}()
    for m in OPERATING_MODES
        idx = findall(==(m), c.schedule[:mode])
        isempty(idx) && continue
        out[m] = Dict{Symbol,Any}(:hours => length(idx),
            :share_pct => 100.0 * length(idx) / length(c.schedule[:mode]))
    end
    return out
end

"""One row per signal for the historian table of the report."""
function campaign_table(c::Campaign)
    rows = Vector{Dict{Symbol,Any}}()
    for t in signal_tags()
        s = c.book[t]
        m = mask_nan(s)
        push!(rows, Dict{Symbol,Any}(:tag => t, :area => s.meta[:area], :unit => s.unit,
            :role => s.meta[:role], :nominal => s.meta[:nominal], :mean => m.mean,
            :min => m.min, :max => m.max, :completeness_pct => completeness(s),
            :nominal_pct => s.meta[:nominal] == 0 ? NaN : 100.0 * m.mean / s.meta[:nominal]))
    end
    return rows
end

"""Mean, minimum and maximum of the usable intervals of a series."""
function mask_nan(s::Series)
    idx = good_intervals(s)
    isempty(idx) && return (mean = NaN, min = NaN, max = NaN)
    v = s.values[idx]
    return (mean = sum(v) / length(v), min = minimum(v), max = maximum(v))
end

"""
    booked_value(campaign, tag, index) -> Float64

Reading of one tag at one interval, falling back to the nominal of the instrument
register when the historian has nothing usable there -- a stalled transmitter or a gap
reports `NaN`, and the model that renders an image or a sound from that reading has to
keep working anyway.
"""
function booked_value(c::Campaign, tag::Symbol, i::Integer)
    v = c.book[tag].values[i]
    return (isfinite(v) && v > 0.0) ? v : signal_spec(tag).nominal
end


"""Write a symbol-keyed table to CSV, one row per record."""
function write_table_csv(path::AbstractString, rows::AbstractVector, columns::Vector{Symbol})
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, join(string.(columns), ","))
        for r in rows
            println(io, join([_csv_cell(get(r, c, "")) for c in columns], ","))
        end
    end
    return path
end

"""CSV cell of a value: symbols as code, everything else as text."""
_csv_cell(v::Symbol) = code_string(v)
_csv_cell(v::Real) = isfinite(v) ? string(round(Float64(v), digits = 4)) : ""
_csv_cell(v::Union{DateTime,Date}) = string(v)
_csv_cell(v) = string(v)

"""
    write_readings_csv(campaign, path; interval = :daily)

Export the historian to CSV at one of the aggregation intervals of
[`INTERVALS`](@ref): the file the rest of the world reads, with one column per
instrument tag.
"""
function write_readings_csv(c::Campaign, path::AbstractString; interval::Symbol = :daily)
    tags = signal_tags()
    reducer_of(t) = SIGNAL_TAGS[t].kind === :flow ? total : mean_value
    books = if interval === :daily
        Dict(t => daily_series(c.book[t]; reducer = reducer_of(t)) for t in tags)
    elseif interval === :monthly
        Dict(t => monthly_series(c.book[t]; reducer = reducer_of(t)) for t in tags)
    elseif interval === :shift
        Dict(t => shift_series(c.book[t]; reducer = reducer_of(t)) for t in tags)
    else
        Dict(t => c.book[t] for t in tags)
    end
    stamps = books[tags[1]].stamps
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, join(["stamp"; string.(tags)], ","))
        for (i, stamp) in enumerate(stamps)
            row = [string(stamp)]
            for t in tags
                push!(row, string(get(books[t].values, i, "")))
            end
            println(io, join(row, ","))
        end
    end
    return path
end

"""
    export_campaign(campaign, dir) -> Vector{String}

Write the data deliverables of a campaign: the daily readings, the register, the
campaign summary and the deviation log.
"""
function export_campaign(c::Campaign, dir::AbstractString)
    files = String[]
    push!(files, write_readings_csv(c, joinpath(dir, "readings_daily.csv"); interval = :daily))
    push!(files, write_table_csv(joinpath(dir, "deviations.csv"), deviation_table(c.deviations),
        [:fault, :role, :kind, :magnitude, :unit, :from_hour, :to_hour, :hours, :note]))
    push!(files, write_table_csv(joinpath(dir, "signal_register.csv"), instrument_table(),
        [:tag, :unit, :area, :stream, :kind, :nominal, :low, :high, :role]))
    push!(files, write_table_csv(joinpath(dir, "campaign_signals.csv"), campaign_table(c),
        [:tag, :area, :unit, :role, :nominal, :mean, :min, :max, :completeness_pct, :nominal_pct]))
    return files
end













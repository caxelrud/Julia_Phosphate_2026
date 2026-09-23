# =============================================================================
# process.jl -- the plant: ore bodies, the registered design, and the flowsheet.
#
# The ore assays, the capacities and the flowsheet are the *configuration* of the
# whole application: the steady-state twin is built from the design, the campaign
# model draws its ore from `ORE_BODIES`, the optimiser blends them, and the
# battery limits printed in the report come from this file.
#
# The assays are representative published figures for the sedimentary and igneous
# phosphate rocks the industry treats; they are screening values, not the assay of
# any particular mine, and every one of them is a `Composition` so it can be
# blended, digested and diluted by the same arithmetic.
# =============================================================================

"""Assay of an ore body: a representative P2O5/CaO/gangue analysis as mass fractions."""
const ORE_BODIES = Dict{Symbol,Composition}(
    :khouribga => composition(p2o5 = 0.3090, cao = 0.5050, sio2 = 0.0300, fe2o3 = 0.0040,
        al2o3 = 0.0040, mgo = 0.0060, f = 0.0340, co2 = 0.0600, h2o = 0.0120, insol = 0.0200),
    :boucraa => composition(p2o5 = 0.3480, cao = 0.5100, sio2 = 0.0210, fe2o3 = 0.0030,
        al2o3 = 0.0030, mgo = 0.0040, f = 0.0360, co2 = 0.0450, h2o = 0.0100, insol = 0.0150),
    :gafsa => composition(p2o5 = 0.2900, cao = 0.4700, sio2 = 0.0550, fe2o3 = 0.0080,
        al2o3 = 0.0090, mgo = 0.0110, f = 0.0350, co2 = 0.0750, h2o = 0.0280, insol = 0.0250),
    :florida_pebble => composition(p2o5 = 0.2980, cao = 0.4550, sio2 = 0.0600, fe2o3 = 0.0130,
        al2o3 = 0.0120, mgo = 0.0050, f = 0.0330, co2 = 0.0650, h2o = 0.0200, insol = 0.0350),
    :jacobina => composition(p2o5 = 0.2980, cao = 0.4600, sio2 = 0.0500, fe2o3 = 0.0450,
        al2o3 = 0.0250, mgo = 0.0150, f = 0.0180, co2 = 0.0550, h2o = 0.0250, insol = 0.0300),
    :tapira => composition(p2o5 = 0.3340, cao = 0.4800, sio2 = 0.0400, fe2o3 = 0.0300,
        al2o3 = 0.0200, mgo = 0.0100, f = 0.0200, co2 = 0.0400, h2o = 0.0150, insol = 0.0200),
)

"""Ore bodies of the blend book, in a stable order."""
ore_bodies() = sort(collect(keys(ORE_BODIES)); by = String)

"""Assay of an ore body, by symbol."""
ore_body(id::Symbol) = haskey(ORE_BODIES, id) ? ORE_BODIES[id] :
                       throw(ArgumentError("unknown ore body $(code_string(id))"))

"""BPL grade (%) of every ore body, the table the geologist asks for first."""
function ore_grade_table()
    rows = Vector{Dict{Symbol,Any}}()
    for id in ore_bodies()
        c = ORE_BODIES[id]
        push!(rows, Dict{Symbol,Any}(:body => id, :p2o5 => p2o5_grade(c), :bpl => bpl_grade(c),
            :cao => grade(c, :cao), :sio2 => grade(c, :sio2), :fe2o3 => grade(c, :fe2o3),
            :al2o3 => grade(c, :al2o3), :mgo => grade(c, :mgo), :f => grade(c, :f),
            :co2 => grade(c, :co2), :h2o => grade(c, :h2o),
            :cao_p2o5 => ratio(c, :cao, :p2o5), :gangue => 100.0 * gangue(c)))
    end
    return rows
end

"""
    ORE_PRICES

Delivered cost of one tonne of ore body (`:usd_per_t`), the objective of the blend
optimiser. The two high-grade bodies carry a premium; the igneous bodies carry a
gangue penalty because they cost more acid and produce more gypsum.
"""
const ORE_PRICES = Dict{Symbol,Float64}(
    :khouribga => 82.0, :boucraa => 96.0, :gafsa => 74.0,
    :florida_pebble => 78.0, :jacobina => 70.0, :tapira => 88.0,
)

## ---- site and registered design -----------------------------------------------

"""
    Site

The plant the application is commissioned for: its identity, the currency of the
economic model and the capacity every normalised indicator is divided by.
"""
struct Site
    id::Symbol
    name::String
    country::String
    currency::Symbol
    capacity_t_p2o5_year::Float64
    design_hours_year::Float64
    meta::Dict{Symbol,Any}
end

"""The reference site of this repository: an integrated mine-to-DAP complex."""
default_site() = Site(:atlas_phosphate, "Atlas Phosphate Complex", "Morocco", :USD,
    1_200_000.0, 8000.0, Dict{Symbol,Any}(:feed_bodies => [:khouribga, :boucraa, :gafsa],
        :product => :dap, :tailings_facility => :gypsum_stack))

"""Price and cost register of the economic model, all in the site currency."""
const ECONOMICS = Dict{Symbol,Float64}(
    :rock_per_t => 82.0, :sulphur_per_t => 152.0, :ammonia_per_t => 486.0,
    :electricity_per_kwh => 0.085, :natural_gas_per_gj => 8.40, :steam_per_t => 22.0,
    :process_water_per_m3 => 1.15, :reagent_per_t => 1450.0, :grinding_media_per_t => 2.10,
    :dap_per_t => 520.0, :map_per_t => 560.0, :merchant_acid_per_t_p2o5 => 905.0,
    :fluosilicic_per_t => 240.0, :gypsum_disposal_per_t => 3.60, :co2_per_t => 25.0,
    :maintenance_per_t => 6.50, :packaging_per_t => 4.20,
    :unscheduled_downtime_per_h => 6400.0, :labour_per_h => 480.0,
)


"""
    PlantDesign

The registered design of the plant: one named value per capacity and per operating
target of the route, from the ore feed to the bagged product. The twin, the
optimiser, the controller and the report all read the same structure, so changing
`ore_tph` here changes every artefact at once.
"""
Base.@kwdef struct PlantDesign
    site::Site = default_site()
    ore_body::Symbol = :khouribga
    ## ore preparation and beneficiation
    ore_tph::Float64 = 320.0
    rock_p2o5::Float64 = 0.290
    grind_f80_um::Float64 = 12000.0
    grind_p80_um::Float64 = 150.0
    bond_wi::Float64 = 12.8
    mill_power_kw::Float64 = 4200.0
    mill_water_m3ph::Float64 = 210.0
    desliming_loss::Float64 = 0.08
    ## flotation
    flotation_recovery::Float64 = 0.86
    flotation_grade::Float64 = 0.315
    rougher_volume_m3::Float64 = 420.0
    flotation_residence_min::Float64 = 18.0
    reagent_kg_per_t::Float64 = 0.95
    ## attack and filtration
    reactor_volume_m3::Float64 = 1400.0
    reactor_banks::Int = 4
    digestion_temperature_k::Float64 = 351.15
    digestion_time_h::Float64 = 4.5
    acid_excess::Float64 = 0.025
    attack_p2o5_mass_fraction::Float64 = 0.30
    weak_acid_p2o5::Float64 = P2O5_WEAK_ACID
    filter_area_m2::Float64 = 320.0
    filtration_recovery::Float64 = 0.975
    gypsum_free_p2o5::Float64 = 0.006
    wash_water_ratio::Float64 = 1.6
    ## acid plant and evaporation
    evaporator_economy::Float64 = 3.6
    evaporator_steam_tph::Float64 = 96.0
    acid_merchant_split::Float64 = 0.24
    acid_plant_capacity_tpd::Float64 = 3600.0
    acid_plant_conversion::Float64 = 0.997
    waste_heat_steam_tph::Float64 = 46.0
    ## granulation and finishing
    product::Symbol = :dap
    ammonia_tph::Float64 = 42.0
    melt_moisture::Float64 = 0.18
    bed_moisture::Float64 = 0.055
    product_tph::Float64 = 268.0
    dryer_fuel_gj_per_t::Float64 = 0.42
    dryer_fuel::Symbol = :natural_gas
    ## utilities and environment
    cooling_circulation_m3ph::Float64 = 9800.0
    cooling_range_k::Float64 = 9.0
    cooling_cycles::Float64 = 4.5
    turbine_isentropic_efficiency::Float64 = 0.78
    stack_fluoride_limit_mg_per_nm3::Float64 = 5.0
    stack_dust_limit_mg_per_nm3::Float64 = 30.0
    ## data
    meta::Dict{Symbol,Any} = Dict{Symbol,Any}(:revision => :A, :basis => :screening_design,
        :note => "capacities and targets are representative screening values")
end

"""The design the repository ships with: 1.2 Mt/a of P2O5, DAP as the product."""
default_design() = PlantDesign()

"""Tonne of P2O5 per hour at the design rate, the denominator of every specific figure."""
design_p2o5_tph(d::PlantDesign = default_design()) =
    d.site.capacity_t_p2o5_year / d.site.design_hours_year

"""Ore per hour implied by the design grade and the target acid production."""
design_ore_tph(d::PlantDesign = default_design()) =
    design_p2o5_tph(d) / max(d.rock_p2o5 * d.flotation_recovery, 1.0e-6)

"""
Concentrate per hour the design implies: the two-product balance of the flotation
circuit, at the recovery and the concentrate grade of the register. This is the feed of
the attack section, and it is the reference the load terms of the correlations use.
"""
design_concentrate_tph(d::PlantDesign = default_design()) =
    design_ore_tph(d) * d.rock_p2o5 * d.flotation_recovery / max(d.flotation_grade, 1.0e-6)

"""Symbol-keyed summary of the design, the table printed on the cover page."""
function design_summary(d::PlantDesign = default_design())
    return Dict{Symbol,Any}(
        :site => d.site.name, :country => d.site.country, :currency => d.site.currency,
        :product => d.product, :capacity_t_p2o5_year => d.site.capacity_t_p2o5_year,
        :design_hours_year => d.site.design_hours_year,
        :design_p2o5_tph => design_p2o5_tph(d), :design_ore_tph => design_ore_tph(d),
        :ore_body => d.ore_body, :rock_p2o5 => 100.0 * d.rock_p2o5,
        :grind_p80_um => d.grind_p80_um, :flotation_recovery => 100.0 * d.flotation_recovery,
        :digestion_temperature_k => d.digestion_temperature_k,
        :weak_acid_p2o5 => 100.0 * d.weak_acid_p2o5,
        :acid_plant_capacity_tpd => d.acid_plant_capacity_tpd,
        :product_tph => d.product_tph, :revision => get(d.meta, :revision, :A))
end

## ---- the flowsheet ------------------------------------------------------------

"""
    Unit

One unit operation of the flowsheet: its tag, its area, the equipment it is built
on, its `kind` (which selects the model), the streams it takes and produces, and
its registered capacity.
"""
struct Unit
    id::Symbol
    area::Symbol
    equipment::Symbol
    kind::Symbol
    feeds::Vector{Symbol}
    products::Vector{Symbol}
    capacity::Float64
    unit::Symbol
    meta::Dict{Symbol,Any}
end

"""
    Flowsheet

The ordered list of [`Unit`](@ref)s of the plant plus an index by tag, so the
route can be walked forwards (`downstream`) and backwards (`upstream`).
"""
struct Flowsheet
    units::Dict{Symbol,Unit}
    order::Vector{Symbol}
end

Base.length(f::Flowsheet) = length(f.order)
Base.getindex(f::Flowsheet, id::Symbol) = f.units[id]
Base.haskey(f::Flowsheet, id::Symbol) = haskey(f.units, id)
Base.iterate(f::Flowsheet, args...) = iterate((f[i] for i in f.order), args...)

"""Unit tags of the flowsheet, in process order."""
unit_ids(f::Flowsheet) = copy(f.order)

"""Units of one area, in process order."""
units_of(f::Flowsheet, area::Symbol) = [f[i] for i in f.order if f[i].area === area]

"""`true` when a stream is produced by the unit (it is one of its products)."""
is_product(f::Flowsheet, id::Symbol, stream::Symbol) = stream in f[id].products

"""`true` when a stream is consumed by the unit (it is one of its feeds)."""
is_feed(f::Flowsheet, id::Symbol, stream::Symbol) = stream in f[id].feeds

"""Units that consume one of the products of `id` (the forward neighbours)."""
function downstream(f::Flowsheet, id::Symbol)
    outs = f[id].products
    return [j for j in f.order if j != id && any(s -> s in f[j].feeds, outs)]
end

"""Units that feed one of the inputs of `id` (the backward neighbours)."""
function upstream(f::Flowsheet, id::Symbol)
    ins = f[id].feeds
    return [j for j in f.order if j != id && any(s -> s in f[j].products, ins)]
end

"""Producer unit of a stream, and `:none` when the stream is a battery-limit feed."""
function producer_of(f::Flowsheet, stream::Symbol)
    for id in f.order
        stream in f[id].products && return id
    end
    return :none
end

"""Consumers of a stream, in process order."""
consumers_of(f::Flowsheet, stream::Symbol) = [id for id in f.order if stream in f[id].feeds]

"""Row per unit for the flowsheet table of the report."""
function flowsheet_table(f::Flowsheet)
    rows = Vector{Dict{Symbol,Any}}()
    for id in f.order
        u = f[id]
        push!(rows, Dict{Symbol,Any}(:unit => id, :area => u.area, :equipment => u.equipment,
            :kind => u.kind, :feeds => join(code_string.(u.feeds), ", "),
            :products => join(code_string.(u.products), ", "), :capacity => u.capacity,
            :unit_of_measure => u.unit))
    end
    return rows
end

"""Stream-by-stream register: producer, consumers and phase of every stream."""
function stream_balance(f::Flowsheet)
    rows = Vector{Dict{Symbol,Any}}()
    for s in STREAMS
        p = producer_of(f, s)
        c = consumers_of(f, s)
        (p === :none && isempty(c)) && continue
        push!(rows, Dict{Symbol,Any}(:stream => s, :area => stream_area(s),
            :phase => stream_phase(s), :producer => p, :consumers => join(code_string.(c), ", "),
            :consumer_count => length(c)))
    end
    return rows
end

"""Symbol-keyed summary of the flowsheet, the cover-page card of the twin."""
function flowsheet_summary(f::Flowsheet)
    by_area = Dict{Symbol,Any}()
    for a in AREAS
        us = units_of(f, a)
        isempty(us) && continue
        by_area[a] = Dict{Symbol,Any}(:units => length(us),
            :equipment => unique([u.equipment for u in us]),
            :streams => unique(vcat([u.products for u in us]...)))
    end
    return Dict{Symbol,Any}(:units => length(f), :areas => length(by_area),
        :streams => length(unique(vcat([f[i].feeds for i in f.order]...,
            [f[i].products for i in f.order]...))), :by_area => by_area)
end

## ---- the registered flowsheet of the complex ----------------------------------

"""Build one [`Unit`](@ref) from the compact form the builders below use."""
flow_unit(id::Symbol, area::Symbol, equipment::Symbol, kind::Symbol, feeds, products,
    capacity::Real, unit_symbol::Symbol; meta...) =
    Unit(id, area, equipment, kind, Symbol[feeds...], Symbol[products...], Float64(capacity),
        unit_symbol, Dict{Symbol,Any}(k => v for (k, v) in meta))

"""Ore preparation and flotation: ROM ore to a dried concentrate ready for attack."""
function beneficiation_units(d::PlantDesign)
    return Unit[
        flow_unit(:CRUSHING, :beneficiation, :jaw_crusher, :crush,
            [:rom_ore], [:crushed_rock], 1.4 * d.ore_tph, :t_ph,
            meta = (crusher_gap_mm = 150.0, availability = 0.94)),
        flow_unit(:GRINDING, :beneficiation, :rod_mill, :grind,
            [:crushed_rock, :dilution_water], [:mill_discharge], d.ore_tph, :t_ph,
            meta = (wi = d.bond_wi, f80_um = d.grind_f80_um, p80_um = d.grind_p80_um,
                power_kw = d.mill_power_kw)),
        flow_unit(:CYCLONE_PACK, :beneficiation, :hydrocyclone_pack, :classify,
            [:mill_discharge], [:cyclone_overflow, :cyclone_underflow], d.ore_tph, :t_ph,
            meta = (cut_size_um = 75.0, circulating_load = 2.6)),
        flow_unit(:DESLIMING, :beneficiation, :desliming_cyclone, :deslime,
            [:cyclone_overflow], [:flotation_feed, :deslimed_slime], d.ore_tph, :t_ph,
            meta = (slime_cut_um = 20.0, loss = d.desliming_loss)),
        flow_unit(:ROUGHER_FLOTATION, :flotation, :rougher_cells, :flotation,
            [:flotation_feed, :reagent_fatty_acid, :reagent_silicate],
            [:rougher_concentrate, :scavenger_tailings], d.ore_tph, :t_ph,
            meta = (volume_m3 = d.rougher_volume_m3, residence_min = d.flotation_residence_min,
                reagent_kg_per_t = d.reagent_kg_per_t)),
        flow_unit(:CLEANER_FLOTATION, :flotation, :cleaner_cells, :flotation,
            [:rougher_concentrate, :reagent_silicate],
            [:cleaner_concentrate, :scavenger_tailings], 0.5 * d.ore_tph, :t_ph,
            meta = (stage = :cleaner, dose_factor = 0.45)),
        flow_unit(:SCAVENGER_FLOTATION, :flotation, :scavenger_cells, :flotation,
            [:scavenger_tailings, :reagent_fatty_acid],
            [:final_concentrate, :flotation_tailings], 0.6 * d.ore_tph, :t_ph,
            meta = (stage = :scavenger, dose_factor = 0.8)),
        flow_unit(:CONCENTRATE_THICKENING, :flotation, :concentrate_thickener, :thicken,
            [:cleaner_concentrate, :final_concentrate], [:thickener_overflow, :concentrate_cake],
            0.45 * d.ore_tph, :t_ph,
            meta = (underflow_pct_solids = 62.0, flocculant_g_per_t = 28.0)),
        flow_unit(:CONCENTRATE_FILTRATION, :filtration, :concentrate_filter, :filter_dry,
            [:concentrate_cake, :process_water], [:dry_rock, :thickener_overflow],
            0.42 * d.ore_tph, :t_ph,
            meta = (cake_moisture = 0.09, dryer_outlet_moisture = 0.02,
                specific_fuel_gj_per_t = 0.09, fuel = :natural_gas)),
    ]
end

## ---- reaction, filtration and acid plant --------------------------------------

"""Attack, digestion, cooling and the filtration train: concentrate to weak acid."""
function reaction_units(d::PlantDesign)
    p2o5_tph = design_p2o5_tph(d)
    return Unit[
        flow_unit(:FLUORINE_SCRUBBING, :filtration, :fluorine_scrubber, :scrub,
            [:flash_vapour, :wash_water], [:fluosilicic_acid, :stack_gas], p2o5_tph, :t_ph,
            meta = (scrubbing_liquid = :water, recovery_f = 0.92,
                limit_mg_per_nm3 = d.stack_fluoride_limit_mg_per_nm3)),
        flow_unit(:ATTACK_TANKS, :attack, :attack_tank, :digest,
            [:dry_rock, :strong_sulphuric, :recycle_acid, :dilution_water], [:attack_slurry],
            p2o5_tph, :t_ph,
            meta = (volume_m3 = d.reactor_volume_m3, banks = d.reactor_banks,
                temperature_k = d.digestion_temperature_k, excess = d.acid_excess,
                p2o5_mass_fraction = d.attack_p2o5_mass_fraction)),
        flow_unit(:DIGESTER, :attack, :digester, :digest,
            [:attack_slurry], [:digester_slurry], p2o5_tph, :t_ph,
            meta = (residence_h = d.digestion_time_h, gypsum_supersaturation = 1.35,
                crystal_form = :dihydrate)),
        flow_unit(:FLASH_COOLING, :attack, :flash_cooler, :flash,
            [:digester_slurry, :cooling_water], [:filter_feed, :flash_vapour], p2o5_tph, :t_ph,
            meta = (flash_vacuum_mmwc = 120.0, outlet_temperature_k = 345.15)),
        flow_unit(:FILTRATION, :filtration, :belt_filter, :filter,
            [:filter_feed, :wash_water], [:filter_weak_acid, :gypsum_cake], p2o5_tph, :t_ph,
            meta = (area_m2 = d.filter_area_m2, vacuum_mmwc = 250.0,
                recovery = d.filtration_recovery, wash_ratio = d.wash_water_ratio,
                free_p2o5_in_cake = d.gypsum_free_p2o5)),
        flow_unit(:GYPSUM_DEWATERING, :filtration, :gypsum_belt, :dewater,
            [:gypsum_cake, :wash_water], [:process_water], p2o5_tph, :t_ph,
            meta = (cake_moisture = 0.24, destination = :gypsum_stack,
                free_p2o5_target = d.gypsum_free_p2o5)),
    ]
end

"""Sulphur burning, conversion, absorption and the steam raised by the acid plant."""
function acid_plant_units(d::PlantDesign)
    h2so4_tph = STOICH.acid * design_p2o5_tph(d)
    return Unit[
        flow_unit(:SULPHUR_MELTING, :acid_plant, :sulphur_melter, :melt,
            Symbol[], [:molten_sulphur], d.acid_plant_capacity_tpd / 24.0, :t_ph,
            meta = (melting_temperature_k = 408.15, solid_sulphur_from = :market)),
        flow_unit(:SULPHUR_BURNING, :acid_plant, :sulphur_burner, :burn,
            [:molten_sulphur, :burner_air, :condensate], [:so2_gas, :steam], h2so4_tph, :t_ph,
            meta = (furnace_temperature_k = 1373.15, so2_vol_pct = 11.0,
                steam_tph = d.waste_heat_steam_tph)),
        flow_unit(:SO2_CONVERSION, :acid_plant, :converter, :convert,
            [:so2_gas, :cooling_water], [:so3_gas], h2so4_tph, :t_ph,
            meta = (bed_temperatures_k = (693.15, 713.15, 703.15), conversion = d.acid_plant_conversion,
                catalyst = :vanadium_pentoxide)),
        flow_unit(:H2SO4_ABSORPTION, :acid_plant, :absorption_tower, :absorb,
            [:so3_gas, :absorption_water], [:strong_sulphuric], h2so4_tph, :t_ph,
            meta = (strength = 0.985, tower_temperature_k = 343.15, acid_temperature_k = 313.15)),
    ]
end

"""Evaporation of the weak acid to merchant grade and the condensate recovery."""
function evaporation_units(d::PlantDesign)
    p2o5_tph = design_p2o5_tph(d)
    return Unit[
        flow_unit(:EVAPORATION, :evaporation, :forced_circulation_evaporator, :evaporate,
            [:filter_weak_acid, :steam], [:concentrated_acid, :evaporator_condensate],
            p2o5_tph, :t_ph,
            meta = (economy = d.evaporator_economy, steam_tph = d.evaporator_steam_tph,
                weak_grade = d.weak_acid_p2o5, product_grade = P2O5_MERCHANT_ACID)),
        flow_unit(:ACID_STORAGE, :evaporation, :acid_storage_tank, :store,
            [:concentrated_acid], [:recycle_acid], p2o5_tph, :t_ph,
            meta = (recycle_fraction = 0.62, merchant_fraction = 0.38,
                storage_m3 = 12000.0)),
        flow_unit(:SURFACE_CONDENSING, :evaporation, :surface_condenser, :condense,
            [:evaporator_condensate, :cooling_water], [:process_water], p2o5_tph, :t_ph,
            meta = (conductivity_limit_us_cm = 40.0, recovery = 0.88)),
    ]
end

## ---- granulation, finishing, utilities and tailings ---------------------------

"""Ammoniation, drum granulation, drying, cooling, sizing, crushing and coating."""
function granulation_units(d::PlantDesign)
    melt = d.product === :map ? :map_melt : :dap_melt
    product = d.product === :map ? :product_map : :product_dap
    p2o5_tph = design_p2o5_tph(d)
    return Unit[
        flow_unit(:AMMONIATION, :granulation, :ammonia_sparger, :ammoniate,
            [:concentrated_acid, :ammonia], [melt, :granulator_offgas], p2o5_tph, :t_ph,
            meta = (product = d.product, ammonia_tph = d.ammonia_tph,
                ratio = d.product === :map ? AMMONIATION_RATIO.map : AMMONIATION_RATIO.dap,
                melt_moisture = d.melt_moisture)),
        flow_unit(:GRANULATION, :granulation, :rotary_granulator, :granulate,
            [melt, :undersize_recycle, :oversize_crush, :process_water],
            [:green_pellets, :granulator_offgas], d.product_tph, :t_ph,
            meta = (bed_moisture = d.bed_moisture, drum_rpm = 6.2,
                recycle_ratio = granulator_recycle_ratio(d.melt_moisture, d.bed_moisture))),
        flow_unit(:DRYING, :granulation, :dryer_drum, :dry,
            [:green_pellets, :natural_gas], [:dried_pellets, :dryer_offgas], d.product_tph, :t_ph,
            meta = (fuel = d.dryer_fuel, specific_fuel_gj_per_t = d.dryer_fuel_gj_per_t,
                outlet_moisture = 0.02, inlet_temperature_k = 623.15)),
        flow_unit(:COOLING, :granulation, :cooler_drum, :cool,
            [:dried_pellets, :compressed_air], [:cooled_pellets, :cooler_offgas],
            d.product_tph, :t_ph,
            meta = (outlet_temperature_k = 318.15, air_per_t = 380.0)),
        flow_unit(:SIZING, :granulation, :size_screens, :screen,
            [:cooled_pellets], [product, :oversize_crush, :undersize_recycle],
            d.product_tph, :t_ph,
            meta = (cut_low_mm = 2.0, cut_high_mm = 4.0, target_size_index = 78.0)),
        flow_unit(:OVERSIZE_CRUSHING, :granulation, :crusher_oversize, :crush,
            [:oversize_crush], [:undersize_recycle], 0.18 * d.product_tph, :t_ph,
            meta = (crusher_gap_mm = 2.5, recycle_fraction = 0.18)),
        flow_unit(:COATING, :granulation, :coating_drum, :coat,
            [product], [:coated_product], d.product_tph, :t_ph,
            meta = (coating = :oil_wax, dose_kg_per_t = 2.4)),
        flow_unit(:PRODUCT_SCRUBBING, :granulation, :product_scrubber, :scrub,
            [:granulator_offgas, :dryer_offgas, :cooler_offgas, :process_water],
            [:scrubber_liquor, :stack_gas], d.product_tph, :t_ph,
            meta = (stages = 3, ph_target = 6.5, dust_limit_mg_per_nm3 = d.stack_dust_limit_mg_per_nm3,
                fluoride_limit_mg_per_nm3 = d.stack_fluoride_limit_mg_per_nm3)),
    ]
end

"""Steam turbine, cooling tower and the tailings water recovery."""
function utility_units(d::PlantDesign)
    p2o5_tph = design_p2o5_tph(d)
    return Unit[
        flow_unit(:STEAM_TURBINE, :utilities, :steam_turbine, :power,
            [:steam], [:electricity, :condensate], d.mill_power_kw / 1000.0, :mw,
            meta = (isentropic_efficiency = d.turbine_isentropic_efficiency,
                inlet_bar = 42.0, condensing_bar = 0.12)),
        flow_unit(:COOLING_WATER, :utilities, :cooling_tower, :cool,
            [:cooling_water_return], [:cooling_water], d.cooling_circulation_m3ph, :m3_ph,
            meta = (range_k = d.cooling_range_k, cycles = d.cooling_cycles,
                evaporation_m3ph = cooling_tower_evaporation(d.cooling_circulation_m3ph,
                    d.cooling_range_k))),
        flow_unit(:TAILINGS_THICKENING, :tailings, :tailings_thickener, :thicken,
            [:flotation_tailings, :deslimed_slime], [:thickener_overflow],
            0.6 * d.ore_tph, :t_ph,
            meta = (underflow_destination = :tailings_dam, reclaimed_water = :process_water)),
        flow_unit(:WATER_RECOVERY, :tailings, :process_water_pump, :recover,
            [:thickener_overflow], [:process_water], p2o5_tph, :t_ph,
            meta = (recovery = 0.72, pond_return = :process_water)),
    ]
end

"""
    default_flowsheet(d = default_design()) -> Flowsheet

The registered flowsheet of the complex in process order: 34 unit operations from
the crusher to the coated product, built from the design so that a capacity change
travels through every model of the package.
"""
function default_flowsheet(d::PlantDesign = default_design())
    units = vcat(beneficiation_units(d), reaction_units(d), acid_plant_units(d),
        evaporation_units(d), granulation_units(d), utility_units(d))
    index = Dict{Symbol,Unit}(u.id => u for u in units)
    length(index) == length(units) || error("duplicate unit tag in the flowsheet")
    return Flowsheet(index, [u.id for u in units])
end

## ---- the instrument register --------------------------------------------------

"""
    SIGNAL_SPECS

The instrument register of the plant, one row per historian tag:

`(tag, unit, area, stream, kind, nominal, low, high, role)`

`kind` is `:flow` (a rate that is summed over an interval) or `:level` (a state
that is averaged), and `role` links the tag to the variable the fault detector and
the soft sensors watch.
"""
const SIGNAL_SPECS = (
    # ore preparation and beneficiation
    (:ROM_FEED, :t_ph, :beneficiation, :rom_ore, :flow, 320.0, 150.0, 400.0, :ore_feed),
    (:CRUSHER_POWER, :kw, :beneficiation, :crushed_rock, :level, 640.0, 380.0, 900.0, :crusher_load),
    (:MILL_POWER, :kw, :beneficiation, :mill_discharge, :level, 4200.0, 3200.0, 5200.0, :mill_load),
    (:MILL_SOUND_DB, :count, :beneficiation, :mill_discharge, :level, 88.0, 78.0, 96.0, :mill_charge),
    (:MILL_FEED_WATER, :m3_ph, :beneficiation, :mill_feed, :flow, 210.0, 140.0, 260.0, :mill_water),
    (:CYCLONE_PRESSURE, :bar, :beneficiation, :mill_discharge, :level, 1.15, 0.9, 1.45, :cyclone_pressure),
    (:CYCLONE_P80, :um, :beneficiation, :cyclone_overflow, :level, 148.0, 90.0, 240.0, :grind_p80),
    (:SLURRY_DENSITY, :wt_pct, :beneficiation, :cyclone_overflow, :level, 38.0, 28.0, 48.0, :slurry_density),
    # flotation
    (:FLOT_FEED_P2O5, :wt_pct, :flotation, :flotation_feed, :level, 24.5, 18.0, 30.0, :feed_grade),
    (:CONC_P2O5, :wt_pct, :flotation, :cleaner_concentrate, :level, 31.2, 27.0, 34.0, :concentrate_grade),
    (:TAIL_P2O5, :wt_pct, :flotation, :flotation_tailings, :level, 3.8, 1.5, 8.0, :tailings_grade),
    (:REAGENT_FLOW, :l_ph, :flotation, :reagent_fatty_acid, :flow, 300.0, 120.0, 480.0, :reagent_flow),
    (:FROTH_PH, :count, :flotation, :rougher_concentrate, :level, 9.4, 8.6, 10.2, :froth_ph),
    (:FROTH_IMAGE_INDEX, :count, :flotation, :rougher_concentrate, :level, 0.55, 0.0, 1.0, :froth_image),
    (:FROTH_BUBBLE_PX, :um, :flotation, :rougher_concentrate, :level, 42.0, 8.0, 90.0, :froth_bubble),
    # attack
    (:ROCK_FEED, :t_ph, :attack, :dry_rock, :flow, 150.0, 90.0, 190.0, :rock_feed),
    (:P2O5_FEED_RATE, :t_ph, :attack, :dry_rock, :flow, 46.8, 20.0, 60.0, :p2o5_rate),
    (:ROCK_P2O5, :wt_pct, :attack, :dry_rock, :level, 31.2, 27.0, 34.0, :rock_grade),

    (:H2SO4_FLOW, :t_ph, :attack, :strong_sulphuric, :flow, 174.0, 120.0, 210.0, :sulphuric_acid_flow),
    (:RECYCLE_ACID_FLOW, :m3_ph, :attack, :recycle_acid, :flow, 640.0, 420.0, 780.0, :recycle_acid_flow),
    (:ATTACK_TEMP, :deg_c, :attack, :attack_slurry, :level, 78.5, 68.0, 88.0, :reactor_temperature),
    (:REACTOR_LEVEL, :wt_pct, :attack, :attack_slurry, :level, 74.0, 55.0, 88.0, :reactor_level),
    (:FREE_SO4, :wt_pct, :attack, :attack_slurry, :level, 2.6, 0.5, 5.0, :sulfate_ratio),
    (:SLURRY_SG, :count, :attack, :digester_slurry, :level, 1.52, 1.42, 1.62, :slurry_sg),
    # filtration
    (:FILTER_VACUUM, :mmwc, :filtration, :gypsum_cake, :level, 250.0, 150.0, 330.0, :filter_vacuum),
    (:FILTER_RATE, :t_per_m2_d, :filtration, :filter_weak_acid, :level, 5.4, 3.0, 8.0, :filtration_rate),
    (:WEAK_ACID_P2O5, :wt_pct, :filtration, :filter_weak_acid, :level, 28.5, 25.0, 32.0, :acid_strength_weak),
    (:GYPSUM_FREE_P2O5, :wt_pct, :filtration, :gypsum_cake, :level, 0.65, 0.2, 1.6, :gypsum_free_p2o5),
    (:GYPSUM_FLOW, :t_ph, :filtration, :gypsum_cake, :flow, 210.0, 90.0, 280.0, :gypsum_rate),

    (:WASH_WATER_FLOW, :m3_ph, :filtration, :wash_water, :flow, 195.0, 120.0, 260.0, :wash_water_flow),
    (:F_WASH_WATER, :ppm, :filtration, :wash_water, :level, 1.2, 0.0, 6.0, :free_acid_wash),
    # acid plant and evaporation
    (:SULPHUR_FEED, :t_ph, :acid_plant, :molten_sulphur, :flow, 58.0, 30.0, 72.0, :sulphur_feed),
    (:SO2_CONC, :pct, :acid_plant, :so2_gas, :level, 11.0, 8.0, 13.0, :so2_concentration),
    (:CONVERTER_TEMP, :deg_c, :acid_plant, :so3_gas, :level, 420.0, 380.0, 460.0, :converter_temperature),
    (:STEAM_FLOW, :t_ph, :utilities, :steam, :flow, 96.0, 40.0, 130.0, :steam_flow),
    (:EVAP_FEED_FLOW, :m3_ph, :evaporation, :evaporator_feed, :flow, 320.0, 180.0, 400.0, :evaporator_feed_flow),
    (:EVAP_DENSITY, :count, :evaporation, :concentrated_acid, :level, 1.52, 1.35, 1.62, :evaporator_density),
    (:EVAP_TEMP, :deg_c, :evaporation, :concentrated_acid, :level, 92.0, 80.0, 105.0, :evaporator_temperature),
    (:STRONG_ACID_P2O5, :wt_pct, :evaporation, :concentrated_acid, :level, 52.4, 48.0, 55.0, :acid_strength),
    (:MERCHANT_ACID_FLOW, :t_ph, :evaporation, :concentrated_acid, :flow, 118.0, 30.0, 170.0, :merchant_acid_rate),

    ## the quality of the acid itself: what the specification of the merchant grade watches
    (:ACID_SO4, :wt_pct, :evaporation, :concentrated_acid, :level, 0.95, 0.20, 2.40, :acid_sulfate),
    (:ACID_F, :wt_pct, :evaporation, :concentrated_acid, :level, 0.32, 0.05, 0.90, :acid_fluoride),
    (:ACID_SOLIDS, :wt_pct, :evaporation, :concentrated_acid, :level, 0.24, 0.02, 0.80, :acid_solids),
    (:ACID_FE_AL, :wt_pct, :evaporation, :concentrated_acid, :level, 0.68, 0.15, 1.80, :acid_iron_aluminium),
    (:ACID_COLOUR, :count, :evaporation, :concentrated_acid, :level, 2.60, 0.50, 6.00, :acid_colour),

    (:EVAP_VACUUM, :mmwc, :evaporation, :evaporator_condensate, :level, 480.0, 300.0, 620.0, :evaporator_vacuum),
    # granulation and finishing
    (:AMMONIA_FLOW, :t_ph, :granulation, :ammonia, :flow, 42.0, 20.0, 55.0, :ammonia_flow),
    (:PRODUCT_FLOW, :t_ph, :granulation, :coated_product, :flow, 268.0, 90.0, 330.0, :product_rate),

    (:MELT_DENSITY, :count, :granulation, :dap_melt, :level, 1.62, 1.50, 1.72, :melt_density),
    (:GRANULATOR_TORQUE, :count, :granulation, :green_pellets, :level, 62.0, 40.0, 88.0, :granulator_torque),
    (:GRAN_BED_TEMP, :deg_c, :granulation, :green_pellets, :level, 96.0, 82.0, 112.0, :granulator_temperature),
    (:RECYCLE_RATIO, :count, :granulation, :undersize_recycle, :flow, 2.8, 1.2, 5.5, :recycle_ratio),
    (:DRYER_OUTLET_TEMP, :deg_c, :granulation, :dried_pellets, :level, 82.0, 65.0, 98.0, :dryer_temperature),
    (:DRYER_FUEL_FLOW, :gj, :granulation, :natural_gas, :flow, 112.0, 60.0, 150.0, :dryer_fuel_flow),
    (:PRODUCT_MOISTURE, :wt_pct, :granulation, :dried_pellets, :level, 1.75, 0.8, 3.2, :product_moisture),
    (:PRODUCT_WSP, :wt_pct, :granulation, :cooled_pellets, :level, 88.5, 78.0, 94.0, :product_wsp),
    (:PRODUCT_N, :wt_pct, :granulation, :coated_product, :level, 18.1, 16.0, 19.5, :product_n),
    (:COOLER_OUTLET_TEMP, :deg_c, :granulation, :cooled_pellets, :level, 45.0, 32.0, 62.0, :cooler_temperature),
    (:OVERSIZE_PCT, :pct, :granulation, :oversize_crush, :flow, 11.0, 4.0, 20.0, :oversize_pct),
    (:FINES_PCT, :pct, :granulation, :undersize_recycle, :flow, 22.0, 10.0, 34.0, :fines_pct),
    (:SCRUBBER_PH, :count, :granulation, :scrubber_liquor, :level, 6.4, 4.5, 8.5, :scrubber_ph),
    (:STACK_DUST, :count, :granulation, :stack_gas, :level, 18.0, 5.0, 45.0, :stack_dust),
    (:STACK_F, :count, :filtration, :stack_gas, :level, 2.6, 0.3, 6.0, :stack_fluoride),
    # utilities and environment
    (:TURBINE_POWER, :mw, :utilities, :electricity, :level, 11.4, 6.0, 16.0, :turbine_power),
    (:COOLING_RETURN_T, :deg_c, :utilities, :cooling_water_return, :level, 38.5, 30.0, 48.0, :cooling_return_temperature),
    (:COOLING_SUPPLY_T, :deg_c, :utilities, :cooling_water, :level, 29.2, 22.0, 38.0, :cooling_supply_temperature),
    (:PROCESS_WATER_FLOW, :m3_ph, :utilities, :process_water, :flow, 420.0, 200.0, 560.0, :process_water_flow),
    (:EFFLUENT_PH, :count, :tailings, :thickener_overflow, :level, 7.4, 6.0, 9.0, :effluent_ph),
    (:PUMP_VIBRATION, :count, :utilities, :process_water, :level, 2.4, 0.5, 9.0, :pump_vibration),
)

"""
    SIGNAL_TAGS

The instrument register as a symbol-keyed dictionary:
`tag => (unit, area, stream, kind, nominal, low, high, role)`.
"""
const SIGNAL_TAGS = Dict{Symbol,NamedTuple}(
    r[1] => (unit = r[2], area = r[3], stream = r[4], kind = r[5], nominal = r[6],
        low = r[7], high = r[8], role = r[9]) for r in SIGNAL_SPECS)

"""Every historian tag, in a stable order."""
signal_tags() = sort(collect(keys(SIGNAL_TAGS)); by = String)

"""Register entry of a tag; throws when the tag is not instrumented."""
function signal_spec(tag::Symbol)
    haskey(SIGNAL_TAGS, tag) ||
        throw(ArgumentError("unknown signal $(code_string(tag))"))
    return SIGNAL_TAGS[tag]
end

"""Tags of one area, in a stable order."""
signals_in(area::Symbol) =
    [t for t in signal_tags() if SIGNAL_TAGS[t].area === area]

"""Tags that watch one role (`:reactor_temperature`, `:acid_strength`, ...)."""
signals_for(role::Symbol) = [t for t in signal_tags() if SIGNAL_TAGS[t].role === role]

"""Row per tag for the instrument-register table of the report."""
function instrument_table()
    rows = Vector{Dict{Symbol,Any}}()
    for t in signal_tags()
        s = SIGNAL_TAGS[t]
        push!(rows, Dict{Symbol,Any}(:tag => t, :unit => s.unit, :area => s.area,
            :stream => s.stream, :kind => s.kind, :nominal => s.nominal, :low => s.low,
            :high => s.high, :role => s.role))
    end
    return rows
end








# =============================================================================
# symbols.jl -- the PHOSPHATE symbol vocabulary.
#
# Every categorical value in this system is a `Symbol`: the plant area, the
# chemical species, the process stream, the equipment tag, the unit of measure,
# the control loop, the KPI key, the fault id, the clause id, the soft-sensing
# modality, the operating mode, the status and the severity.
#
# Keeping the vocabulary in one place means that every `Dict`, `NamedTuple` and
# `struct` in the package speaks the same language, and a typo in a symbol is
# caught by `validate_vocabulary` instead of silently producing a `missing`.
# =============================================================================

"""
    AREAS

The nine areas of the phosphate route, in process order:

1. `:beneficiation` -- crushing, rod/ball milling, desliming
2. `:flotation`     -- rougher/cleaner/scavenger flotation, thickening
3. `:attack`        -- rock digestion with sulphuric acid (attack tanks)
4. `:filtration`    -- gypsum separation on belt/pan filters
5. `:evaporation`   -- acid concentration to merchant grade
6. `:acid_plant`    -- sulphur burning, conversion, absorption (H2SO4 supply)
7. `:granulation`   -- ammoniation, drum granulation, drying, cooling, sizing
8. `:utilities`     -- steam, cooling water, compressed air, power
9. `:tailings`      -- phosphogypsum stacking, water recovery, scrubbing
"""
const AREAS = (:beneficiation, :flotation, :attack, :filtration, :evaporation,
    :acid_plant, :granulation, :utilities, :tailings)

"""Canonical display name of every area (a `Symbol`, like everything else)."""
const AREA_NAMES = (
    beneficiation = :Beneficiation,
    flotation = :Flotation,
    attack = :Attack,
    filtration = :Filtration,
    evaporation = :Evaporation,
    acid_plant = :SulphuricAcidPlant,
    granulation = :Granulation,
    utilities = :Utilities,
    tailings = :Tailings,
)

"""
    SPECIES

The chemical species carried by the mass balance: the phosphate value
(`:p2o5`, `:bpl`), the gangue (`:cao`, `:sio2`, `:fe2o3`, `:al2o3`, `:mgo`),
the acid moieties (`:h2so4`, `:so4`, `:h3po4`), the nutrients (`:nh3`, `:k2o`),
the volatiles (`:f`, `:co2`, `:h2o`) and the residuals (`:insol`, `:cl`, `:na2o`).
"""
const SPECIES = (:p2o5, :bpl, :cao, :sio2, :fe2o3, :al2o3, :mgo, :f, :h2so4, :so4,
    :h3po4, :nh3, :k2o, :na2o, :co2, :cl, :h2o, :insol)

"""Display formula of every species, used by the tables and the printout."""
const SPECIES_FORMULAS = (
    p2o5 = :P2O5, bpl = :BPL, cao = :CaO, sio2 = :SiO2, fe2o3 = :Fe2O3,
    al2o3 = :Al2O3, mgo = :MgO, f = :F, h2so4 = :H2SO4, so4 = :SO4,
    h3po4 = :H3PO4, nh3 = :NH3, k2o = :K2O, na2o = :Na2O, co2 = :CO2,
    cl = :Cl, h2o = :H2O, insol = :Insol,
)

"""Role of each species in the balance (value, gangue, acid, nutrient, volatile)."""
const SPECIES_ROLES = (
    p2o5 = :value, bpl = :value, cao = :value, sio2 = :gangue, fe2o3 = :gangue,
    al2o3 = :gangue, mgo = :gangue, f = :volatile, h2so4 = :acid, so4 = :acid,
    h3po4 = :acid, nh3 = :nutrient, k2o = :nutrient, na2o = :gangue, co2 = :volatile,
    cl = :gangue, h2o = :volatile, insol = :gangue,
)

"""Species reported as an oxide-equivalent grade of the ore, the acid or the product."""
const VALUE_SPECIES = (:p2o5, :bpl)

"""Species whose release drives the emissions inventory (fluorine, acid, CO2)."""
const EMISSION_SPECIES = (:f, :p2o5, :so4, :co2)

## ---- process streams ---------------------------------------------------------

"""
    STREAMS

Every material stream of the flowsheet: ore and concentrate, flotation rejects,
the acid-plant gas train, reaction slurry, filter products, concentrated acid,
fertiliser product and the utilities.
"""
const STREAMS = (
    # ore preparation and beneficiation
    :rom_ore, :crushed_rock, :mill_feed, :mill_discharge, :cyclone_overflow,
    :cyclone_underflow, :deslimed_slime, :flotation_feed, :rougher_concentrate,
    :scavenger_tailings, :cleaner_concentrate, :final_concentrate, :flotation_tailings,
    :reagent_fatty_acid, :reagent_silicate, :thickener_overflow, :concentrate_cake,
    :dry_rock,
    # acid plant
    :molten_sulphur, :burner_air, :so2_gas, :so3_gas, :absorption_water, :strong_sulphuric,
    # attack and filtration
    :recycle_acid, :dilution_water, :attack_slurry, :digester_slurry, :flash_vapour,
    :filter_feed, :filter_weak_acid, :wash_water, :gypsum_cake, :fluosilicic_acid,
    # evaporation and merchant acid
    :evaporator_feed, :concentrated_acid, :evaporator_condensate, :cooling_water_return,
    # granulation and finishing
    :ammonia, :map_melt, :dap_melt, :granulator_offgas, :dryer_offgas, :cooler_offgas,
    :scrubber_liquor, :green_pellets, :dried_pellets, :cooled_pellets, :undersize_recycle,
    :oversize_crush, :coated_product, :product_dap, :product_map,
    # utilities and stacks
    :steam, :condensate, :natural_gas, :compressed_air, :electricity, :process_water,
    :cooling_water, :stack_gas,
)

"""Area each stream belongs to; used for grouping, colouring and reporting."""
const STREAM_AREA = Dict{Symbol,Symbol}(
    :rom_ore => :beneficiation, :crushed_rock => :beneficiation, :mill_feed => :beneficiation,
    :mill_discharge => :beneficiation, :cyclone_overflow => :beneficiation,
    :cyclone_underflow => :beneficiation, :deslimed_slime => :beneficiation,
    :flotation_feed => :flotation, :rougher_concentrate => :flotation,
    :scavenger_tailings => :flotation, :cleaner_concentrate => :flotation,
    :final_concentrate => :flotation, :flotation_tailings => :flotation,
    :reagent_fatty_acid => :flotation, :reagent_silicate => :flotation,
    :thickener_overflow => :flotation, :concentrate_cake => :filtration,
    :dry_rock => :beneficiation,
    :molten_sulphur => :acid_plant, :burner_air => :acid_plant, :so2_gas => :acid_plant,
    :so3_gas => :acid_plant, :absorption_water => :acid_plant,
    :strong_sulphuric => :acid_plant,
    :recycle_acid => :attack, :dilution_water => :attack, :attack_slurry => :attack,
    :digester_slurry => :attack, :flash_vapour => :attack, :filter_feed => :filtration,
    :filter_weak_acid => :filtration, :wash_water => :filtration, :gypsum_cake => :filtration,
    :fluosilicic_acid => :filtration,
    :evaporator_feed => :evaporation, :concentrated_acid => :evaporation,
    :evaporator_condensate => :evaporation, :cooling_water_return => :utilities,
    :ammonia => :granulation, :map_melt => :granulation, :dap_melt => :granulation,
    :granulator_offgas => :granulation, :dryer_offgas => :granulation,
    :cooler_offgas => :granulation, :scrubber_liquor => :granulation,
    :green_pellets => :granulation, :dried_pellets => :granulation,
    :cooled_pellets => :granulation, :undersize_recycle => :granulation,
    :oversize_crush => :granulation, :coated_product => :granulation,
    :product_dap => :granulation, :product_map => :granulation,
    :steam => :utilities, :condensate => :utilities, :natural_gas => :utilities,
    :compressed_air => :utilities, :electricity => :utilities, :process_water => :utilities,
    :cooling_water => :utilities, :stack_gas => :tailings,
)

"""Phase of a stream: solid, slurry, liquid, gas or energy (drives the conversion)."""
const STREAM_PHASES = Dict{Symbol,Symbol}(
    :rom_ore => :solid, :crushed_rock => :solid, :mill_feed => :slurry,
    :mill_discharge => :slurry, :cyclone_overflow => :slurry,
    :cyclone_underflow => :slurry, :deslimed_slime => :slurry,
    :flotation_feed => :slurry, :rougher_concentrate => :slurry,
    :scavenger_tailings => :slurry, :cleaner_concentrate => :slurry,
    :final_concentrate => :slurry, :flotation_tailings => :slurry,
    :reagent_fatty_acid => :liquid, :reagent_silicate => :liquid,
    :thickener_overflow => :liquid, :concentrate_cake => :solid, :dry_rock => :solid,
    :molten_sulphur => :liquid, :burner_air => :gas, :so2_gas => :gas, :so3_gas => :gas,
    :absorption_water => :liquid, :strong_sulphuric => :liquid, :recycle_acid => :liquid,
    :dilution_water => :liquid, :attack_slurry => :slurry, :digester_slurry => :slurry,
    :flash_vapour => :gas, :filter_feed => :slurry, :filter_weak_acid => :liquid,
    :wash_water => :liquid, :gypsum_cake => :solid, :fluosilicic_acid => :liquid,
    :evaporator_feed => :liquid, :concentrated_acid => :liquid,
    :evaporator_condensate => :liquid, :cooling_water_return => :liquid,
    :ammonia => :gas, :map_melt => :slurry, :dap_melt => :slurry,
    :granulator_offgas => :gas, :dryer_offgas => :gas, :cooler_offgas => :gas,
    :scrubber_liquor => :liquid, :green_pellets => :solid, :dried_pellets => :solid,
    :cooled_pellets => :solid, :undersize_recycle => :solid, :oversize_crush => :solid,
    :coated_product => :solid, :product_dap => :solid, :product_map => :solid,
    :steam => :gas, :condensate => :liquid, :natural_gas => :gas,
    :compressed_air => :gas, :electricity => :energy, :process_water => :liquid,
    :cooling_water => :liquid, :stack_gas => :gas,
)

## ---- equipment ---------------------------------------------------------------

"""The equipment tags of the flowsheet, grouped by area in `EQUIPMENT_AREA`."""
const EQUIPMENT = (
    :rom_stockpile, :jaw_crusher, :cone_crusher, :rod_mill, :ball_mill, :hydrocyclone_pack,
    :desliming_cyclone, :rougher_cells, :cleaner_cells, :scavenger_cells,
    :concentrate_thickener, :tailings_thickener, :concentrate_filter, :rock_dryer,
    :slurry_pump, :attack_tank, :digester, :flash_cooler, :belt_filter, :pan_filter,
    :gypsum_belt, :forced_circulation_evaporator, :surface_condenser, :fluorine_scrubber,
    :acid_storage_tank, :sulphur_melter, :sulphur_burner, :waste_heat_boiler, :converter,
    :absorption_tower, :drying_tower, :acid_cooler, :ammonia_sparger, :rotary_granulator,
    :dryer_drum, :cooler_drum, :size_screens, :crusher_oversize, :coating_drum,
    :product_scrubber, :steam_turbine, :cooling_tower, :process_water_pump, :stack,
)

"""Area of each equipment tag; the areas match `AREAS`."""
const EQUIPMENT_AREA = Dict{Symbol,Symbol}(
    :rom_stockpile => :beneficiation, :jaw_crusher => :beneficiation,
    :cone_crusher => :beneficiation, :rod_mill => :beneficiation,
    :ball_mill => :beneficiation, :hydrocyclone_pack => :beneficiation,
    :desliming_cyclone => :beneficiation, :rougher_cells => :flotation,
    :cleaner_cells => :flotation, :scavenger_cells => :flotation,
    :concentrate_thickener => :flotation, :tailings_thickener => :flotation,
    :concentrate_filter => :filtration, :rock_dryer => :beneficiation,
    :slurry_pump => :beneficiation, :attack_tank => :attack, :digester => :attack,
    :flash_cooler => :attack, :belt_filter => :filtration, :pan_filter => :filtration,
    :gypsum_belt => :filtration, :forced_circulation_evaporator => :evaporation,
    :surface_condenser => :evaporation, :fluorine_scrubber => :filtration,
    :acid_storage_tank => :evaporation, :sulphur_melter => :acid_plant,
    :sulphur_burner => :acid_plant, :waste_heat_boiler => :acid_plant,
    :converter => :acid_plant, :absorption_tower => :acid_plant,
    :drying_tower => :acid_plant, :acid_cooler => :acid_plant,
    :ammonia_sparger => :granulation, :rotary_granulator => :granulation,
    :dryer_drum => :granulation, :cooler_drum => :granulation,
    :size_screens => :granulation, :crusher_oversize => :granulation,
    :coating_drum => :granulation, :product_scrubber => :granulation,
    :steam_turbine => :utilities, :cooling_tower => :utilities,
    :process_water_pump => :utilities, :stack => :tailings,
)

## ---- units of measure --------------------------------------------------------

"""Every unit of measure used by the balances, the historians and the reports."""
const UNITS = (:t, :kg, :t_ph, :kg_ph, :m3, :m3_ph, :l_ph, :Nm3_ph, :wt_pct, :pct,
    :ppm, :deg_c, :k, :bar, :kpa, :mmwc, :kwh, :kwh_per_t, :mw, :kw, :gj, :gj_per_t,
    :kj_per_kg, :t_per_m2_d, :um, :mm, :rpm, :hz, :kp, :usd, :usd_per_t, :h, :count)

"""Physical quantity carried by a unit, used to check a conversion is legal."""
const UNIT_QUANTITIES = (
    t = :mass, kg = :mass, t_ph = :mass_flow, kg_ph = :mass_flow, m3 = :volume,
    m3_ph = :volume_flow, l_ph = :volume_flow, Nm3_ph = :volume_flow,
    wt_pct = :fraction, pct = :fraction, ppm = :fraction, deg_c = :temperature,
    k = :temperature, bar = :pressure, kpa = :pressure, mmwc = :pressure, kwh = :energy,
    kwh_per_t = :specific_energy, mw = :power, kw = :power, gj = :energy,
    gj_per_t = :specific_energy,
    kj_per_kg = :specific_energy, t_per_m2_d = :area_rate, um = :length, mm = :length,
    rpm = :frequency, hz = :frequency, kp = :mass, usd = :money, usd_per_t = :specific_cost,
    h = :time, count = :count,
)


## ---- control and soft sensing ------------------------------------------------

"""Manipulated variables available to the operator, the optimiser and the MPC."""
const MANIPULATED = (:rock_feed, :sulphuric_acid_flow, :recycle_acid_flow,
    :dilution_water_flow, :wash_water_flow, :reagent_flow, :mill_water_flow,
    :slurry_density_setpoint, :cooling_water_flow, :flash_vacuum, :steam_flow,
    :evaporator_feed_flow, :ammonia_flow, :granulator_recycle_ratio, :dryer_fuel_flow,
    :coating_flow, :sulphur_feed, :burner_air_flow, :absorber_water_flow)

"""Controlled and performance variables of the digital twin and of the predictive controller."""
const CONTROLLED = (:reactor_temperature, :acid_strength, :sulfate_ratio,
    :slurry_density, :grind_p80, :concentrate_grade, :flotation_recovery,
    :filtration_rate, :evaporator_density, :product_moisture, :product_wsp,
    :scrubber_ph, :stack_fluoride, :gypsum_free_p2o5, :product_nh3_ratio)

"""Soft-sensing modality of an inferential sensor."""
const SENSOR_KINDS = (:process, :visual, :acoustic, :vibration, :spectral, :thermal)

"""State of a soft sensor: usable, drifting, faulty or unavailable."""
const SENSOR_STATUSES = (:healthy, :degraded, :faulty, :offline)

"""How a soft sensor is validated (the split used when fitting it)."""
const VALIDATION_STRATEGIES = (:holdout, :kfold, :rolling, :campaign)

"""Signal-processing features available to the visual and acoustic soft sensors."""
const FEATURE_KINDS = (:statistic, :spectral, :texture, :morphology, :colour, :cepstral)

## ---- operations --------------------------------------------------------------

"""Operating mode of the plant over an interval."""
const OPERATING_MODES = (:production, :startup, :shutdown, :standby, :upset)

"""Aggregation intervals of the historian."""
const INTERVALS = (:shift, :hourly, :daily, :weekly, :monthly, :annual)

"""Minutes covered by one interval."""
const INTERVAL_MINUTES = (
    shift = 480.0, hourly = 60.0, daily = 1440.0, weekly = 10080.0,
    monthly = 43200.0, annual = 525600.0,
)

## ---- assessment --------------------------------------------------------------

"""Compliance assessment outcomes."""
const STATUSES = (:compliant, :at_risk, :noncompliant, :not_assessed)

"""Fault severity levels."""
const SEVERITIES = (:info, :warning, :critical)

"""Direction of a target comparison."""
const COMPARATORS = (:le, :ge, :eq, :between)

"""Currencies the economic model can be expressed in."""
const CURRENCIES = (:USD, :EUR, :BRL, :GBP, :MAD, :ZAR)

"""Compliance frameworks of the phosphate industry."""
const FRAMEWORKS = (:iso_50001, :iso_14001, :iso_46001, :iso_9001, :ghg_protocol,
    :eu_ied, :us_epa_40cfr63, :ifa_bat, :phosphogypsum_code)




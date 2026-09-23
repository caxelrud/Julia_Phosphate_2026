# =============================================================================
# measures.jl -- units, physical constants, stoichiometry and the correlations
# that convert one measured quantity into another.
#
# Every table is keyed by `Symbol`, and every conversion checks that the two units
# carry the same physical quantity, so `convert_value(1.0, :bar, :t_ph)` fails
# loudly instead of returning a number.
# =============================================================================

"""Mass conversion factors to `:kg`; the `*_ph` entries are the same factors applied to a flow."""
const MASS_TO_KG = (t = 1000.0, kg = 1.0, kp = 0.45359237, t_ph = 1000.0, kg_ph = 1.0)

"""Energy conversion factors to `:GJ`."""
const ENERGY_TO_GJ = (gj = 1.0, kwh = 0.0036, mwh = 3.6)

"""Power conversion factors to `:MW`."""
const POWER_TO_MW = (mw = 1.0, kw = 1.0e-3, kwh_per_h = 1.0e-3)


"""Pressure conversion factors to `:bar`."""
const PRESSURE_TO_BAR = (bar = 1.0, kpa = 0.01, mmwc = 9.80665e-5)

"""Length conversion factors to `:mm`."""
const LENGTH_TO_MM = (mm = 1.0, um = 1.0e-3)

"""Volume conversion factors to `:m3`; the `*_ph` entries are the same factors on a flow."""
const VOLUME_TO_M3 = (m3 = 1.0, l = 1.0e-3, m3_ph = 1.0, l_ph = 1.0e-3, Nm3_ph = 1.0)

"""Fraction conversion factors to a unit fraction."""
const FRACTION_TO_UNITY = (wt_pct = 0.01, pct = 0.01, ppm = 1.0e-6, unity = 1.0)

"""`true` when the two units carry the same physical quantity and can be converted."""
is_convertible(from::Symbol, to::Symbol) = unit_quantity(from) === unit_quantity(to)

"""
    convert_value(x, from, to) -> Float64

Convert a value between two units of the same physical quantity:

```julia
convert_value(1.0, :bar, :kpa)     # 100.0
convert_value(28.0, :wt_pct, :unity)  # 0.28
```
"""
function convert_value(x::Real, from::Symbol, to::Symbol)
    from === to && return Float64(x)
    q = unit_quantity(from)
    q === unit_quantity(to) || throw(ArgumentError(string("cannot convert ",
        code_string(from), " (", q, ") into ", code_string(to), " (", unit_quantity(to), ")")))
    xf = conversion_factor(from, to, q)
    return Float64(x) * xf
end

"""Factor that takes a value in `from` to the canonical unit of its quantity."""
function conversion_factor(from::Symbol, to::Symbol, q::Symbol)
    if q === :mass || q === :mass_flow
        return MASS_TO_KG[from] / MASS_TO_KG[to]
    elseif q === :energy
        return ENERGY_TO_GJ[from] / ENERGY_TO_GJ[to]
    elseif q === :power
        return POWER_TO_MW[from] / POWER_TO_MW[to]
    elseif q === :pressure
        return PRESSURE_TO_BAR[from] / PRESSURE_TO_BAR[to]
    elseif q === :length
        return LENGTH_TO_MM[from] / LENGTH_TO_MM[to]
    elseif q === :volume
        return VOLUME_TO_M3[from] / VOLUME_TO_M3[to]
    elseif q === :fraction
        return FRACTION_TO_UNITY[from] / FRACTION_TO_UNITY[to]
    elseif q === :temperature
        return 1.0
    end
    throw(ArgumentError(string("no conversion table for ", q, " (", code_string(from),
        " -> ", code_string(to), ")")))
end

"""Convert a temperature, honouring the Celsius/Kelvin offset the factor tables cannot."""
function convert_temperature(x::Real, from::Symbol, to::Symbol)
    k = from === :deg_c ? Float64(x) + 273.15 : Float64(x)
    return to === :deg_c ? k - 273.15 : k
end

"""Energy of a value given in `unit`, expressed in `:GJ`."""
to_gj(x::Real, unit::Symbol) = unit === :gj ? Float64(x) : convert_value(x, unit, :gj)

"""Energy of a value given in `unit`, expressed in `:kWh`."""
to_kwh(x::Real, unit::Symbol) = convert_value(x, unit, :kwh)

"""Energy content of one `unit`, expressed in `:kWh` (used by the tariff tables)."""
unit_energy_kwh(unit::Symbol) = convert_value(1.0, unit, :kwh)

## ---- physical constants -------------------------------------------------------

"""Molar masses (kg/kmol) of the species and molecules of the reaction section."""
const MOLAR_MASSES = (
    cao = 56.077, p2o5 = 141.944, h2so4 = 98.079, h3po4 = 97.994, nh3 = 17.031,
    sio2 = 60.084, f = 18.998, hf = 20.006, gypsum = 172.168, fluorapatite = 504.30,
    caco3 = 100.087, so4 = 96.058, co2 = 44.009, h2o = 18.015, sulfur = 32.065,
    so2 = 64.064, so3 = 80.062, dap = 132.056, map = 115.026,
)

"""P2O5 content of bone phosphate of lime, `Ca3(PO4)2`, computed from the molar masses."""
const P2O5_PER_BPL = MOLAR_MASSES.p2o5 / (3 * MOLAR_MASSES.cao + MOLAR_MASSES.p2o5)

"""`BPL = 2.1853 × P2O5` (bone phosphate of lime is the traditional ore grade)."""
const BPL_PER_P2O5 = 1.0 / P2O5_PER_BPL

"""Convert an ore grade between the P2O5 and the BPL convention."""
bpl_of_p2o5(x::Real) = x * BPL_PER_P2O5
p2o5_of_bpl(x::Real) = x * P2O5_PER_BPL


## ---- stoichiometry of the attack reaction ------------------------------------

"""
    STOICH

Stoichiometric coefficients of the dihydrate process, all expressed per kilogram
of P2O5 fed as fluorapatite (`Ca5(PO4)3F`):

* `acid`   -- 2.3032 kg H2SO4 (`5 / 1.5` kmol of H2SO4 per kmol of P2O5)
* `gypsum` -- 4.0423 kg CaSO4·2H2O
* `water`  -- 0.8461 kg H2O consumed by the hydration of the gypsum
* `hf`     -- 0.0939 kg HF released per kg P2O5 (all of the fluorine in the lattice)

The values are computed from the molar masses, so they follow the constants above.
"""
const STOICH = (
    acid = (5 / 1.5) * MOLAR_MASSES.h2so4 / MOLAR_MASSES.p2o5,
    gypsum = (5 / 1.5) * MOLAR_MASSES.gypsum / MOLAR_MASSES.p2o5,
    water = (10 / 1.5) * MOLAR_MASSES.h2o / MOLAR_MASSES.p2o5,
    hf = (1 / 1.5) * MOLAR_MASSES.hf / MOLAR_MASSES.p2o5,
)

"""CaO equivalent carried by the apatite lattice (`5 CaO` per `1.5 P2O5`)."""
const APATITE_CAO_PER_P2O5 = (5 / 1.5) * MOLAR_MASSES.cao / MOLAR_MASSES.p2o5

"""Sulphuric acid consumed by free carbonate in the ore: `CaCO3 + H2SO4 -> CaSO4 + CO2 + H2O`."""
const ACID_PER_FREE_CACO3 = MOLAR_MASSES.h2so4 / MOLAR_MASSES.caco3

"""CaCO3 equivalent required to carry a given amount of free CaO."""
const CACO3_PER_CAO = MOLAR_MASSES.caco3 / MOLAR_MASSES.cao

"""CO2 released per kilogram of carbonate attacked."""
const CO2_PER_CACO3 = MOLAR_MASSES.co2 / MOLAR_MASSES.caco3

"""`H3PO4` mass produced from one kilogram of P2O5 (`2 H3PO4` per `P2O5`)."""
const H3PO4_PER_P2O5 = 2.0 * MOLAR_MASSES.h3po4 / MOLAR_MASSES.p2o5

"""Ammonia consumed per kilogram of P2O5 when the product is DAP, `(NH4)2HPO4`."""
const AMMONIA_PER_P2O5_DAP = 4.0 * MOLAR_MASSES.nh3 / MOLAR_MASSES.p2o5


"""Ammonia consumed per kilogram of P2O5 when the product is MAP, `NH4H2PO4`."""
const AMMONIA_PER_P2O5_MAP = AMMONIA_PER_P2O5_DAP / 2.0

"""Molar ratio `NH3 : H3PO4` of the two ammoniated products (the "ammoniation ratio")."""
const AMMONIATION_RATIO = (dap = 2.0, map = 1.0, dap_map = 1.8)

"""Enthalpy released when one kilogram of P2O5 is digested (registered plant value)."""
const HEAT_OF_ATTACK_KJ_PER_KG_P2O5 = 2050.0

"""Enthalpy released by the ammoniation of one kilogram of P2O5 (DAP basis)."""
const HEAT_OF_AMMONIATION_KJ_PER_KG_P2O5 = 2600.0

## ---- process correlations -----------------------------------------------------

"""Latent heat of vaporisation of water (kJ/kg) at the evaporator pressure."""
const LATENT_HEAT_KJ_PER_KG = 2260.0

"""Specific heat capacity of the reaction slurry (kJ/kg/K)."""
const SLURRY_CP_KJ_PER_KG_K = 2.9

"""
Share of the heat of attack that stays in the slurry of the digester.

The reaction releases about 2050 kJ per kilogram of P2O5, which would raise the slurry
by nearly a hundred degrees; a flash cooler evaporates water out of the digester and
takes the rest away, which is what holds the attack tanks at the 78-82 C of the
crystallisation window. This is the share the models keep: it is the one constant that
puts the temperature of the digester where the instrument register says it runs.
"""
const HEAT_RETENTION_SLURRY = 0.17

"""Temperature a litre of cooling water removes from the attack slurry (C per m3/h)."""
const COOLING_GAIN_C_PER_M3PH = 0.02

"""Specific heat capacity of dry product (kJ/kg/K)."""
const SOLID_CP_KJ_PER_KG_K = 0.9

"""P2O5 grade of the weak acid leaving the filters (mass fraction)."""
const P2O5_WEAK_ACID = 0.28

"""P2O5 grade of the merchant acid leaving the evaporators (mass fraction)."""
const P2O5_MERCHANT_ACID = 0.52

"""Lower heating value of a fuel or a feedstock, in GJ per tonne (registered values)."""
energy_density_gj_per_t(material::Symbol) = get(
    (natural_gas = 48.0, coal = 25.8, sulfur = 9.2), material, 0.0)


"""
    bond_mill_power(wi, f80, p80, tph) -> Float64

Specific grinding energy in kWh per tonne of ore from Bond's third law,
`W = 10 Wi (1/sqrt(P80) - 1/sqrt(F80))`, with `wi` in kWh/t and the sizes in µm.
"""
function bond_mill_power(wi::Real, f80::Real, p80::Real, tph::Real)
    return 10.0 * wi * (1.0 / sqrt(p80) - 1.0 / sqrt(f80)) * tph
end

"""
    evaporation_duty(m_feed, x_in, x_out) -> (; water, feed, product)

Water that has to be evaporated to lift a stream from a P2O5 mass fraction `x_in`
to `x_out`, together with the resulting product mass. Both fractions are mass
fractions (not percentages) and `x_out > x_in` is required.
"""
function evaporation_duty(m_feed::Real, x_in::Real, x_out::Real)
    x_in < x_out || throw(ArgumentError("x_out must exceed x_in in evaporation_duty"))
    water = m_feed * (1.0 - x_in / x_out)
    return (water = water, feed = Float64(m_feed), product = m_feed - water)
end

"""Steam consumed by an evaporator set of a given economy (kg water per kg steam)."""
steam_for_evaporation(water::Real, economy::Real) = water / economy

"""
    filtration_rate(area, p2o5_rate, cycle) -> Float64

Filter productivity in tonnes of P2O5 per square metre per day, the figure the
filter section is compared against in every phosphate plant (typical 3-8).
"""
filtration_rate(area::Real, p2o5_rate_tph::Real, availability::Real = 0.92) =
    area <= 0 ? NaN : p2o5_rate_tph * 24.0 * availability / area

"""
    cooling_tower_evaporation(circulation_m3h, range_k) -> Float64

Evaporation loss (m3/h) of an open cooling tower: `0.00085 × circulation × 1.8 × ΔT`,
the standard rule of thumb expressed with the range in kelvin.
"""
cooling_tower_evaporation(circulation_m3h::Real, range_k::Real) =
    0.00085 * circulation_m3h * 1.8 * range_k


"""Drift loss (m3/h) of a cooling tower with a given drift fraction."""
cooling_tower_drift(circulation_m3h::Real, drift_fraction::Real = 0.0002) =
    circulation_m3h * drift_fraction

"""Blowdown (m3/h) needed to hold a number of concentrations cycles."""
cooling_tower_blowdown(evaporation::Real, cycles::Real) =
    cycles <= 1 ? 0.0 : evaporation / (cycles - 1.0)

"""
    granulator_recycle_ratio(moisture_melt, moisture_bed) -> Float64

Recycle ratio of a rotary granulator from the moisture of the melt and the
moisture the bed is allowed to hold; the mass flow that has to be recycled per
unit of product grows as the two approach each other.
"""
function granulator_recycle_ratio(moisture_melt::Real, moisture_bed::Real)
    moisture_bed <= moisture_melt && return 25.0
    return clamp((moisture_melt - 0.01) / (moisture_bed - moisture_melt), 0.5, 25.0)
end

## ---- composition arithmetic ---------------------------------------------------

"""
    Composition

Assay of a solid, a slurry or an acid: a `species => mass fraction` map, keyed by
the symbols of [`SPECIES`](@ref). Ore bodies, concentrates, gypsum cakes, weak
acid, melt and product are all `Composition`s, so one arithmetic serves the whole
flowsheet:

```julia
rock = composition(p2o5 = 0.29, cao = 0.46, sio2 = 0.09)
grade(rock, :p2o5)      # 29.0 (%)
bpl_grade(rock)         # 63.4 (BPL %)
blend([rock, filler], [0.8, 0.2])
```
"""
struct Composition
    fractions::Dict{Symbol,Float64}
    function Composition(d::AbstractDict)
        fractions = Dict{Symbol,Float64}()
        for (k, v) in d
            v = Float64(v)
            v == 0.0 || (fractions[Sym(k)] = v)
        end
        new(fractions)
    end
end

"""Build a `Composition` from pairs or a dictionary of mass fractions."""
Composition(pairs::Pair...) =
    Composition(Dict{Symbol,Float64}(Sym(k) => Float64(v) for (k, v) in pairs))
composition(d::AbstractDict) = Composition(d)
composition(nt::NamedTuple) =
    Composition(Dict{Symbol,Float64}(k => Float64(v) for (k, v) in pairs(nt)))

"""Build a `Composition` from keyword arguments: `composition(p2o5 = 0.29, cao = 0.46)`."""
composition(; kwargs...) =
    Composition(Dict{Symbol,Float64}(Sym(k) => Float64(v) for (k, v) in kwargs))


"""Mass fraction of one species (`0.0` when the assay does not list it)."""
Base.getindex(c::Composition, s::Symbol) = get(c.fractions, s, 0.0)
Base.getindex(c::Composition, s::AbstractString) = c[Sym(s)]
Base.keys(c::Composition) = keys(c.fractions)
Base.values(c::Composition) = values(c.fractions)
Base.length(c::Composition) = length(c.fractions)
Base.iterate(c::Composition, args...) = iterate(c.fractions, args...)
Base.:(==)(a::Composition, b::Composition) = a.fractions == b.fractions

"""Sum of the listed mass fractions (1.0 for a complete, normalised assay)."""
total(c::Composition) = sum(values(c.fractions))

"""Grade of a species in per cent (`grade(rock, :p2o5)`)."""
grade(c::Composition, s::Symbol) = 100.0 * c[s]

"""P2O5 grade in per cent, the figure every phosphate assay leads with."""
p2o5_grade(c::Composition) = grade(c, :p2o5)

"""BPL grade in per cent (`BPL = 2.1853 × P2O5`)."""
bpl_grade(c::Composition) = 100.0 * bpl_of_p2o5(c[:p2o5])

"""The assay scaled so that the listed fractions sum to one."""
normalize_composition(c::Composition) =
    total(c) == 0.0 ? c :
    Composition(Dict{Symbol,Float64}(k => v / total(c) for (k, v) in c.fractions))

"""Total mass fraction of the gangue species (`:sio2`, `:fe2o3`, `:al2o3`, `:mgo`, ...)."""
gangue(c::Composition) = sum(c[s] for s in species_of(:gangue); init = 0.0)

"""Mass fraction of the species of one role, e.g. the volatiles of an assay."""
role_fraction(c::Composition, role::Symbol) = sum(c[s] for s in species_of(role); init = 0.0)

"""
    ratio(c, a, b) -> Float64

Mass ratio of two species of an assay. The CaO : P2O5 ratio of a concentrate and the
SiO2 : CaO ratio of a dihydrate filter feed are the two the reaction section is watched
against; a zero denominator returns `Inf` rather than `NaN`.
"""
function ratio(c::Composition, a::Symbol, b::Symbol)
    den = c[b]
    return den == 0.0 ? Inf : c[a] / den
end

"""
    blend(comps, weights) -> Composition

Mass-weighted blend of several assays, the operation behind the rock-blend optimiser and
behind the feed preparation of the reaction section.
"""
function blend(comps::AbstractVector, weights::AbstractVector{<:Real})
    length(comps) == length(weights) ||
        throw(ArgumentError("blend needs one weight per composition"))
    w = collect(Float64, weights)
    s = sum(w)
    s > 0 || throw(ArgumentError("the blend weights must not sum to zero"))
    w ./= s
    out = Dict{Symbol,Float64}()
    for (c, wi) in zip(comps, w)
        wi == 0.0 && continue
        for (k, v) in c.fractions
            out[k] = get(out, k, 0.0) + wi * v
        end
    end
    return Composition(out)
end

"""`true` when the assay lists the species of a role at a non-zero fraction."""
has_role(c::Composition, role::Symbol) = role_fraction(c, role) > 0.0


## ---- reaction engineering from an assay --------------------------------------

"""Sulphuric acid consumed by free lime in the ore: `CaO + H2SO4 -> CaSO4 + H2O`."""
const ACID_PER_FREE_CAO = MOLAR_MASSES.h2so4 / MOLAR_MASSES.cao

"""Gypsum produced per kilogram of free lime in the ore."""
const GYPSUM_PER_FREE_CAO = MOLAR_MASSES.gypsum / MOLAR_MASSES.cao

"""CaO equivalent of the non-apatitic ("free") fraction of an ore assay."""
free_cao(c::Composition, mass::Real) =
    max(0.0, mass * c[:cao] - APATITE_CAO_PER_P2O5 * mass * c[:p2o5])

"""
    acid_requirement(mass_rock, c; excess = 0.0) -> (; stoich, carbonate, total)

Sulphuric acid (kg) needed to digest `mass_rock` kilograms of a rock of assay `c`:
the apatite demand plus the demand of the free carbonate, grossed up by an
`excess` expressed as a fraction of the total. The sulphate balance of the plant
is this excess seen as `SO4 : P2O5` in the product acid.
"""
function acid_requirement(mass_rock::Real, c::Composition; excess::Real = 0.0)
    p2o5 = mass_rock * c[:p2o5]
    stoich = STOICH.acid * p2o5
    carbonate = ACID_PER_FREE_CAO * free_cao(c, mass_rock)
    base = stoich + carbonate
    return (; stoich = stoich, carbonate = carbonate, total = base * (1.0 + excess),
        free_cao = free_cao(c, mass_rock))
end

"""Gypsum (kg) produced by digesting `mass_rock` kilograms of an ore assay `c`."""
function gypsum_production(mass_rock::Real, c::Composition)
    return STOICH.gypsum * mass_rock * c[:p2o5] + GYPSUM_PER_FREE_CAO * free_cao(c, mass_rock)
end

"""CO2 (kg) released by the carbonate in `mass_rock` kilograms of an ore assay `c`."""
function carbonate_co2(mass_rock::Real, c::Composition)
    return CO2_PER_CACO3 * CACO3_PER_CAO * free_cao(c, mass_rock)
end

"""HF-forming fluorine (kg) released per kilogram of ore, at a given release fraction."""
hf_release(mass_rock::Real, c::Composition; release::Real = 0.45) =
    release * mass_rock * c[:f] * (MOLAR_MASSES.hf / MOLAR_MASSES.f)

"""
    rock_for_p2o5(p2o5_kg, c) -> (; rock, bpl)

Ore that has to be fed to deliver `p2o5_kg` kilograms of P2O5 at the grade of the
assay, the inverse of the plant's recovery calculation.
"""
function rock_for_p2o5(p2o5_kg::Real, c::Composition)
    rock = c[:p2o5] <= 0.0 ? Inf : p2o5_kg / c[:p2o5]
    return (; rock = rock, bpl = isfinite(rock) ? rock * bpl_of_p2o5(c[:p2o5]) : Inf)
end

"""
    acid_density(wt_pct; T = 60.0) -> Float64

Density (kg/l) of a phosphoric acid solution from a tabulated curve of the
H3PO4-water system, interpolated linearly and corrected for temperature with
`-0.0005` kg/l per kelvin above 20 °C (a screening-level correlation).
"""
function acid_density(wt_pct::Real, T::Real = 60.0)
    xs = (0.0, 10.0, 20.0, 28.0, 36.0, 44.0, 52.0, 58.0)
    ys = (0.998, 1.054, 1.113, 1.163, 1.216, 1.293, 1.512, 1.575)
    x = clamp(Float64(wt_pct), first(xs), last(xs))
    i = clamp(searchsortedlast(collect(xs), x), 1, length(xs) - 1)
    t = (x - xs[i]) / (xs[i + 1] - xs[i])
    rho20 = ys[i] + t * (ys[i + 1] - ys[i])
    return rho20 - 0.0005 * (Float64(T) - 20.0)
end

"""Boiling point (K) of a phosphoric acid solution of a given P2O5 mass fraction."""
acid_boiling_point(wt_pct::Real) = 373.15 + 0.95 * clamp(Float64(wt_pct), 0.0, 60.0)



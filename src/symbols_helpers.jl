# =============================================================================
# symbols_helpers.jl -- turning symbols into text, and back again, and asking the
# vocabulary questions about them.
#
# The whole package is written against these lookups, so a typo in a symbol is
# reported with the symbol's `code_string` instead of producing a `missing`.
# =============================================================================

"""
    Sym(x) -> Symbol

Convenience constructor: `Sym("P2O5") === :p2o5`, `Sym(:attack) === :attack`.
"""
Sym(x::Symbol) = x
Sym(x::AbstractString) = Symbol(lowercase(replace(x, r"[\s\-]+" => "_")))

"""
    to_string(sym) -> String

Render a `Symbol` for humans: `:acid_strength` becomes `"Acid strength"`.
"""
function to_string(sym::Symbol)
    s = replace(String(sym), '_' => ' ')
    return isempty(s) ? s : string(uppercase(s[1]), s[2:end])
end

"""A string is already its own label; this keeps the printers type-agnostic."""
to_string(str::AbstractString) = String(str)

"""Convert a human string back into the symbol vocabulary (`"Acid strength" -> :acid_strength`)."""
to_symbol(str::AbstractString) = Sym(str)

"""Format a symbol the way it is written in code, e.g. `:attack` -> `":attack"`."""
code_string(sym::Symbol) = string(':', sym)

"""`true` when both values are the same symbol (accepts `Symbol` or `String`)."""
symbol_equal(a::Symbol, b::Symbol) = a === b
symbol_equal(a::Symbol, b::AbstractString) = a === Sym(b)
symbol_equal(a::AbstractString, b::Symbol) = Sym(a) === b
symbol_equal(a::AbstractString, b::AbstractString) = Sym(a) === Sym(b)

## ---- vocabulary questions ----------------------------------------------------

"""`true` when `sym` is one of the nine plant areas."""
is_area(sym::Symbol) = sym in AREAS

"""Index (1-based) of an area inside [`AREAS`](@ref), used for stable ordering."""
area_index(sym::Symbol) = findfirst(==(sym), AREAS)

"""Human-readable name of an area."""
area_name(sym::Symbol) = get(AREA_NAMES, sym, sym)

"""`true` when `sym` is a species of the mass balance."""
is_species(sym::Symbol) = sym in SPECIES

"""Display formula of a species (`:p2o5` -> `:P2O5`)."""
species_formula(sym::Symbol) = get(SPECIES_FORMULAS, sym, sym)

"""Role of a species in the balance (`:value`, `:gangue`, `:acid`, `:nutrient`, `:volatile`)."""
species_role(sym::Symbol) = get(SPECIES_ROLES, sym, :other)

"""Species of a role, in the order of [`SPECIES`](@ref): `species_of(:gangue)`."""
species_of(role::Symbol) = Tuple(s for s in SPECIES if species_role(s) === role)

"""`true` when `sym` is a stream of the flowsheet."""
is_stream(sym::Symbol) = sym in STREAMS

"""Area a stream belongs to; the area of an unknown stream is `:utilities`."""
stream_area(sym::Symbol) = get(STREAM_AREA, sym, :utilities)

"""Phase of a stream (`:solid`, `:slurry`, `:liquid`, `:gas`, `:energy`)."""
stream_phase(sym::Symbol) = get(STREAM_PHASES, sym, :liquid)

"""Streams of one area, in the order of [`STREAMS`](@ref)."""
streams_of(area::Symbol) = Tuple(s for s in STREAMS if stream_area(s) === area)

"""`true` when `sym` is an equipment tag of the flowsheet."""
is_equipment(sym::Symbol) = sym in EQUIPMENT

"""Area an equipment tag belongs to; the area of an unknown tag is `:utilities`."""
equipment_area(sym::Symbol) = get(EQUIPMENT_AREA, sym, :utilities)

"""Equipment tags of one area, in the order of [`EQUIPMENT`](@ref)."""
equipment_of(area::Symbol) = Tuple(e for e in EQUIPMENT if equipment_area(e) === area)

"""`true` when `sym` is a unit of measure known to the package."""
is_unit_symbol(sym::Symbol) = sym in UNITS

"""Physical quantity carried by a unit; throws when the unit is unknown."""
function unit_quantity(sym::Symbol)
    haskey(UNIT_QUANTITIES, sym) || throw(ArgumentError("unknown unit $(code_string(sym))"))
    return UNIT_QUANTITIES[sym]
end

"""`true` when `sym` is a manipulated variable of the plant."""
is_manipulated(sym::Symbol) = sym in MANIPULATED

"""`true` when `sym` is a controlled (or performance) variable of the plant."""
is_controlled(sym::Symbol) = sym in CONTROLLED

"""`true` when `sym` is a soft-sensing modality."""
is_sensor_kind(sym::Symbol) = sym in SENSOR_KINDS

"""`true` when `sym` is a compliance framework of the phosphate industry."""
is_framework(sym::Symbol) = sym in FRAMEWORKS

"""
    group_by_area(x)

Group a symbol-keyed dictionary by the area of its keys: streams, equipment or
anything else with an entry in `STREAM_AREA` / `EQUIPMENT_AREA`. Returns a
`Dict{Symbol,Any}` keyed by area; print it through `sort(collect(...))` for a
stable order.
"""
function group_by_area(d::AbstractDict)
    out = Dict{Symbol,Any}()
    for (k, v) in d
        a = equipment_area(k)
        haskey(STREAM_AREA, k) && (a = stream_area(k))
        push!(get!(out, a, Any[]), v)
    end
    return out
end

## ---- container conversion ----------------------------------------------------

"""
    symbolize_keys(x)

Recursively rebuild a container using `Symbol` keys, so that JSON payloads read
back into the same vocabulary the package uses in code.
"""
symbolize_keys(d::AbstractDict) = Dict{Symbol,Any}(Sym(k) => symbolize_keys(v) for (k, v) in d)
symbolize_keys(v::AbstractVector) = Any[symbolize_keys(x) for x in v]
symbolize_keys(x) = x

"""Inverse of [`symbolize_keys`](@ref); used before writing JSON."""
stringify_keys(d::AbstractDict) = Dict{String,Any}(String(k) => stringify_keys(v) for (k, v) in d)
stringify_keys(v::AbstractVector) = Any[stringify_keys(x) for x in v]
stringify_keys(x) = x

"""
    validate_vocabulary(; io = stdout) -> Bool

Assert that the vocabulary is internally consistent and print the route summary:
every list is duplicate free, every area has a name, every stream has an area and
a phase, every equipment tag has an area, and every unit has a physical
quantity. Returns `true` on success and throws otherwise.
"""
function validate_vocabulary(; io::IO = stdout)
    for (label, list) in (:AREAS => AREAS, :SPECIES => SPECIES, :STREAMS => STREAMS,
        :EQUIPMENT => EQUIPMENT, :UNITS => UNITS, :MANIPULATED => MANIPULATED,
        :CONTROLLED => CONTROLLED)
        length(unique(list)) == length(list) || error("duplicate entry in $(label)")
    end
    Set(keys(AREA_NAMES)) == Set(AREAS) || error("AREA_NAMES must cover AREAS")
    for u in UNITS
        haskey(UNIT_QUANTITIES, u) || error("unit $(code_string(u)) has no quantity")
    end
    for s in STREAMS
        haskey(STREAM_AREA, s) || error("stream $(code_string(s)) has no area")
        haskey(STREAM_PHASES, s) || error("stream $(code_string(s)) has no phase")
        is_area(stream_area(s)) || error("stream $(code_string(s)) maps to an unknown area")
    end
    for e in EQUIPMENT
        haskey(EQUIPMENT_AREA, e) || error("equipment $(code_string(e)) has no area")
    end
    for (label, list) in (:AREA_NAMES => collect(values(AREA_NAMES)),
        :SPECIES_FORMULAS => collect(values(SPECIES_FORMULAS)))
        length(unique(list)) == length(list) || error("duplicate value in $(label)")
    end
    Set(keys(SPECIES_FORMULAS)) == Set(SPECIES) ||
        error("SPECIES_FORMULAS must cover SPECIES")
    Set(keys(SPECIES_ROLES)) == Set(SPECIES) || error("SPECIES_ROLES must cover SPECIES")

    print(io, "PHOSPHATE vocabulary: ", length(AREAS), " areas, ", length(SPECIES),
        " species, ", length(STREAMS), " streams, ", length(EQUIPMENT), " equipment tags, ",
        length(UNITS), " units\n")
    for a in AREAS
        print(io, rpad(code_string(a), 18), " -> ", rpad(string(area_name(a)), 20),
            lpad(length(streams_of(a)), 3), " streams, ",
            lpad(length(equipment_of(a)), 3), " equipment tags\n")
    end
    return true
end


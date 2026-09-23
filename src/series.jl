# =============================================================================
# series.jl -- the historian containers.
#
# `Reading` is a single measurement with its unit and its quality flag; `Series`
# is a regular interval series of one signal; `SignalBook` is the whole historian
# of the plant, keyed by signal tag. Every signal tag, unit and quality flag is a
# `Symbol`, so a book can be rolled up, joined and exported without a schema.
# =============================================================================

"""Quality flag of an interval: measured, reconciled or unusable."""
const QUALITY_FLAGS = (:measured, :estimated, :reconciled, :substituted, :faulty, :missing)

"""Quality flags that may be used in a balance or a report."""
const OK_QUALITY = (:measured, :estimated, :reconciled, :substituted)

"""Compact rendering of a number without the digits a report does not need."""
fmt_value(x::Real; digits::Integer = 3) =
    isfinite(x) ? string(round(Float64(x), digits = digits)) : "n/a"

"""
    Reading

One measurement: a value, its unit, its quality flag and the tag that produced it.

```julia
r = Reading(72.4, :deg_c, :measured, :attack_tank)
usable(r)     # true
```
"""
struct Reading
    value::Float64
    unit::Symbol
    quality::Symbol
    tag::Symbol
end

"""A reading of an unknown tag, measured in the unit of the signal."""
Reading(value::Real, unit::Symbol, quality::Symbol = :measured) =
    Reading(Float64(value), unit, quality, :none)

"""`true` when the reading may be used in a balance."""
usable(r::Reading) = r.quality in OK_QUALITY

"""Human-readable line for logs and reports."""
to_string(r::Reading) = string(fmt_value(r.value), " ", code_string(r.unit), " (",
    string(r.quality), ")")

"""`true` when the value is inside the nominal range; `NaN` counts as out of range."""
within(r::Reading, lo::Real, hi::Real) = isfinite(r.value) && lo <= r.value <= hi

## ---- interval series ---------------------------------------------------------

"""
    Series

A regular interval series of one signal: `stamps`, `values`, `qualities`, plus the
`id`, the `interval`, the `unit` and a symbol-keyed `meta` block (description,
area, stream, equipment and the nominal range).

The four vectors always have the same length, so an index into the time grid
indexes everything at once.
"""
struct Series
    id::Symbol
    interval::Symbol
    unit::Symbol
    stamps::Vector{DateTime}
    values::Vector{Float64}
    qualities::Vector{Symbol}
    meta::Dict{Symbol,Any}
    function Series(id::Symbol, interval::Symbol, unit::Symbol, stamps::Vector{DateTime},
        values::Vector{Float64}, qualities::Vector{Symbol},
        meta::Dict{Symbol,Any} = Dict{Symbol,Any}())
        n = length(stamps)
        length(values) == n || throw(ArgumentError("values must match the time grid"))
        length(qualities) == n || throw(ArgumentError("qualities must match the time grid"))
        return new(id, interval, unit, stamps, values, qualities, meta)
    end
end

"""Series of a constant value over a time grid (used by the tests and the demos)."""
function Series(id::Symbol, interval::Symbol, unit::Symbol, stamps::Vector{DateTime},
    value::Real; quality::Symbol = :measured, meta::Dict{Symbol,Any} = Dict{Symbol,Any}())
    n = length(stamps)
    return Series(id, interval, unit, stamps, fill(Float64(value), n), fill(quality, n), meta)
end

Base.length(s::Series) = length(s.stamps)
Base.getindex(s::Series, i) = s.values[i]
Base.eltype(::Type{Series}) = Float64

"""`true` when the series has at least one usable interval."""
has_data(s::Series) = any(q -> q in OK_QUALITY, s.qualities)

"""Index of every interval with a usable quality flag."""
good_intervals(s::Series) = findall(q -> q in OK_QUALITY, s.qualities)

"""Values of the usable intervals only."""
good_values(s::Series) = s.values[good_intervals(s)]

"""Sum of the usable intervals, the only total a balance may use."""
total(s::Series) = sum(good_values(s); init = 0.0)

"""Mean of the usable intervals."""
mean_value(s::Series) = (v = good_values(s); isempty(v) ? NaN : sum(v) / length(v))

"""Largest usable interval."""
peak_value(s::Series) = (v = good_values(s); isempty(v) ? NaN : maximum(v))

"""Smallest usable interval."""
min_value(s::Series) = (v = good_values(s); isempty(v) ? NaN : minimum(v))

"""Smallest and largest usable interval, for the report cards."""
extrema_value(s::Series) = (min = min_value(s), max = peak_value(s))

## ---- the reducers the daily, monthly and shift roll-ups apply to a window --------

"""Sum of a window of values; the reducer every flow is rolled up with."""
total(v::AbstractVector{<:Real}) = isempty(v) ? 0.0 : sum(v; init = 0.0)

"""Mean of a window of values; the reducer every level and grade is rolled up with."""
mean_value(v::AbstractVector{<:Real}) = isempty(v) ? NaN : sum(v) / length(v)

"""Largest value of a window."""
peak_value(v::AbstractVector{<:Real}) = isempty(v) ? NaN : maximum(v)

"""Smallest value of a window."""
min_value(v::AbstractVector{<:Real}) = isempty(v) ? NaN : minimum(v)

"""First and last timestamp of the series."""
span(s::Series) = isempty(s.stamps) ? (nothing, nothing) : (first(s.stamps), last(s.stamps))

"""Fraction of the time grid that carries a usable interval."""
completeness(s::Series) =
    isempty(s.stamps) ? 0.0 : 100.0 * length(good_intervals(s)) / length(s.stamps)

"""Runs of unusable intervals as `(from, to, count, quality)` tuples."""
function bad_intervals(s::Series)
    runs = NamedTuple{(:from, :to, :count, :quality),Tuple{DateTime,DateTime,Int,Symbol}}[]
    i = 1
    n = length(s)
    while i <= n
        if !(s.qualities[i] in OK_QUALITY)
            j = i
            while j < n && s.qualities[j + 1] == s.qualities[i]
                j += 1
            end
            push!(runs, (from = s.stamps[i], to = s.stamps[j], count = j - i + 1,
                quality = s.qualities[i]))
            i = j + 1
        else
            i += 1
        end
    end
    return runs
end

"""Sub-series of the given indices."""
subseries(s::Series, idx::AbstractVector{<:Integer}) =
    Series(s.id, s.interval, s.unit, s.stamps[idx], s.values[idx], s.qualities[idx], copy(s.meta))

"""Sub-series between two timestamps (inclusive)."""
window(s::Series, from::DateTime, to::DateTime) =
    subseries(s, findall(t -> from <= t <= to, s.stamps))

"""The same series expressed in another unit of the same physical quantity."""
function convert_series(s::Series, unit::Symbol)
    is_convertible(s.unit, unit) || throw(ArgumentError(string("cannot convert series ",
        code_string(s.id), " from ", code_string(s.unit), " to ", code_string(unit))))
    return Series(s.id, s.interval, unit, s.stamps,
        [convert_value(v, s.unit, unit) for v in s.values], s.qualities, copy(s.meta))
end

"""The series scaled so that its mean becomes `to`, used to compare shapes."""
function normalize_series(s::Series; to::Real = 1.0)
    m = mean_value(s)
    (m == 0.0 || isnan(m)) && return s
    return Series(s.id, s.interval, :count, s.stamps, [to * v / m for v in s.values],
        s.qualities, copy(s.meta))
end

"""The series shifted in time by a number of interval steps (dead-time alignment)."""
shift_series(s::Series, steps::Integer) =
    Series(s.id, s.interval, s.unit, s.stamps, circshift(s.values, steps),
        circshift(s.qualities, steps), copy(s.meta))

"""Worst quality flag of a list of flags, in the order of [`QUALITY_FLAGS`](@ref)."""
function worst_quality(flags)
    worst = :measured
    for q in flags
        idx = findfirst(==(q), QUALITY_FLAGS)
        idx === nothing && continue
        idx > findfirst(==(worst), QUALITY_FLAGS) && (worst = q)
    end
    return worst
end

"""Symbol-keyed summary of a series, the row a report writes for every signal."""
function series_summary(s::Series)
    return Dict{Symbol,Any}(:signal => s.id, :interval => s.interval, :unit => s.unit,
        :intervals => length(s), :completeness_pct => round(completeness(s), digits = 2),
        :total => total(s), :mean => mean_value(s), :min => min_value(s), :max => peak_value(s),
        :quality => worst_quality(s.qualities))
end


## ---- the historian -----------------------------------------------------------

"""
    SignalBook

The historian of one campaign: a symbol-keyed dictionary of [`Series`](@ref), one
per signal tag, plus the plant `context` (site, period, campaign, seed).
"""
struct SignalBook
    signals::Dict{Symbol,Series}
    context::Dict{Symbol,Any}
end

SignalBook(signals::Dict{Symbol,Series} = Dict{Symbol,Series}()) =
    SignalBook(signals, Dict{Symbol,Any}())

Base.length(b::SignalBook) = length(b.signals)
Base.getindex(b::SignalBook, id::Symbol) = b.signals[id]
Base.getindex(b::SignalBook, id::AbstractString) = b.signals[Sym(id)]
Base.haskey(b::SignalBook, id::Symbol) = haskey(b.signals, id)
Base.keys(b::SignalBook) = keys(b.signals)
Base.values(b::SignalBook) = values(b.signals)
Base.iterate(b::SignalBook, args...) = iterate(b.signals, args...)
Base.setindex!(b::SignalBook, s::Series, id::Symbol) = (b.signals[id] = s; b)

"""Every signal tag of the book, in a stable order."""
signal_ids(b::SignalBook) = sort(collect(keys(b.signals)); by = String)

"""Signals of one area, using the area recorded in each series' metadata."""
function signals_of(b::SignalBook, area::Symbol)
    ids = [id for id in signal_ids(b) if get(b[id].meta, :area, :utilities) === area]
    return [b[id] for id in ids]
end


"""Range of a signal of the book, and `NaN` when it carries no usable interval."""
value_of(b::SignalBook, id::Symbol) = haskey(b, id) ? mean_value(b[id]) : NaN

"""`true` when every listed signal is present in the book."""
function has_signals(b::SignalBook, ids::AbstractVector{Symbol})
    return all(id -> haskey(b, id), ids)
end

"""The book with every timestamp shifted by a number of interval steps."""
function shift_book(b::SignalBook, steps::Integer)
    return SignalBook(Dict{Symbol,Series}(id => shift_series(s, steps) for (id, s) in b.signals),
        copy(b.context))
end

"""Symbol-keyed summary of the whole book, one row per signal."""
book_summary(b::SignalBook) = [series_summary(b[id]) for id in signal_ids(b)]


"""Mean completeness of the book, the number the data-quality card shows."""
book_completeness(b::SignalBook) =
    isempty(b.signals) ? 0.0 : sum(completeness(s) for s in values(b.signals)) / length(b.signals)



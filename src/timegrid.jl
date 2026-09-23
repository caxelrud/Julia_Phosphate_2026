# =============================================================================
# timegrid.jl -- the shift calendar of the historian.
#
# The plant runs three eight-hour shifts; the historian stores hourly means and
# the reports roll them up to shifts, days, months and the campaign. Everything
# is derived from `DateTime` stamps, so the same code serves the synthetic
# campaign and a real export.
# =============================================================================

"""Hour of the day (0-23) at which a shift starts, in the order of `SHIFTS`."""
const SHIFT_STARTS = (day = 6, swing = 14, night = 22)

"""Name of a shift, used in the tables and the figures."""
const SHIFTS = (:day, :swing, :night)

"""First `DateTime` of the campaign: the origin of every synthetic signal."""
campaign_start(year::Integer = 2026, month::Integer = 1, day::Integer = 1) =
    DateTime(year, month, day, 0, 0, 0)

"""
    hourly_stamps(days; start) -> Vector{DateTime}

Time grid of the hourly historian, `24 × days` stamps from `start`.
"""
hourly_stamps(days::Integer; start::DateTime = campaign_start()) =
    [start + Hour(h) for h in 0:(24 * days - 1)]

"""
    interval_stamps(interval, start, stop; step_hours = 1) -> Vector{DateTime}

Time grid of an arbitrary interval between two timestamps, used by the unit tests
and by the scripts that resample a campaign.
"""
function interval_stamps(interval::Symbol, start::DateTime, stop::DateTime;
    step_hours::Real = 1.0)
    step = interval === :hourly ? Hour(1) : Millisecond(round(Int, step_hours * 3_600_000))
    stamps = DateTime[]
    t = start
    while t <= stop
        push!(stamps, t)
        t += step
    end
    return stamps
end

"""Name of the shift that contains a timestamp."""
function shift_of(t::DateTime)
    h = Dates.hour(t)
    h >= SHIFT_STARTS.day && h < SHIFT_STARTS.swing && return :day
    h >= SHIFT_STARTS.swing && h < SHIFT_STARTS.night && return :swing
    return :night
end

"""`true` when the timestamp falls in a weekend, when the plant runs at reduced rate."""
is_weekend(t::DateTime) = Dates.dayofweek(t) >= 6

"""
    shift_series(book, id; reducer = total)

Roll one signal of the historian to one value per shift, the granularity the
production report is written in. `reducer` is `total` for flows and
`mean_value` for temperatures and grades.
"""
function shift_series(s::Series; reducer = total)
    buckets = Dict{Tuple{Date,Symbol},Vector{Float64}}()
    for (t, v, q) in zip(s.stamps, s.values, s.qualities)
        q in OK_QUALITY || continue
        key = (Dates.Date(t), shift_of(t))
        push!(get!(buckets, key, Float64[]), v)
    end
    bucket_keys = sort(collect(keys(buckets));
        by = k -> (k[1], findfirst(==(k[2]), SHIFTS)))
    stamps = [DateTime(k[1]) + Hour(SHIFT_STARTS[k[2]]) for k in bucket_keys]
    values = [reducer(buckets[k]) for k in bucket_keys]
    return Series(Symbol(s.id, :_shift), :shift, s.unit, stamps, values,
        fill(Symbol(:reconciled), length(stamps)), copy(s.meta))
end

"""
    daily_series(s) -> Series

One value per calendar day, summing a flow and averaging anything else, driven by
the `:kind` entry of the series metadata (`:flow` or `:level`).
"""
function daily_series(s::Series; reducer = nothing)
    red = reducer === nothing ? (get(s.meta, :kind, :level) === :flow ? total : mean_value) : reducer
    buckets = Dict{Date,Vector{Float64}}()
    for (t, v, q) in zip(s.stamps, s.values, s.qualities)
        q in OK_QUALITY || continue
        push!(get!(buckets, Dates.Date(t), Float64[]), v)
    end
    days = sort(collect(keys(buckets)))
    return Series(Symbol(s.id, :_daily), :daily, s.unit,
        [DateTime(d) for d in days], [red(buckets[d]) for d in days],
        fill(Symbol(:reconciled), length(days)), copy(s.meta))
end

"""One value per calendar month, summing a flow and averaging anything else."""
function monthly_series(s::Series; reducer = nothing)
    red = reducer === nothing ? (get(s.meta, :kind, :level) === :flow ? total : mean_value) : reducer
    buckets = Dict{Tuple{Int,Int},Vector{Float64}}()
    for (t, v, q) in zip(s.stamps, s.values, s.qualities)
        q in OK_QUALITY || continue
        push!(get!(buckets, (Dates.year(t), Dates.month(t)), Float64[]), v)
    end
    bucket_keys = sort(collect(keys(buckets)))
    return Series(Symbol(s.id, :_monthly), :monthly, s.unit,
        [DateTime(k[1], k[2], 1) for k in bucket_keys], [red(buckets[k]) for k in bucket_keys],
        fill(Symbol(:reconciled), length(bucket_keys)), copy(s.meta))
end

"""The historian rolled up to one value per shift: a book of the same signals."""
function shift_book(b::SignalBook; kinds::Dict{Symbol,Symbol} = Dict{Symbol,Symbol}())
    out = Dict{Symbol,Series}()
    for (id, s) in b.signals
        kind = get(kinds, id, get(s.meta, :kind, :level))
        red = kind === :flow ? total : mean_value
        out[id] = shift_series(s; reducer = red)
    end
    return SignalBook(out, copy(b.context))
end

"""The historian rolled up to one value per day."""
function daily_book(b::SignalBook; kinds::Dict{Symbol,Symbol} = Dict{Symbol,Symbol}())
    out = Dict{Symbol,Series}()
    for (id, s) in b.signals
        kind = get(kinds, id, get(s.meta, :kind, :level))
        red = kind === :flow ? total : mean_value
        out[id] = daily_series(s; reducer = red)
    end
    return SignalBook(out, copy(b.context))
end

"""Steps between two timestamps of an hourly series (dead time in intervals)."""
steps_between(from::DateTime, to::DateTime; interval_hours::Real = 1.0) =
    round(Int, Dates.value(to - from) / 3_600_000 / interval_hours)

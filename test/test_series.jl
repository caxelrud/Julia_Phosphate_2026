## The historian containers and the aggregation of the time grid.
@testset "series" begin
    stamps = hourly_stamps(3)
    @test length(stamps) == 72
    s = Series(:test, :hourly, :t_ph, stamps, 5.0)
    @test length(s) == 72
    @test total(s) ≈ 360.0
    @test mean_value(s) ≈ 5.0
    @test peak_value(s) ≈ 5.0
    @test completeness(s) ≈ 100.0
    @test isempty(bad_intervals(s))
    @test span(s)[1] == stamps[1]
    @test shift_of(DateTime(2026, 1, 1, 7)) === :day
    @test shift_of(DateTime(2026, 1, 1, 15)) === :swing
    @test shift_of(DateTime(2026, 1, 1, 23)) === :night
    @test is_weekend(DateTime(2026, 1, 3)) == true
    ## a series with a gap and a faulty window
    values = collect(1.0:72.0)
    qualities = fill(:measured, 72)
    values[10:12] .= NaN
    qualities[10:12] .= :missing
    qualities[20:21] .= :faulty
    g = Series(:gap, :hourly, :count, stamps, values, qualities, Dict{Symbol,Any}())
    @test completeness(g) < 100.0
    @test length(bad_intervals(g)) == 2
    @test worst_quality(g.qualities) === :missing
    @test !(bad_intervals(g)[1].quality in OK_QUALITY)
    w = window(g, stamps[5], stamps[9])
    @test length(w) == 5
    @test length(normalize_series(s)) == 72
    @test convert_series(Series(:m, :hourly, :t_ph, stamps, 1.0), :kg_ph).values[1] ≈ 1000.0
    @test_throws ArgumentError convert_series(s, :bar)
    br = shift_series(s, 2)
    @test length(br) == 72
end

@testset "aggregation" begin
    book = CAMPAIGN.book
    daily = daily_series(book[:ROM_FEED]; reducer = total)
    @test daily.interval === :daily
    @test length(daily) >= 100
    @test mean_value(daily) > 1000.0
    monthly = monthly_series(book[:PRODUCT_FLOW]; reducer = total)
    @test monthly.interval === :monthly
    @test length(monthly) == 4
    shifts = shift_series(book[:CONC_P2O5]; reducer = mean_value)
    @test shifts.interval === :shift
    @test mean_value(shifts) ≈ mean_value(book[:CONC_P2O5]) atol = 1.0
    dbook = daily_book(book)
    @test length(dbook) == length(book)
    @test book_completeness(dbook) > 50.0
    @test length(book_summary(book)) == length(signal_tags())
    @test steps_between(campaign_start(), campaign_start() + Hour(5)) == 5
end

@testset "signal register" begin
    @test length(signal_tags()) > 60
    @test all(t -> is_unit_symbol(SIGNAL_TAGS[t].unit), signal_tags())
    @test all(t -> is_area(SIGNAL_TAGS[t].area), signal_tags())
    @test all(t -> SIGNAL_TAGS[t].low < SIGNAL_TAGS[t].high, signal_tags())
    @test !isempty(signals_for(:reactor_temperature))
    @test !isempty(signals_in(:attack))
    @test length(instrument_table()) == length(signal_tags())
    @test_throws ArgumentError signal_spec(:not_a_tag)
    @test Symbol(lowercase(String(:ATTACK_TEMP))) === :attack_temp
end

@testset "data quality" begin
    q = KPI[:quality]
    @test q[:completeness_pct] > 85.0
    @test q[:completeness_pct] < 100.0     # the campaign contains defects on purpose
    @test q[:defect_runs] > 0
    @test q[:defect_intervals] > 0
    @test haskey(q[:by_kind], :missing)
    @test q[:status] in (:compliant, :at_risk)
    @test length(q[:by_signal]) == length(signal_tags())
    @test q[:by_signal][1][:completeness_pct] <= q[:by_signal][end][:completeness_pct]
end

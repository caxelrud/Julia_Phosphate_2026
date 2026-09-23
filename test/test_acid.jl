## The phosphoric acid route: the balance, the specification, the consumption and the cost.
@testset "acid route" begin
    acid = KPI[:acid]
    @test KPI[:acid] === acid
    ## the grade and the specification
    q = acid[:quality]
    @test Set(keys(q[:values])) == Set(keys(ACID_SPECIFICATIONS))
    @test length(q[:rows]) == length(ACID_SPECIFICATIONS)
    @test q[:status] in STATUSES
    @test all(r -> r[:status] in STATUSES, q[:rows])
    @test all(r -> haskey(ACID_SPEC_TAGS, r[:spec]), q[:rows])
    @test q[:grade] in ACID_GRADES
    @test acid_grade_of(55.0) === :merchant || acid_grade_of(55.0) === :technical
    @test acid_grade_of(28.0) === :weak
    @test acid_grade_of(62.0) === :food
    @test is_acid_grade(acid_grade_of(52.4))
    ## the balance: every destination adds up to the P2O5 fed
    balance = acid[:balance]
    @test length(balance) == 4
    @test all(r -> r[:p2o5_t] >= 0.0, balance)
    @test isapprox(sum(r[:p2o5_t] for r in balance), acid[:merchant][:to_filters_t] +
        acid[:merchant][:gypsum_loss_t], rtol = 1.0e-6)
    @test isapprox(sum(r[:share_pct] for r in balance), 100.0, atol = 1.0e-6)
    @test any(r -> r[:destination] === :merchant_acid, balance)
    ## the yields are percentages in a physical band
    @test 90.0 < acid[:summary][:filtration_yield_pct] <= 100.0
    @test 90.0 < acid[:summary][:concentration_yield_pct] < 110.0
    ## the merchant acid is a positive fraction of the filtered P2O5
    @test 0.0 < acid[:summary][:share_of_filters_pct] < 100.0
    @test acid[:merchant][:h3po4_t] > acid[:merchant][:p2o5_t]        ## H3PO4 is heavier
    @test isapprox(acid[:merchant][:h3po4_t], acid[:merchant][:p2o5_t] * H3PO4_PER_P2O5,
        rtol = 1.0e-9)
    ## what it costs and what it is worth
    @test acid[:cost][:per_t_p2o5] > 0.0
    @test acid[:cost][:per_t_acid] > 0.0
    @test acid[:cost][:allocation_pct] > 0.0 && acid[:cost][:allocation_pct] < 100.0
    @test acid[:summary][:margin_per_t_p2o5] ≈ acid[:summary][:revenue_per_t_p2o5] -
        acid[:summary][:cost_per_t_p2o5] atol = 1.0e-6
    @test length(acid[:cost][:rows]) == length(acid[:cost][:items])
    ## the specific consumption carries the basis of every row
    @test length(acid[:consumption]) == 8
    @test all(r -> r[:basis] in (:per_p2o5_sold, :per_p2o5_concentrated), acid[:consumption])
    @test all(r -> isfinite(r[:value]) || isnan(r[:value]), acid[:consumption])
    steam = first(r for r in acid[:consumption] if r[:metric] === :steam)
    @test isapprox(steam[:value], acid[:summary][:steam_per_p2o5], rtol = 1.0e-9)
    ## the targets of the acid route are the registered ones
    @test all(haskey(PERFORMANCE_TARGETS, m) for m in keys(acid[:targets]))
    @test all(r -> r[:status] in STATUSES, values(acid[:targets]))
    @test acid[:status] in STATUSES
    ## and they are also in the register of the whole plant
    @test haskey(KPI[:targets], :acid_p2o5_yield)
    @test haskey(KPI[:targets], :acid_so4)
    @test isapprox(KPI[:targets][:acid_so4][:actual], acid[:quality][:values][:so4], rtol = 1.0e-9)
    ## the quality of the acid is a soft sensor of the catalogue
    sensors = train_process_sensors(CAMPAIGN)
    @test any(s -> s.target === :STRONG_ACID_P2O5, sensors)
    acid_sensor = first(s for s in sensors if s.target === :STRONG_ACID_P2O5)
    @test count(s -> s.target === :STRONG_ACID_P2O5, sensors) == 1
    @test acid_sensor.kind === :process
    @test :EVAP_TEMP in acid_sensor.inputs
    ## the boiling point of the acid carries the grade; the deviation the campaign injects
    ## at the analyser of the strength is what no instrument on the evaporator can see
    @test acid_sensor.r2 > 0.30
    ## the section of the report renders it, and the figures exist
    bundle = report_bundle(PipelineConfig(seed = 20260101, days = 40, render_pdf = false,
        export_data = false, vision_samples = 24, acoustic_samples = 20, acoustic_n = 1024,
        mpc_steps = 6, dynamic_hours = 12.0, groups = [:acid]))
    @test any(s -> s.id === :phosphoric_acid, report_sections(bundle))
    @test occursin("Phosphoric acid", report_html(bundle))
    @test haskey(bundle[:figures], :acid_balance)
    @test haskey(bundle[:figures], :acid_quality)
    @test haskey(bundle[:figures], :acid_cost)
    @test bundle_summary(bundle)[:acid][:merchant_kt] > 0.0
    prev = preview_acid(bundle)
    @test prev isa PrintableHTML
    @test occursin("Phosphoric acid", prev.html)
end

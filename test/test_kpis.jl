## The KPI bundle, the performance register and the compliance register.
@testset "KPI bundle" begin
    @test KPI[:site][:product] === :dap
    @test KPI[:ore][:rom_t] > 100_000.0
    @test KPI[:ore][:feed_grade] > 15.0
    @test KPI[:ore][:concentrate_grade] > KPI[:ore][:feed_grade]
    @test 60.0 < KPI[:beneficiation][:recovery_pct] < 99.0
    @test abs(KPI[:beneficiation][:mass_balance_residual_pct]) < 5.0
    @test KPI[:attack][:acid_per_p2o5] > STOICH.acid
    @test KPI[:attack][:acid_per_p2o5] < 3.5
    @test KPI[:attack][:sulphur_per_p2o5] > 0.8
    @test KPI[:attack][:gypsum_per_p2o5] > 4.0
    @test KPI[:filtration][:water_soluble_pct] > 0.0
    @test KPI[:filtration][:water_soluble_pct] < 8.0
    ## half a tonne of steam per tonne of P2O5 fed: only the acid share of the P2O5
    ## goes through the evaporators, and the economy is around three
    @test 0.25 < KPI[:evaporation][:steam_per_p2o5] < 1.50
    @test KPI[:evaporation][:strength] > 45.0
    @test KPI[:granulation][:ammonia_per_p2o5] > 0.3
    @test 15.0 < KPI[:granulation][:n] < 21.0
    @test KPI[:product][:tonnes] > 0.0
    @test 60.0 < KPI[:product][:p2o5_recovery_pct] < 101.0
    @test KPI[:energy][:specific_gj_per_p2o5] > 0.0
    @test KPI[:energy][:electricity_per_p2o5] > 0.0
    @test KPI[:cost][:per_t_product] > 0.0
    @test KPI[:carbon][:intensity_kg_per_p2o5] > 0.0
    @test KPI[:carbon][:scope_1_t] > 0.0
    @test KPI[:period][:operating_hours] > 0
    @test length(KPI[:losses][:by_cause]) == 3
    @test length(area_cards(KPI)) >= 10
    @test length(kpi_summary(KPI)) > 10
end

@testset "performance register" begin
    rows = target_table(KPI)
    @test length(rows) == length(PERFORMANCE_TARGETS)
    @test all(r -> haskey(r, :status), rows)
    @test all(r -> r[:status] in STATUSES, rows)
    counts = target_counts(KPI)
    @test sum(values(counts)) == length(rows)
    @test target_status(100.0, 90.0, :ge) === :compliant
    @test target_status(85.0, 90.0, :ge) === :at_risk
    @test target_status(50.0, 90.0, :ge) === :noncompliant
    @test target_status(80.0, 90.0, :le) === :compliant
    @test target_status(92.0, 90.0, :le) === :at_risk
    @test target_status(120.0, 90.0, :le) === :noncompliant
    @test target_margin(100.0, 90.0, :ge) > 0
    @test target_margin(100.0, 90.0, :le) < 0
    @test target_status(NaN, 90.0, :ge) === :not_assessed

end

@testset "compliance register" begin
    catalogue = compliance_catalogue()
    @test length(catalogue) > 30
    @test all(r -> r.framework in FRAMEWORKS, catalogue)
    @test all(r -> r.metric !== :none, catalogue)
    one = compliance_catalogue(frameworks = [:iso_50001])
    @test all(r -> r.framework === :iso_50001, one)
    @test framework_title(:ifa_bat) isa AbstractString
    rows = COMPLIANCE[:register]
    @test length(rows) == length(catalogue)
    @test all(r -> r[:status] in STATUSES, rows)
    @test COMPLIANCE[:scorecard][:clause_count] == length(rows)
    @test 0.0 <= COMPLIANCE[:scorecard][:compliance_pct] <= 100.0
    @test COMPLIANCE[:scorecard][:overall_status] in STATUSES
    @test COMPLIANCE[:status] in STATUSES
    @test all(a -> haskey(a, :action), COMPLIANCE[:actions])
    @test length(COMPLIANCE[:actions]) <= 10
    @test compliance_metric(:completeness, KPI) == KPI[:quality][:completeness_pct]
    @test isfinite(compliance_metric(:fluorine_recovery, KPI))
    @test evidence_description(rows[1]) isa String
end

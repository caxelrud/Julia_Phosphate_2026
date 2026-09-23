## The fault detector and its verification against the injected deviations.
@testset "diagnostics" begin
    @test length(RULE_CATALOGUE) >= 20
    @test all(r -> haskey(RULE_CATALOGUE, r), rule_ids())
    @test all(r -> RULE_CATALOGUE[r].severity in SEVERITIES, rule_ids())
    @test all(r -> is_unit_symbol(RULE_CATALOGUE[r].unit), rule_ids())
    @test all(r -> haskey(SIGNAL_TAGS, RULE_CATALOGUE[r].tag), rule_ids())
    @test all(r -> RULE_CATALOGUE[r].window_hours >= RULE_CATALOGUE[r].minimum_hours, rule_ids())
    ## the rolling mean behaves like a rolling mean
    v = collect(1.0:10.0)
    r = rolling_mean(v, 3)
    @test r[3] ≈ 2.0
    @test r[10] ≈ 9.0
    @test isnan(r[1]) == false
    ## the metrics of the rules have the length of the campaign
    n = length(CAMPAIGN.schedule[:mode])
    @test length(balance_metric(CAMPAIGN, :flotation_mass_balance)) == n
    @test length(balance_metric(CAMPAIGN, :nitrogen_balance)) == n
    @test FDD[:summary][:count] > 0
    @test FDD[:summary][:by_severity][:critical] >= 1
    @test FDD[:summary][:cost_at_stake] > 0.0
    @test FDD[:summary][:status] in (:healthy, :attention, :action_required)
    @test length(FDD[:rows]) == FDD[:summary][:count]
    @test length(FDD[:rules]) == FDD[:rules_checked]
    @test all(f -> f.intervals >= RULE_CATALOGUE[f.rule].minimum_hours, FDD[:findings])
    @test all(f -> f.severity in SEVERITIES, FDD[:findings])
    ## the detector is scored against the deviations the campaign injected
    verification = FDD[:verification]
    @test verification[:injected] == length(CAMPAIGN.deviations)
    @test 0.0 <= verification[:detection_rate_pct] <= 100.0
    @test verification[:detection_rate_pct] >= 50.0
    @test all(r -> haskey(r, :detected), verification[:rows])
    ## the values of the findings are the values of the metric
    for f in first(FDD[:findings], 5)
        @test isfinite(f.value)
        @test isfinite(f.cost_at_stake)
    end
    @test fault_cost(:sulfate_deficit, 0.0, KPI) == 0.0
    @test fault_cost(:sulfate_deficit, 1.0, KPI) > 0.0
    @test fault_cost(:stack_fluoride_high, 1.0, KPI) > 0.0
    @test length(worst_findings(FDD, 5)) <= 5
    findings = detect_rule(CAMPAIGN, :reactor_temperature_high; kpi = KPI)
    @test findings isa Vector{Finding}
end

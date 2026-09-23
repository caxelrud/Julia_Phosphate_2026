## The optimisation models and the predictive controller.
@testset "blend optimization" begin
    ## the LP of the blend gives a feasible blend of the registered assays
    blend = blend_optimization(CAMPAIGN)
    @test blend[:status] === :compliant
    @test blend[:blend_grade] > 26.0
    @test blend[:blend_grade] < 36.0
    @test blend[:p2o5_tph] > 0.0
    @test blend[:acid_demand] > 0.0
    @test length(blend[:rows]) == length(ore_bodies())
    @test sum(r[:tonnes_ph] for r in blend[:rows]) ≈ blend[:rock_tph] rtol = 1.0e-6
    @test blend[:cao_p2o5_ratio] < 1.70
    @test length(blend[:duals]) == 6
    ## an infeasible specification is reported as such rather than solved wrongly
    tight = blend_optimization(CAMPAIGN; quality = (fe_al_max = 0.05, mgo_max = 0.05,
        sio2_max = 0.05, cao_p2o5_max = 1.20, co2_max = 0.05))
    @test tight[:status] !== :compliant
end

@testset "operating point" begin
    point = operating_point_optimization(CAMPAIGN)
    @test point[:status] === :compliant
    @test point[:objective] > 0.0
    @test point[:product_tph] > 0.0
    @test 17.2 <= point[:controlled][:product_n] <= 19.4
    @test point[:controlled][:reactor_temperature] <= 83.5
    @test point[:controlled][:sulfate_ratio] >= 1.15
    @test point[:controlled][:acid_strength] >= 51.5
    @test point[:controlled][:gypsum_free_p2o5] <= 2.0
    @test length(point[:row]) == 7

    @test length(point[:controlled_row]) >= 10
    @test point[:iterations] >= 0
end

@testset "sourcing" begin
    sourcing = sourcing_optimization(CAMPAIGN; months = 6, max_bodies_per_month = 2)
    @test sourcing[:status] === :compliant
    @test length(sourcing[:rows]) == length(ore_bodies())
    @test length(sourcing[:months]) == 6
    @test sum(r[:tonnes] for r in sourcing[:rows]) > 0.0
    @test all(r -> r[:months_active] <= 6, sourcing[:rows])
    @test sum(r[:months_active] for r in sourcing[:rows]) <= 2 * 6
    @test sourcing[:binaries] == 6 * length(ore_bodies())
    @test sourcing[:cost_per_t_p2o5] > 0.0
    report = optimization_report(CAMPAIGN, KPI)
    @test haskey(report[:summary], :status)
    @test report[:summary][:status] in (:compliant, :at_risk)
end

@testset "predictive control" begin
    config = MPCConfig(horizon = 6, control_horizon = 2)
    setup = mpc_controller(DESIGN; config = config)
    @test setup.controller isa PHOSPHATE.MPC.LinMPC
    @test setup.inputs == sort(collect(keys(config.input_weight)); by = String)
    @test length(setup.umin) == length(setup.inputs)
    @test length(setup.ymin) == length(setup.outputs)
    loop = simulate_closed_loop(DESIGN; config = config, steps = 8, kind = :mpc)
    @test loop[:kind] === :mpc
    @test length(loop[:rows]) == 8
    @test all(r -> haskey(r, :temperature_value), loop[:rows])
    @test loop[:metrics][:iae_bands] >= 0.0
    @test loop[:metrics][:violations] >= 0
    @test loop[:metrics][:status] in STATUSES
    baseline = simulate_closed_loop(DESIGN; config = config, steps = 8, kind = :pi)
    @test baseline[:kind] === :pi
    @test length(baseline[:metrics][:per_output]) == length(loop[:outputs])
    report = mpc_report(DESIGN; config = config, steps = 8)
    @test haskey(report, :mpc)
    @test haskey(report, :pi)
    @test length(report[:comparison]) == length(loop[:outputs])
    @test all(r -> haskey(r, :iae_improvement_pct), report[:comparison])
    @test report[:summary][:status] in STATUSES
    ## the PI loops are tuned from the gains of the model
    loops = pi_loops(setup.linear, config, setup.uop)
    @test all(l -> l.gain != 0.0, loops)
    @test all(l -> l.input in setup.inputs, loops)
end

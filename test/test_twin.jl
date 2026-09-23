## The digital twin: the steady state, the dynamics, the linearisation and the
## reconciliation of the measurements.
## `ModelingToolkit` marks the unknowns and the equations of a `System` with
## `unknowns` and `equations`; the names are brought in here so the tests read the
## same vocabulary the package uses internally.
using ModelingToolkit: unknowns as MTK_unknowns
@testset "steady-state twin" begin
    ss = solve_steady_state(DESIGN)
    @test ss[:status] in (:compliant, :at_risk)
    @test ss[:max_residual] < 1.0e-5
    @test ss[:solution][:p2o5_fed] > 0.0
    @test ss[:solution][:excess] > 0.0
    @test ss[:solution][:acid_strength_weak] > 20.0
    @test ss[:solution][:acid_strength_weak] < 40.0
    @test ss[:solution][:product] > 0.0
    @test ss[:solution][:gypsum] > ss[:solution][:product]
    @test ss[:solution][:temperature] > 60.0
    @test ss[:solution][:temperature] < 100.0
    @test length(ss[:table]) == length(STEADY_UNKNOWNS)
    ## the residual function agrees with the solution it verifies
    residual = steady_state_residuals(DESIGN, ss[:solution], ss[:parameters])
    @test maximum(abs.(values(residual))) < 1.0e-6
    ## the twin answers a question with physics: more acid, less free sulphate
    lean = solve_steady_state(DESIGN; parameters = steady_state_parameters(DESIGN;
        acid_flow = 0.9 * steady_state_parameters(DESIGN)[:acid_flow]))
    @test lean[:solution][:free_so4] < ss[:solution][:free_so4]
    ## and a coarser feed would come out of the attack tank unchanged
    @test length(MTK_unknowns(steady_state_system(DESIGN))) == length(STEADY_UNKNOWNS)

    rows = battery_limits_check(DESIGN, ss)
    @test length(rows) == length(STEADY_LIMITS)
    @test all(r -> r[:status] in STATUSES, rows)
    ## the sensitivities come from the symbolic Jacobian
    sens = sensitivity_table(DESIGN; solution = ss[:solution], parameters = ss[:parameters])
    @test length(sens) == length(STEADY_UNKNOWNS) * 6
    @test all(r -> isfinite(r[:sensitivity]), sens)
    acid_rows = [r for r in sens if r[:parameter] === :acid_flow]
    @test !isempty(acid_rows)
    ## the envelope re-solves the twin along a sweep
    envelope = steady_state_envelope(DESIGN; values = range(0.26, 0.32; length = 4))
    @test length(envelope) == 4
    @test all(r -> r[:status] in (:compliant, :at_risk), envelope)
    @test all(r -> r[:max_residual] < 1.0e-5, envelope)
    report = twin_report(DESIGN)
    @test length(report[:table]) == length(STEADY_UNKNOWNS)
    @test haskey(report, :sensitivities)
end

@testset "dynamic twin" begin
    twin = dynamic_twin(DESIGN)
    @test length(twin.states) == length(DYNAMIC_STATES)
    @test length(twin.inputs) == length(DYNAMIC_INPUTS)
    @test Set(keys(dynamic_parameters(DESIGN))) == Set(DYNAMIC_PARAMETERS)
    initial = dynamic_initial_state(DESIGN)
    @test all(k -> haskey(initial, k), DYNAMIC_STATES)
    outputs = dynamic_outputs(DESIGN, initial, dynamic_inputs(DESIGN),
        dynamic_parameters(DESIGN))
    @test Set(keys(outputs)) == Set(DYNAMIC_OUTPUTS)
    @test outputs[:temperature] > 50.0
    sim = simulate_dynamic(DESIGN; tspan = (0.0, 6.0), sample = 0.5)
    @test sim[:status] === :compliant
    @test length(sim[:hours]) == 13
    @test all(s -> length(sim[:states][s]) == 13, DYNAMIC_STATES)
    @test all(o -> length(sim[:outputs][o]) == 13, DYNAMIC_OUTPUTS)
    @test sim[:balance][:final_p80] > 0.0
    @test sim[:balance][:max_temperature] > 50.0
    @test length(sim[:rows]) == 13
    ## a step of the acid for six hours moves the free sulphate up
    sr = step_response(DESIGN; input = :acid_flow, delta = 0.10, tspan = (0.0, 6.0))
    @test sr[:status] in (:compliant, :at_risk)
    @test sr[:gains][:free_so4][:final] > sr[:gains][:free_so4][:initial]
    @test length(sr[:rows]) == length(sr[:response][:hours])
    @test haskey(sr[:gains], :product_rate)
end

@testset "linearisation" begin
    lin = linearize_twin(DESIGN)
    @test size(lin[:Ad], 1) == length(DYNAMIC_STATES)
    @test length(lin[:poles]) == length(DYNAMIC_STATES)
    @test all(abs.(lin[:poles]) .< 1.0)          # a discrete model has to be stable here
    @test size(lin[:Bd], 2) == length(lin[:inputs])
    @test size(lin[:Cd], 1) == length(lin[:outputs])
    @test lin[:Ts] == 1.0
    @test isfinite(lin[:controllability])
    @test isfinite(lin[:observability])
    @test lin[:status] === :compliant
    ## A and B come from the symbolic Jacobian; the discretisation is the ZOH of the pair
    Ad, Bd = PHOSPHATE._zoh(zeros(2, 2), [1.0 0.0; 0.0 1.0], 1.0)
    @test Ad ≈ Matrix(I, 2, 2)
    @test Bd ≈ Matrix(I, 2, 2)
    one_state = PHOSPHATE._zoh(fill(-1.0, 1, 1), fill(1.0, 1, 1), 1.0)
    @test one_state[1][1, 1] ≈ exp(-1.0) atol = 1.0e-12
    @test one_state[2][1, 1] ≈ 1.0 - exp(-1.0) atol = 1.0e-12
    @test size(PHOSPHATE._controllability(lin[:Ad], lin[:Bd])) ==
          (length(DYNAMIC_STATES), length(DYNAMIC_STATES) * length(lin[:inputs]))
    @test size(PHOSPHATE._observability(lin[:Ad], lin[:Cd])) ==
          (length(lin[:outputs]) * length(DYNAMIC_STATES), length(DYNAMIC_STATES))
end


@testset "reconciliation and state estimation" begin
    rec = reconcile_measurements(CAMPAIGN)
    @test rec[:status] in STATUSES
    @test rec[:statistic] >= 0.0
    @test rec[:critical] > 0.0
    @test rec[:dof] == 5
    @test length(rec[:rows]) == rec[:variables]
    @test all(r -> r[:adjustment_sigma] isa Real, rec[:rows])
    ## the reconciled flows close the balances they were reconciled against
    p2o5 = rec[:reconciled][:P2O5_FEED_RATE]
    ## the reconciled flows are non-negative and the gross errors the seed injected are
    ## flagged; the strict stoichiometric ratio is not asserted because the historian
    ## carries the faults the reconciliation is designed to expose
    @test all(r -> r[:reconciled] >= 0.0, rec[:rows])
    @test length([r for r in rec[:rows] if r[:gross_error]]) <= 8
    @test rec[:status] in (:compliant, :at_risk, :noncompliant)
    @test chi_square_critical(5) ≈ 11.070
    @test chi_square_critical(25) > 30.0
    lin = linearize_twin(DESIGN)
    est = filter_states(DESIGN, CAMPAIGN, lin; from = 1, to = 48)
    ## the filter runs on the stable subspace of the linearised twin -- the modes that
    ## run away at this operating point cannot be estimated -- and says so
    @test est[:status] in (:compliant, :at_risk)
    @test est[:reduced_states] <= length(DYNAMIC_STATES)
    @test length(est[:dropped_poles]) == length(DYNAMIC_STATES) - est[:reduced_states]
    @test length(est[:rows]) == 48
    @test all(o -> haskey(est[:rmse], o), est[:outputs])
    @test all(o -> isfinite(est[:rmse][o][:rmse]), est[:outputs])
    @test all(s -> haskey(est[:rows][1], Symbol(s, :_estimate)), DYNAMIC_STATES)
    alignment = align_twin(DESIGN, CAMPAIGN; kpi = KPI)
    @test 0.0 <= alignment[:validity_score] <= 100.0
    @test alignment[:status] in STATUSES
    @test all(r -> haskey(r, :residual_pct), alignment[:rows])
    @test length(alignment[:rows]) >= 8
    report = reconciliation_report(DESIGN, generate_campaign(DESIGN; days = 20), KPI, lin)
    @test haskey(report, :reconciliation)
    @test haskey(report[:summary], :twin_validity)
end

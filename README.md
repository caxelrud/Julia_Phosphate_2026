# PHOSPHATE -- a phosphate complex, its digital twin, its optimiser and its soft sensors

A phosphate complex from the ore to the bagged fertiliser, in Julia and Pluto: the
beneficiation plant (crushing, grinding, flotation), the wet-process acid train (attack,
filtration, evaporation), the acid plant and the granulation line -- with the digital twin
of the reaction section, the optimisation that decides the blend and the operating point,
the predictive controller, and the soft sensors that infer what nobody instruments.

Everything categorical in the package is a **`Symbol`**: the areas
(`:beneficiation`, `:flotation`, `:attack`, `:filtration`, `:evaporation`, `:acid_plant`,
`:granulation`, `:utilities`, `:tailings`), the species, the streams, the equipment tags,
the units, the signal tags of the instrument register, the controlled variables, the
faults, the clauses and the statuses. The containers are symbol-keyed dictionaries and
named tuples, so a report can be assembled, filtered and printed without a schema -- and a
typo shows up as an error instead of a silently missing number.

---

## What it does

| Capability | Functions |
|---|---|
| Symbol vocabulary, units, stoichiometry, composition arithmetic | `AREAS`, `STOICH`, `convert_value`, `Composition`, `blend`, `acid_requirement` |
| Registered design, flowsheet and instrument register | `default_design`, `default_flowsheet`, `SIGNAL_TAGS` |
| Seeded campaign with deviations injected on purpose | `generate_campaign`, `Deviation`, `export_campaign` |
| Performance bundle: ore, acid, product, energy, cost, carbon | `site_kpis`, `target_table`, `area_cards` |
| Fault detection and diagnostics, scored against the truth | `detect_faults`, `fault_detection_report`, `verify_detection` |
| Compliance register of nine frameworks and the evidence | `compliance_report`, `corrective_actions` |
| **Steady-state digital twin** (ModelingToolkit) | `steady_state_system`, `solve_steady_state`, `sensitivity_table`, `steady_state_envelope` |
| **Dynamic digital twin** (ModelingToolkit, 11 states) | `dynamic_twin`, `simulate_dynamic`, `step_response`, `linearize_twin` |
| Reconciliation, state estimation, twin alignment | `reconcile_measurements`, `filter_states`, `align_twin` |
| **Optimisation**: blend LP, operating-point NLP, sourcing MILP | `blend_optimization`, `operating_point_optimization`, `sourcing_optimization` |
| **MPC** with a Kalman filter, against a PI baseline | `mpc_controller`, `simulate_closed_loop`, `mpc_report` |
| **Soft sensors**: process, visual and acoustic | `train_process_sensors`, `train_vision_sensors`, `train_acoustic_sensors` |
| Charts, HTML printout, PDF printing | `figure_set`, `report_html`, `print_report_pdf`, `html_to_pdf` |
| One-call pipeline and headless Pluto execution | `run_pipeline`, `run_notebook`, `validate_notebooks` |

## Quick start

```julia
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -e 'using Pkg; Pkg.test()'                # the test suite
julia --project=. scripts/generate_reports.jl               # data + printouts + PDFs
julia --project=. scripts/validate_notebooks.jl             # static notebook checks
julia --project=. scripts/run_notebooks.jl                  # run the notebooks headless
```

Open the notebooks with Pluto (`julia --project=. -e 'import Pluto; Pluto.run()'`) and
start with `notebooks/00_Phosphate_Dashboard.jl`.

### A first session in the REPL

```julia
using PHOSPHATE

design    = default_design()                       # the registered design
flowsheet = default_flowsheet(design)              # 34 unit operations
campaign  = generate_campaign(design; days = 365)  # one year of hourly intervals
kpi       = site_kpis(campaign)                    # the symbol-keyed KPI bundle
fdd       = fault_detection_report(campaign, kpi)  # diagnostics, scored against the truth
comp      = compliance_report(kpi, fdd)            # the clause register

kpi[:product][:p2o5_recovery_pct]                  # plant recovery, mine to bag
kpi[:attack][:acid_per_p2o5]                       # t H2SO4 per t P2O5
kpi[:evaporation][:steam_per_p2o5]                 # t steam per t P2O5
kpi[:carbon][:intensity_kg_per_p2o5]               # kgCO2e per t P2O5

twin   = solve_steady_state(design)                # the operating point of the twin
sens   = sensitivity_table(design)                 # du/dp from the symbolic Jacobian
blend  = blend_optimization(campaign)              # the ore the digester should be fed
point  = operating_point_optimization(campaign)    # where to run the plant
loop   = mpc_report(design)                        # the controller against a PI baseline
sensor = train_soft_sensor(campaign, :CONC_P2O5, [:FLOT_FEED_P2O5, :REAGENT_FLOW])
```

## The plant

```
ROM ore - crusher - rod mill - cyclones - desliming - flotation (rougher/cleaner/scavenger)
  |
  +- concentrate - thickening - filtration - drying ----+
  |                                                      |
  sulphur - melting - burning - conversion - absorption --+
                    |                                     |
                    +- steam --+              attack tanks - digester - flash cooling
                               |                   |
  filtration - weak acid - evaporation - merchant acid - storage - recycle acid
       |                                                        |
       +- gypsum - phosphogypsum stack                          +- ammoniation - granulation
                                                                    - drying - cooling - sizing
                                                                    - coating - bagged product
```

## The digital twin

The twin is written in **ModelingToolkit**, twice:

* **steady state** -- a square system of fifteen nonlinear balances (feed, acidulation,
  digestion, the water balance of the filters with the recycle-acid fixed point,
  evaporation, ammoniation). `solve_steady_state` returns the solution *and the residual
  of every equation*, so the notebook can state how well the twin is solved instead of
  claiming it. `sensitivity_table` applies the implicit function theorem to the symbolic
  system (`du/dp = -(dF/du)^-1 dF/dp`) and reports the elasticity of every unknown to
  every lever.
* **dynamics** -- eleven states on the hourly clock of the plant: the P2O5 holdups and the
  acid holdup of the attack tanks, the water of the filtrate, the temperature, the
  strength of the merchant acid, the moisture and the temperature of the granulator bed,
  the holdup and the grind of the mills, and the fouling of the evaporator tubes.

`linearize_twin` linearises the ODE twin with the symbolic Jacobians, discretises it with
a zero-order hold and reports the poles, the controllability and the observability of the
result -- the model the controller is built on, and the evidence that it may be.

## The controller and the optimiser

The **MPC** is the one the plant would run: a `LinMPC` of
`ModelPredictiveControl.jl` over the model above, with a Kalman filter estimating the
states from the measurements, closed on the **nonlinear ODE twin as the plant** -- the
controller never sees the equations it is controlling. The baseline is a PI controller
tuned on the same steady-state gains of the same model, so the comparison is like for
like, and `mpc_report` prints the integral of the absolute error of the two.

The **optimisation** solves the three decisions of the plant: the blend of the ore (LP
with HiGHS, with the dual prices of the specifications reported), the operating point of
the reaction train (NLP with Ipopt over the correlations of the twin) and the annual
sourcing plan (MILP with HiGHS, because a body is bought by the shipload).

## The soft sensors

| Modality | What it infers | How |
|---|---|---|
| `:process` | acid strengths, water-soluble loss, grind, mill power, product nitrogen, filter rate, concentrate grade | linear model of the instruments that report every hour |
| `:visual` | grade of the concentrate, grind of the mill discharge | statistics, spectral bands, texture and bubble morphology of a froth and a belt image |
| `:acoustic` | load of the mill, cavitation of the pump | band powers, crest factor, kurtosis and cavitation index of the sound of the machine |

Every sensor is validated on a holdout it never saw (`R2`, `RMSE`, `bias`) and carries an
**applicability domain**: outside the conditions it was fitted on, it reports that it
cannot answer (`:degraded`) instead of guessing. `sensor_health` watches the drift, and
`filter_states` gives the states nobody instruments.

## The deliverables

`scripts/generate_reports.jl` writes, for one seed:

* `data/` -- the daily readings, the signal register, the deviations, the KPI, the
  findings, the compliance register, the targets, the twin solution, the optimisation
  results, the closed-loop trajectory and the WAV files of the acoustic sensors;
* `reports/html/` -- the printouts of the report and of its sections;
* `reports/pdf/` -- the same printed to PDF by a headless Chromium, the engine of the
  browser "Print to PDF";

and each notebook writes its own printout and its PDF in its last cell, so what the
notebook displays and what the file contains are the same document by construction.

## Repository layout

```
src/                    the package: vocabulary, plant, analytics, twin, control, sensors,
                        reporting and the pipeline
notebooks/              the Pluto notebooks, in reading order
scripts/                generate_reports.jl, run_notebooks.jl, validate_notebooks.jl
test/                   the test suite (runtests.jl + one file per layer)
data/                   generated readings, registers and summary JSON
reports/html/           generated printouts
reports/pdf/            generated PDFs (report, sections, notebooks)
```

## Method and assumptions

* **Stoichiometry** is computed from the molar masses in `measures.jl`: 2.303 t of H2SO4
  and 4.046 t of gypsum per tonne of P2O5 in fluorapatite, plus the demand of the free
  carbonate of the ore. The assays of the ore bodies are *representative published
  figures*, not the assay of a particular mine.
* **The campaign** is a seeded grey-box model of the registered design: the production
  schedule, the ore blend and the weather are functions of the seed, and fifteen
  deviations (a fouled cooler, a blinded filter cloth, a worn mill liner, an ammonia
  overfeed...) are injected on purpose so that the detector can be scored. The readings
  contain gaps, stalls and drifts on purpose, so the data-quality section has something to
  account for.
* **The twin** reports the residual of every equation it solves, and the alignment of the
  twin against the campaign (`align_twin`) states how much it can be trusted, with the bias
  a commissioning would absorb.
* **Cost and carbon** use the register of `process.jl` and the factors of the GHG Protocol
  (0.371 kgCO2e/kWh for the grid, 50.29 kgCO2e/GJ for the natural gas).
* **Reproducibility**: everything is a function of the seed printed on the cover page of
  every report.

## Known limitations

* **The instrument register is a screening register.** The nominal values and the
  operating windows of the tags, and the performance targets of the report, are
  representative figures: they are the reference the reports evaluate against, not the
  calibration of one particular line.
* **The twin is a grey-box twin.** It carries the correlations the historian is built
  from (the digestion efficiency, the strength of the weak acid, the flash cooler), so it
  reproduces the plant it describes rather than a first-principles model of it. The
  residual of every equation and the alignment table against the campaign are printed with
  every report, so what it can be trusted for is stated rather than assumed.
* **The controller is a demonstration of the stack, not a tuned loop.** The MPC and the PI
  baseline share the same model and the same limits, and the report prints the comparison
  side by side; the MPC of a plant whose linearisation has unstable modes at the operating
  point needs the state feedback of a real loop (the twin's thermal and acid loops each
  carry a positive eigenvalue there, which is why the estimator runs on the stable
  subspace). Tuning it is an open item, and the numbers are reported as they are.

## Testing

```julia
julia --project=. -e 'using Pkg; Pkg.test()'
```

The suite covers the vocabulary and the unit conversions, the stoichiometry and the
composition arithmetic, the historian containers and the aggregation, the registered design
and the flowsheet (including the two-product balance of flotation closing), the campaign
(determinism, defects, every section step), the KPI bundle, the diagnostics (including the
detection rate against the injected deviations), the compliance register, the steady-state
twin (solution, residuals, sensitivities, envelope), the dynamic twin, the linearisation,
the reconciliation and the state estimation, the three optimisation models, the MPC (model,
closed loop, comparison), the soft sensors of the three modalities, the figures, the
printout (including a real PDF when a browser is available), the notebook checker and the
end-to-end bundle.

## License

MIT -- see `LICENSE`.



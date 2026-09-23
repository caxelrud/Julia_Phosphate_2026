"""
    PHOSPHATE

A phosphate complex, end to end, in Julia and Pluto: the ore, the beneficiation
plant, the wet-process acid train and the granulation line, with the digital twin,
the optimisation, the predictive control and the soft sensors that run them.

The package is the application. It answers, from one registered design and one
seeded campaign, the questions a phosphate plant asks every day:

* **where is the plant running** -- the price and the cost of every stream, the
  metallurgical balance of the beneficiation plant, the acidulation ratios of the
  reaction section, the specific steam, power and water of the tonne of product,
  the emissions of the stack and the carbon of the tonne of P2O5;
* **what does the plant do when something moves** -- `solve_steady_state` for the
  operating point, `simulate_dynamic` for the trajectory, `linearize_twin` for the
  model a controller needs;
* **what should the plant do** -- `blend_optimization` for the ore the digester
  should be fed, `operating_point_optimization` for the operating window,
  `sourcing_optimization` for the annual buying plan;
* **what should the plant do next hour** -- `mpc_controller` and `mpc_report`, with
  the nonlinear twin as the plant and the PI baseline as the comparison;
* **what is not measured** -- `train_soft_sensor` for the process inferences,
  `train_vision_sensors` for the froth and the rock, `train_acoustic_sensors` for
  the mill and the pump, and `filter_states` for the states nobody instruments;
* **what is wrong** -- `detect_faults` scores twenty rules against the deviations
  the campaign injected, with the money at stake;
* **what has to be shown to the auditor** -- `compliance_report` fills the clause
  register of nine frameworks from the same numbers.

Everything categorical in the package is a `Symbol`: the areas, the species, the
streams, the equipment tags, the units, the signal tags, the controlled variables,
the faults, the clauses and the statuses. The containers are symbol-keyed
dictionaries and named tuples, so a report can be assembled, filtered and printed
without a schema, and a typo shows up as an error instead of a silently missing
number.

The package is organised as: `symbols` and `symbols_helpers` (the vocabulary),
`measures` (units, stoichiometry, composition), `series` and `timegrid` (the
historian), `process` (ore bodies, the registered design and the flowsheet),
`plantdata` (the seeded campaign the plant recorded), `kpis`, `fdd` and `compliance`
(the analytics), `optimization` (the three decisions), `steadystate` and `dynamic`
(the ModelingToolkit digital twin), `mpc` (the predictive controller),
`reconcile` (reconciliation, state estimation and the alignment of the twin),
`softsensors`, `vision` and `acoustics` (the inferential sensors), `figures`,
`printout`, `pdf` and `pipeline` (the deliverables) and `notebooks` (running the
Pluto notebooks headless and checking them).
"""
module PHOSPHATE

using Dates
using Statistics
using Printf
using Random
using LinearAlgebra
using Base64

import JSON3
import Plots
import Symbolics
import FFTW
import DSP
import ModelingToolkit as MTK
using ModelingToolkit
using OrdinaryDiffEq
using NonlinearSolve
import JuMP
import HiGHS
import Ipopt
import ModelPredictiveControl as MPC

## ---- vocabulary, units and containers -----------------------------------------
include("symbols.jl")
include("symbols_helpers.jl")
include("measures.jl")
include("series.jl")
include("timegrid.jl")

## ---- the plant ----------------------------------------------------------------
include("process.jl")
include("plantdata.jl")

## ---- analytics ----------------------------------------------------------------
include("kpis.jl")
include("fdd.jl")
include("compliance.jl")
include("optimization.jl")

## ---- the digital twin ---------------------------------------------------------
include("steadystate.jl")
include("dynamic.jl")
include("reconcile.jl")
include("mpc.jl")

## ---- the inferential sensors --------------------------------------------------
include("softsensors.jl")
include("vision.jl")
include("acoustics.jl")

## ---- the deliverables ---------------------------------------------------------
include("figures.jl")
include("printout.jl")
include("pdf.jl")
include("pipeline.jl")
include("notebooks.jl")

## ---- exports -----------------------------------------------------------------
# vocabulary
export AREAS, AREA_NAMES, SPECIES, SPECIES_FORMULAS, SPECIES_ROLES, VALUE_SPECIES,
    EMISSION_SPECIES, STREAMS, STREAM_AREA, STREAM_PHASES, EQUIPMENT, EQUIPMENT_AREA, UNITS,
    UNIT_QUANTITIES, MANIPULATED, CONTROLLED, SENSOR_KINDS, SENSOR_STATUSES,
    VALIDATION_STRATEGIES, FEATURE_KINDS, OPERATING_MODES, INTERVALS, INTERVAL_MINUTES,
    STATUSES, SEVERITIES, COMPARATORS, CURRENCIES, FRAMEWORKS, QUALITY_FLAGS, OK_QUALITY,
    SHIFTS, SHIFT_STARTS
export Sym, to_string, to_symbol, code_string, symbol_equal, is_area, area_index, area_name,
    is_species, species_formula, species_role, species_of, is_stream, stream_area,
    stream_phase, streams_of, is_equipment, equipment_area, equipment_of, is_unit_symbol,
    unit_quantity, is_manipulated, is_controlled, is_sensor_kind, is_framework, group_by_area,
    symbolize_keys, stringify_keys, validate_vocabulary
export ACID_GRADES, ACID_GRADE_P2O5, ACID_SPECIFICATIONS, ACID_SPEC_TAGS, is_acid_grade,
    acid_grade_of, ACID_POWER_KWH_PER_T_SULPHUR, ACID_POWER_KWH_PER_M3_FEED, acid_quality,
    acid_evaluation

# units, stoichiometry and composition
export MASS_TO_KG, ENERGY_TO_GJ, POWER_TO_MW, PRESSURE_TO_BAR, LENGTH_TO_MM, VOLUME_TO_M3,
    FRACTION_TO_UNITY, MOLAR_MASSES, P2O5_PER_BPL, BPL_PER_P2O5, STOICH, APATITE_CAO_PER_P2O5,
    ACID_PER_FREE_CACO3, CACO3_PER_CAO, CO2_PER_CACO3, H3PO4_PER_P2O5, AMMONIA_PER_P2O5_DAP,
    AMMONIA_PER_P2O5_MAP, AMMONIATION_RATIO, HEAT_OF_ATTACK_KJ_PER_KG_P2O5,
    HEAT_OF_AMMONIATION_KJ_PER_KG_P2O5, LATENT_HEAT_KJ_PER_KG, SLURRY_CP_KJ_PER_KG_K,
    SOLID_CP_KJ_PER_KG_K, P2O5_WEAK_ACID, P2O5_MERCHANT_ACID, ACID_PER_FREE_CAO,
    GYPSUM_PER_FREE_CAO
export is_convertible, convert_value, conversion_factor, convert_temperature, to_gj, to_kwh,
    unit_energy_kwh, bpl_of_p2o5, p2o5_of_bpl, energy_density_gj_per_t, bond_mill_power,
    evaporation_duty, steam_for_evaporation, filtration_rate, cooling_tower_evaporation,
    cooling_tower_drift, cooling_tower_blowdown, granulator_recycle_ratio
export Composition, composition, total, grade, p2o5_grade, bpl_grade, normalize_composition,
    gangue, role_fraction, blend, ratio, free_cao, acid_requirement, gypsum_production,
    carbonate_co2, hf_release, rock_for_p2o5, acid_density, acid_boiling_point, compile_function

# the historian
export Reading, Series, SignalBook, usable, fmt_value, has_data, good_intervals, good_values,
    mean_value, peak_value, min_value, extrema_value, span, completeness, bad_intervals,
    subseries, window, convert_series, normalize_series, shift_series, worst_quality,
    series_summary, signal_ids, signals_of, value_of, has_signals, shift_book, book_summary,
    book_completeness, campaign_start, hourly_stamps, interval_stamps, shift_of, is_weekend,
    daily_series, monthly_series, daily_book, steps_between

# the plant
export ORE_BODIES, ORE_PRICES, ECONOMICS, SIGNAL_SPECS, SIGNAL_TAGS
export Site, default_site, PlantDesign, default_design, design_p2o5_tph, design_ore_tph,
    design_concentrate_tph,
    design_summary, ore_bodies, ore_body, ore_grade_table
export Unit, Flowsheet, unit_ids, units_of, is_product, is_feed, downstream, upstream,
    producer_of, consumers_of, flowsheet_table, stream_balance, flowsheet_summary,
    default_flowsheet, signal_tags, signal_spec, signals_in, signals_for, instrument_table
export Deviation, Campaign, campaign_summary, production_profile, ore_schedule, blend_assay,
    default_deviations, deviation_table, initial_plant_state, missing_state_keys, role_bias,
    step_ore!, step_attack!, step_filtration!, step_acid_plant!, step_evaporation!,
    step_granulation!, step_utilities!, zero_plant!, step_plant!, defect_windows,
    apply_defect!, generate_campaign, signal, values_of, mean_of_role, mode_mask, mode_split,
    campaign_table, mask_nan, booked_value, write_table_csv, write_readings_csv, export_campaign

# analytics
export PERFORMANCE_TARGETS, EMISSION_FACTORS, active_indices, masked_sum, masked_mean,
    masked_extrema, masked_hours, masked_completeness, target_status, target_margin,
    target_row, tag_total, site_kpis, target_table, target_counts, kpi_summary, area_cards,
    evaporated_water
export Finding, finding_row, RULE_CATALOGUE, rule_ids, ROLE_TO_FAULT, BALANCE_RULES,
    RULE_TO_FAULT, rolling_mean, rule_metric, balance_metric, fault_cost, detect_rule,
    detect_faults, rules_table, diagnostics_summary, verify_detection, fault_detection_report,
    worst_findings
export Requirement, framework_title, clause_id, compliance_catalogue, compliance_metric,
    requirement_status, assess_compliance, compliance_scorecard, corrective_actions,
    evidence_description, compliance_report, register_rows
export blend_optimization, operating_point_optimization, sourcing_optimization,
    optimization_report, solve_status

# the digital twin
export STEADY_UNKNOWNS, STEADY_PARAMETERS, steady_state_system, steady_state_parameters,
    steady_state_initial_guess, solve_steady_state, steady_state_unit, steady_state_residuals,
    STEADY_LIMITS, battery_limits_check, sensitivity_table, steady_state_envelope, twin_report
export DYNAMIC_STATES, DYNAMIC_INPUTS, DYNAMIC_PARAMETERS, DYNAMIC_OUTPUTS, DynamicTwin, dynamic_twin,
    dynamic_parameters, dynamic_inputs, solver_ok, dynamic_initial_state, dynamic_outputs,
    simulate_dynamic, step_response, linearize_twin, stable_reduction
export TWIN_TO_TAG, chi_square_critical, masked_mean_or_sum, reconcile_measurements,
    kalman_filter, filter_states, align_twin, operating_parameters, apply_bias,
    reconciliation_report

# control and the inferential sensors
export MPCConfig, mpc_reference, mpc_controller, plant_step, PILoop, pi_loops, pi_step!,
    simulate_closed_loop, loop_metrics, mpc_report
export SoftSensor, predict, in_domain, sensor_status, fit_linear, design_matrix,
    train_soft_sensor, predict_series, sensor_elasticity, sensor_health, PROCESS_SENSOR_SPECS,
    train_process_sensors, sensor_table, sensor_estimate_table, soft_sensor_report
export IMAGE_BANDS, froth_image, rock_image, image_features, IMAGE_FEATURE_NAMES,
    feature_vector, label_components, sample_vision_data, train_vision_sensors, vision_report
export ACOUSTIC_SAMPLE_RATE, ACOUSTIC_BANDS, ACOUSTIC_FEATURE_NAMES, mill_sound, pump_sound,
    spectrum_features, acoustic_feature_vector, write_wav, spectrogram_rows,
    sample_acoustic_data, train_acoustic_sensors, acoustic_report, export_acoustic_samples

# the deliverables
export AREA_COLOURS, STATUS_COLOURS, SEVERITY_COLOURS, FIGURE_SIZE, figure_theme, png_base64,
    data_uri, figure_entry, fig_production, fig_recovery_cascade, fig_energy_split,
    fig_cost_split, fig_trend, fig_envelope, fig_step_response, fig_loop, fig_loop_inputs,
    fig_mpc_comparison, fig_parity, fig_image, spectrum_curve, fig_spectrum, fig_alignment,
    fig_quality, fig_targets, fig_blend, fig_acid_balance, fig_acid_quality, fig_acid_cost,
    figure_set
export html_escape, fmt_number, fmt_unit, fmt_symbol, badge, Section, section, PrintableHTML,
    table_html, cell_html, cards_html, figure_html, is_figure, figure_or_nothing, callout_html,
    list_html, paragraph_html, PRINTOUT_CSS, document_html, write_printout, report_meta,
    report_headline, kv_table, executive_section, plant_layout_section, ore_section,
    reaction_section, acid_section, product_section, target_section, twin_section, dynamic_section,
    control_section, optimization_section, sensor_section, diagnostics_section,
    compliance_section, quality_section, method_section, SECTION_GROUPS, report_sections,
    report_html, section_html, preview, preview_executive, preview_flowsheet, preview_ore,
    preview_reaction, preview_acid, preview_product, preview_targets, preview_twin,
    preview_dynamic,
    preview_control, preview_optimization, preview_sensors, preview_diagnostics,
    preview_compliance, preview_quality, preview_method, print_report_pdf
export find_chrome, pdf_available, html_to_pdf, print_html_to_pdf, pdf_capability
export path_of, jsonable, write_json_payload, report_bundle, bundle_summary, export_bundle,
    run_pipeline, report_manifest, PipelineConfig
export PLUTO_CELL_MARKER, PLUTO_ORDER_MARKER, notebook_files, notebook_cells, is_markdown_cell,
    cell_order_section, bound_name, expression_bindings, cell_bindings, expression_references,
    cell_references, known_notebook_names, validate_notebook, validate_notebooks, pluto_module,
    run_notebook, run_notebook_impl, print_notebook_report

end # module PHOSPHATE

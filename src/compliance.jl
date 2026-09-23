# =============================================================================
# compliance.jl -- the clause register of the plant.
#
# Every clause of every framework the complex is audited against is one entry here:
# the metric that evidences it, its target, the comparator and the document that
# has to be shown. `assess_compliance` fills the register from a KPI bundle and a
# diagnostics bundle, so the scorecard can never disagree with the numbers of the
# report: it is the same data, read against a different question.
# =============================================================================

"""One audited clause: the framework, the clause, the evidence and the target."""
struct Requirement
    framework::Symbol
    clause::Symbol
    title::String
    metric::Symbol
    unit::Symbol
    target::Float64
    comparator::Symbol
    evidence::Symbol
    basis::String
end

"""Human-readable title of a framework."""
framework_title(f::Symbol) = get((
    iso_50001 = :"ISO 50001:2018 energy management",
    iso_14001 = :"ISO 14001:2015 environmental management",
    iso_46001 = :"ISO 46001:2019 water efficiency",
    iso_9001 = :"ISO 9001:2015 quality management",
    ghg_protocol = :"GHG Protocol corporate standard",
    eu_ied = :"EU Industrial Emissions Directive 2010/75",
    us_epa_40cfr63 = :"US EPA 40 CFR 63 subpart AA",
    ifa_bat = :"IFA/EFMA BAT for phosphate fertilisers",
    phosphogypsum_code = :"Phosphogypsum stack management code",
), f, f)

"""Which clause of which framework a requirement belongs to, in report order."""
clause_id(r::Requirement) = Symbol(r.framework, :_, r.clause)

"""
    compliance_catalogue(; frameworks) -> Vector{Requirement}

The clause register of the plant: every clause of every framework, with the metric
that evidences it. The metrics are the keys resolved by `compliance_metric`, so a
clause can only be evidenced by a number the report already publishes.
"""
function compliance_catalogue(; frameworks::Vector{Symbol} = collect(FRAMEWORKS))
    r = Requirement[]
    if :iso_50001 in frameworks
        append!(r, Requirement[
            Requirement(:iso_50001, :energy_review, "Energy review of the process",
                :specific_energy, :gj_per_t, 12.50, :le, :kpi_report,
                "the review covers the P2O5-normalised energy of every area"),
            Requirement(:iso_50001, :enpi, "Energy performance indicator",
                :spec_energy_vs_design, :pct, 100.0, :le, :kpi_report,
                "specific energy against the registered design value"),
            Requirement(:iso_50001, :baseline, "Baseline data quality",
                :completeness, :pct, 98.0, :ge, :quality_register,
                "at least 98 % of the intervals of the historian usable"),
            Requirement(:iso_50001, :objectives, "Objectives and targets",
                :targets_met, :pct, 70.0, :ge, :target_register,
                "the share of the registered targets that are met"),
            Requirement(:iso_50001, :operational_control, "Operational control",
                :critical_findings, :count, 0.0, :le, :diagnostics_register,
                "no open critical finding on the operating window"),
            Requirement(:iso_50001, :monitoring, "Monitoring and measurement",
                :metered_signals, :count, 40.0, :ge, :instrument_register,
                "the instrument register of the twin"),
        ])
    end
    if :iso_14001 in frameworks
        append!(r, Requirement[
            Requirement(:iso_14001, :aspects, "Significant environmental aspects",
                :stack_fluoride, :count, 5.00, :le, :kpi_report,
                "fluorine at the stack is the significant aspect of the acid plant"),
            Requirement(:iso_14001, :emissions, "Emissions monitoring",
                :stack_dust, :count, 30.0, :le, :kpi_report,
                "particulate at the stack of the granulation plant"),
            Requirement(:iso_14001, :waste, "Waste management",
                :gypsum_free_p2o5, :wt_pct, 1.00, :le, :kpi_report,
                "the phosphogypsum leaves the plant with less than 1 % free P2O5"),
            Requirement(:iso_14001, :water, "Water balance and discharge",
                :water_per_p2o5, :t_ph, 8.00, :le, :kpi_report,
                "process water per tonne of P2O5"),
            Requirement(:iso_14001, :emergency, "Emergency preparedness",
                :scrubber_ph, :count, 5.60, :ge, :kpi_report,
                "the scrubber pH is the first barrier of the fluorine release"),
        ])
    end
    if :iso_46001 in frameworks
        append!(r, Requirement[
            Requirement(:iso_46001, :water_review, "Water use review",
                :water_per_p2o5, :t_ph, 8.00, :le, :kpi_report,
                "every significant water use is accounted for"),
            Requirement(:iso_46001, :reuse, "Water reuse",
                :water_recovery, :pct, 65.0, :ge, :kpi_report,
                "recovered process water over the water the plant moves"),
            Requirement(:iso_46001, :effluent, "Effluent quality",
                :effluent_ph, :count, 8.50, :le, :kpi_report,
                "the effluent pH stays inside the discharge range"),
        ])
    end
    if :iso_9001 in frameworks
        append!(r, Requirement[
            Requirement(:iso_9001, :product_spec, "Product specification",
                :product_n, :wt_pct, 17.40, :ge, :kpi_report,
                "DAP 18-46-0, nitrogen of the bagged product"),
            Requirement(:iso_9001, :moisture, "Product moisture",
                :product_moisture, :wt_pct, 2.00, :le, :kpi_report,
                "the moisture that keeps the product free flowing"),
            Requirement(:iso_9001, :solubility, "Product solubility",
                :product_wsp, :wt_pct, 85.0, :ge, :kpi_report,
                "water-soluble P2O5 of the product"),
            Requirement(:iso_9001, :process_control, "Control of production",
                :acid_strength, :wt_pct, 50.50, :ge, :kpi_report,
                "the merchant acid leaves the evaporators at specification"),
        ])
    end
    append!(r, _compliance_sustainability(frameworks))
    return r
end

"""Second half of the catalogue: GHG Protocol, EU IED, EPA NESHAP, IFA BAT, gypsum."""
function _compliance_sustainability(frameworks::Vector{Symbol})
    r = Requirement[]
    if :ghg_protocol in frameworks
        append!(r, Requirement[
            Requirement(:ghg_protocol, :scope_1, "Scope 1 quantification",
                :scope_1_t, :t, 48.0, :le, :carbon_inventory,
                "the fuel of the dryers, the calcination CO2 and the sulphur burnt"),
            Requirement(:ghg_protocol, :scope_2, "Scope 2 quantification",
                :scope_2_t, :t, 240.0, :le, :carbon_inventory,
                "the grid electricity of the mine and the plant"),
            Requirement(:ghg_protocol, :intensity, "Emissions intensity",
                :carbon_intensity, :kg_ph, 145.0, :le, :carbon_inventory,
                "kgCO2e per tonne of P2O5 produced"),
            Requirement(:ghg_protocol, :factors, "Emission factor register",
                :factor_count, :count, 4.0, :ge, :carbon_inventory,
                "every factor is registered with its source"),
        ])
    end
    if :eu_ied in frameworks
        append!(r, Requirement[
            Requirement(:eu_ied, :bat_emissions, "BAT emission levels",
                :stack_fluoride, :count, 5.00, :le, :kpi_report,
                "the BAT range of the fluorine emitted by the acid plant"),
            Requirement(:eu_ied, :energy_efficiency, "Energy efficiency of BAT",
                :specific_energy, :gj_per_t, 12.50, :le, :kpi_report,
                "the energy consumption of the BAT reference document"),
            Requirement(:eu_ied, :monitoring, "Continuous monitoring",
                :completeness, :pct, 98.0, :ge, :quality_register,
                "the monitoring of the emission points is continuous and usable"),
            Requirement(:eu_ied, :waste, "Waste management plan",
                :gypsum_free_p2o5, :wt_pct, 1.00, :le, :kpi_report,
                "the phosphogypsum is managed inside the permitted facility"),
        ])
    end
    if :us_epa_40cfr63 in frameworks
        append!(r, Requirement[
            Requirement(:us_epa_40cfr63, :fluoride, "Fluoride emission limit",
                :stack_fluoride, :count, 5.00, :le, :kpi_report,
                "the fluoride standard of the phosphoric acid subpart"),
            Requirement(:us_epa_40cfr63, :scrubber, "Scrubber operating limit",
                :scrubber_ph, :count, 5.60, :ge, :kpi_report,
                "the parameter that has to stay inside its operating range"),
            Requirement(:us_epa_40cfr63, :records, "Record keeping",
                :completeness, :pct, 98.0, :ge, :quality_register,
                "the records of the emission point are complete for the period"),
        ])
    end
    if :ifa_bat in frameworks
        append!(r, Requirement[
            Requirement(:ifa_bat, :recovery, "P2O5 recovery of the route",
                :p2o5_recovery, :pct, 94.0, :ge, :kpi_report,
                "the recovery from the mine to the bagged product"),
            Requirement(:ifa_bat, :acid_demand, "Specific acid demand",
                :acid_consumption, :t_ph, 2.85, :le, :kpi_report,
                "sulphuric acid per tonne of P2O5"),
            Requirement(:ifa_bat, :water_soluble, "Water-soluble loss",
                :water_soluble_loss, :pct, 2.00, :le, :kpi_report,
                "the P2O5 lost with the gypsum"),
            Requirement(:ifa_bat, :fluorine, "Fluorine recovery",
                :fluorine_recovery, :pct, 80.0, :ge, :kpi_report,
                "the fluorine recovered as fluosilicic acid"),
            Requirement(:ifa_bat, :grind, "Liberation of the ore",
                :grind_p80, :um, 170.0, :le, :kpi_report,
                "the grind that liberates the apatite of the blend"),
        ])
    end
    if :phosphogypsum_code in frameworks
        append!(r, Requirement[
            Requirement(:phosphogypsum_code, :stack_quality, "Gypsum quality to the stack",
                :gypsum_free_p2o5, :wt_pct, 1.00, :le, :kpi_report,
                "the free P2O5 of the cake going to the stack"),
            Requirement(:phosphogypsum_code, :water_return, "Water return to the plant",
                :water_recovery, :pct, 65.0, :ge, :kpi_report,
                "the water recovered from the stack pond"),
            Requirement(:phosphogypsum_code, :dust, "Dust control on the stack",
                :stack_dust, :count, 30.0, :le, :kpi_report,
                "the dust of the gypsum handling"),
        ])
    end
    return r
end

"""
    compliance_metric(name, kpi, fdd) -> Float64

Value of the metric that evidences a clause. Every name is resolved from the KPI
bundle (and, for the diagnostic clauses, from the findings bundle), so a clause can
only ever be evidenced by a number the report also publishes.
"""
function compliance_metric(name::Symbol, kpi::Dict{Symbol,Any}, fdd = nothing)
    crit = fdd === nothing ? 0.0 : fdd[:summary][:by_severity][:critical]
    return name === :specific_energy ? kpi[:energy][:specific_gj_per_p2o5] :
           name === :spec_energy_vs_design ? 100.0 * kpi[:energy][:specific_gj_per_p2o5] / 12.5 :
           name === :completeness ? kpi[:quality][:completeness_pct] :
           name === :targets_met ? 100.0 * target_counts(kpi)[:compliant] /
                                   max(length(kpi[:targets]), 1) :
           name === :critical_findings ? crit :
           name === :metered_signals ? length(signal_tags()) :
           name === :stack_fluoride ? kpi[:emissions][:stack_fluoride] :
           name === :stack_dust ? kpi[:emissions][:stack_dust] :
           name === :scrubber_ph ? kpi[:emissions][:scrubber_ph] :
           name === :gypsum_free_p2o5 ? kpi[:filtration][:free_p2o5] :
           name === :water_per_p2o5 ? kpi[:water][:water_per_p2o5] :
           name === :water_recovery ? 100.0 * kpi[:water][:process_water_m3] /
                                      max(kpi[:water][:process_water_m3] +
                                          kpi[:water][:cooling_evaporation_m3] +
                                          kpi[:water][:cooling_blowdown_m3], 1.0) :
           name === :effluent_ph ? kpi[:water][:effluent_ph] :
           name === :product_n ? kpi[:product][:n_pct] :
           name === :product_moisture ? kpi[:product][:moisture_pct] :
           name === :product_wsp ? kpi[:product][:wsp_pct] :
           name === :acid_strength ? kpi[:evaporation][:strength] :
           name === :scope_1_t ? kpi[:carbon][:scope_1_t] :
           name === :scope_2_t ? kpi[:carbon][:scope_2_t] :
           name === :carbon_intensity ? kpi[:carbon][:intensity_kg_per_p2o5] :
           name === :factor_count ? length(kpi[:carbon][:factors]) :
           name === :p2o5_recovery ? kpi[:product][:p2o5_recovery_pct] :
           name === :acid_consumption ? kpi[:attack][:acid_per_p2o5] :
           name === :water_soluble_loss ? kpi[:filtration][:water_soluble_pct] :
           name === :fluorine_recovery ? _fluorine_recovery(kpi) :
           name === :grind_p80 ? kpi[:beneficiation][:grind_p80] : NaN
end

"""
    _fluorine_recovery(kpi) -> Float64

Scrubber capture index of the fluorine released by the attack: the registered
scrubber efficiency (92 %) reduced by the measured exceedance of the stack limit.
"""
function _fluorine_recovery(kpi::Dict{Symbol,Any})
    over = max(0.0, kpi[:emissions][:stack_fluoride] - kpi[:emissions][:fluoride_limit])
    return clamp(92.0 - 12.0 * over, 0.0, 99.0)
end

"""One row of the compliance register, with the status of its clause."""
function requirement_status(r::Requirement, kpi::Dict{Symbol,Any}, fdd = nothing)
    value = compliance_metric(r.metric, kpi, fdd)
    status = target_status(value, r.target, r.comparator)
    return Dict{Symbol,Any}(:framework => r.framework, :clause => r.clause,
        :title => r.title, :metric => r.metric, :value => value, :unit => r.unit,
        :target => r.target, :comparator => r.comparator, :status => status,
        :margin_pct => target_margin(value, r.target, r.comparator),
        :evidence => r.evidence, :basis => r.basis, :framework_title => framework_title(r.framework))
end

"""
    assess_compliance(kpi, fdd; frameworks) -> Dict{Symbol,Any}

Fill the clause register of every framework and score it: the register itself, the
statuses by framework, the number of clauses and the over-all status.
"""
function assess_compliance(kpi::Dict{Symbol,Any}, fdd = nothing;
    frameworks::Vector{Symbol} = collect(FRAMEWORKS))
    catalogue = compliance_catalogue(; frameworks = frameworks)
    register = [requirement_status(r, kpi, fdd) for r in catalogue]
    by_framework = Dict{Symbol,Any}()
    for f in frameworks
        rows = [r for r in register if r[:framework] === f]
        isempty(rows) && continue
        by_framework[f] = Dict{Symbol,Any}(:title => framework_title(f), :clauses => length(rows),
            :compliant => count(r -> r[:status] === :compliant, rows),
            :at_risk => count(r -> r[:status] === :at_risk, rows),
            :noncompliant => count(r -> r[:status] === :noncompliant, rows),
            :compliance_pct => 100.0 * count(r -> r[:status] === :compliant, rows) / length(rows),
            :rows => rows)
    end
    return Dict{Symbol,Any}(:register => register, :catalogue => catalogue,
        :frameworks => frameworks, :by_framework => Dict{Symbol,Any}(by_framework))
end

"""
    compliance_scorecard(assessment) -> Dict{Symbol,Any}

Counts and percentages of the register: how many clauses are compliant, at risk and
non-compliant, and the over-all status of the plant.
"""
function compliance_scorecard(assessment::Dict{Symbol,Any})
    rows = assessment[:register]
    n = length(rows)
    compliant = count(r -> r[:status] === :compliant, rows)
    at_risk = count(r -> r[:status] === :at_risk, rows)
    noncompliant = count(r -> r[:status] === :noncompliant, rows)
    pct = n == 0 ? 0.0 : 100.0 * compliant / n
    return Dict{Symbol,Any}(:clause_count => n, :compliant => compliant, :at_risk => at_risk,
        :noncompliant => noncompliant, :compliance_pct => pct,
        :overall_status => noncompliant > 0 ? :noncompliant :
                           at_risk > 0 ? :at_risk : :compliant,
        :frameworks => length(assessment[:frameworks]), :rows => rows,
        :by_framework => assessment[:by_framework])
end

"""
    corrective_actions(assessment; limit) -> Vector{Dict{Symbol,Any}}

Corrective actions for the clauses that are not compliant: the clause, the measured
value against its target and the action the plant has to take, ordered by the size
of the gap.
"""
function corrective_actions(assessment::Dict{Symbol,Any}; limit::Integer = 10)
    rows = [r for r in assessment[:register]
            if r[:status] !== :compliant && r[:status] !== :not_assessed]
    sort!(rows; by = r -> r[:margin_pct])
    return [Dict{Symbol,Any}(:framework => r[:framework], :clause => r[:clause],
        :title => r[:title], :metric => r[:metric], :value => r[:value], :target => r[:target],
        :unit => r[:unit], :gap_pct => r[:margin_pct], :status => r[:status],
        :action => _action_for(r), :evidence => r[:evidence])
            for r in first(rows, min(limit, length(rows)))]
end

"""The action a plant engineer would write for a clause that is out of its target."""
function _action_for(r::Dict{Symbol,Any})
    m = r[:metric]
    return m === :stack_fluoride ? "Raise the scrubber pH and check the tower nozzles" :
           m === :stack_dust ? "Inspect the dryer cyclones and the scrubber packing" :
           m === :gypsum_free_p2o5 ? "Raise the wash ratio and review the filter vacuum" :
           m === :acid_strength ? "Re-tube the evaporator and re-tune the steam control" :
           m === :specific_energy ? "Run the energy review on the evaporator and the mills" :
           m === :water_per_p2o5 ? "Close the water balance of the tailings pond" :
           m === :completeness ? "Repair the transmitters of the worst signals of the register" :
           (m === :product_n || m === :product_moisture) ? "Re-tune the sparger and the dryer" :
           m === :critical_findings ? "Close the critical findings of the diagnostics register" :
           m === :p2o5_recovery ? "Review the reagent dose and the grind of the blend" :
           m === :carbon_intensity ? "Substitute the dryer fuel and buy green power" :
           "Review the operating window with the process engineer"
end

"""Human-readable description of the evidence a clause is evidenced with."""
evidence_description(r::Dict{Symbol,Any}) = string(to_string(r[:evidence]), " -- ",
    to_string(r[:metric]), " (", code_string(r[:unit]), ")")

"""
    compliance_report(kpi, fdd; frameworks) -> Dict{Symbol,Any}

The compliance bundle of a campaign: the assessment, the scorecard, the corrective
actions and the register as flat rows, ready for the printout and the JSON payload.
"""
function compliance_report(kpi::Dict{Symbol,Any}, fdd = nothing;
    frameworks::Vector{Symbol} = collect(FRAMEWORKS))
    assessment = assess_compliance(kpi, fdd; frameworks = frameworks)
    scorecard = compliance_scorecard(assessment)
    return Dict{Symbol,Any}(:assessment => assessment, :scorecard => scorecard,
        :actions => corrective_actions(assessment), :register => scorecard[:rows],
        :frameworks => frameworks, :status => scorecard[:overall_status])
end

"""The register of a compliance report, as rows ready for a table."""
register_rows(compliance::Dict{Symbol,Any}) = compliance[:register]





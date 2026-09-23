# =============================================================================
# pipeline.jl -- one call that produces every artefact of the plant.
#
# `report_bundle` builds everything a report can print -- the campaign, the KPIs,
# the diagnostics, the compliance register, the twin, the optimiser, the controller
# and the sensors -- and `run_pipeline` also writes the data, the printouts and the
# PDFs, then a manifest that says exactly what was produced.
#
# The notebooks call `report_bundle` too, so the notebook and the PDF of the same
# seed are the same document by construction.
# =============================================================================

"""
    PipelineConfig

Everything the pipeline needs, all keyed by `Symbol` so it can also be passed as a
plain dictionary: `:root`, `:seed`, `:days`, `:vision_samples`, `:acoustic_samples`,
`:mpc_steps`, `:mpc_scenario`, the switches of the optional subsystems and the
printing options.
"""
Base.@kwdef struct PipelineConfig
    root::String = pwd()
    data_dir::String = "data"
    html_dir::String = joinpath("reports", "html")
    pdf_dir::String = joinpath("reports", "pdf")
    seed::Int = 20260101
    days::Int = 365
    vision_samples::Int = 160
    vision_size::Int = 96
    acoustic_samples::Int = 120
    acoustic_n::Int = 4096
    mpc_steps::Int = 48
    mpc_scenario::Symbol = :setpoint
    dynamic_hours::Float64 = 48.0
    run_optimization::Bool = true
    run_mpc::Bool = true
    run_vision::Bool = true
    run_acoustic::Bool = true
    run_dynamic::Bool = true
    run_twin::Bool = true
    export_data::Bool = true
    render_pdf::Bool = true
    chrome::Union{Nothing,String} = nothing
    groups::Vector{Symbol} = [:all, :acid, :twin, :control, :sensors, :diagnostics, :compliance]
end

"""Build a `PipelineConfig` from a symbol-keyed dictionary (for scripts and notebooks)."""
function PipelineConfig(d::AbstractDict)
    kw = Dict{Symbol,Any}(Sym(k) => v for (k, v) in d)
    return PipelineConfig(; (k => v for (k, v) in kw if k in fieldnames(PipelineConfig))...)
end

"""Absolute path of one of the configured output directories."""
path_of(cfg::PipelineConfig, key::Symbol) =
    key === :root ? cfg.root :
    key === :data ? joinpath(cfg.root, cfg.data_dir) :
    key === :html ? joinpath(cfg.root, cfg.html_dir) :
    key === :pdf ? joinpath(cfg.root, cfg.pdf_dir) :
    throw(ArgumentError("unknown output $(code_string(key))"))

"""
    jsonable(x)

Deep conversion of any pipeline result into plain JSON-able data: symbols become
strings, dates become ISO strings, structs become objects of their fields, and the
values that are not finite become `null` rather than an invalid JSON number.
"""
function jsonable(x::Any)
    x isa Symbol && return String(x)
    x isa Union{Date,DateTime} && return string(x)
    x isa AbstractFloat && return isfinite(x) ? x : nothing
    x isa AbstractDict && return Dict{String,Any}(string(jsonable(k)) => jsonable(v)
                                                  for (k, v) in x)
    x isa NamedTuple && return Dict{String,Any}(string(k) => jsonable(v) for (k, v) in pairs(x))
    x isa AbstractVector && return Any[jsonable(v) for v in x]
    x isa Tuple && return Any[jsonable(v) for v in x]
    (x isa Real || x isa AbstractString || x isa Bool || x === nothing) && return x
    if isstructtype(typeof(x)) && !(x isa Function)
        return Dict{String,Any}(string(f) => jsonable(getfield(x, f))
                                for f in fieldnames(typeof(x)))
    end
    return string(x)
end

"""Write a symbol-keyed payload to JSON with the vocabulary preserved as strings."""
function write_json_payload(path::AbstractString, payload)
    mkpath(dirname(path))
    open(path, "w") do io
        JSON3.pretty(io, jsonable(payload))
    end
    return path
end

"""
    report_bundle(cfg = PipelineConfig(); design, campaign) -> Dict{Symbol,Any}

Build everything a report can print, in the order the plant would compute it:
the campaign of the historian, the KPI bundle, the diagnostics, the compliance
register, the steady-state and dynamic twins, the alignment of the twin against the
plant, the state estimation, the three optimisation models, the closed loop of the
controller and the inferential sensors, and then every figure that can be drawn
from them.

The optional subsystems are only computed when the configuration asks for them,
because a study of the twin of a campaign of a year does not need the acoustic
sensors: the switches are `run_twin`, `run_dynamic`, `run_optimization`, `run_mpc`,
`run_vision` and `run_acoustic`.
"""
function report_bundle(cfg::PipelineConfig = PipelineConfig();
    design::PlantDesign = default_design(), campaign::Union{Nothing,Campaign} = nothing)
    t0 = time()
    flowsheet = default_flowsheet(design)
    c = campaign === nothing ? generate_campaign(design; days = cfg.days, seed = cfg.seed) :
        campaign
    kpi = site_kpis(c)
    fdd = fault_detection_report(c, kpi)
    compliance = compliance_report(kpi, fdd)

    twin = cfg.run_twin ? twin_report(design) : nothing
    dynamic = cfg.run_dynamic ?
              simulate_dynamic(design; tspan = (0.0, cfg.dynamic_hours)) : nothing
    linear = linearize_twin(design)

    estimation = cfg.run_twin ? filter_states(design, c, linear; from = 1, to = 336) : nothing
    alignment = cfg.run_twin ? align_twin(design, c; kpi = kpi) : nothing
    reconciliation = reconcile_measurements(c)
    optimization = cfg.run_optimization ? optimization_report(c, kpi; design = design) : nothing
    mpc = cfg.run_mpc ? mpc_report(design; steps = cfg.mpc_steps,
        scenario = cfg.mpc_scenario, seed = cfg.seed) : nothing
    process_sensors = train_process_sensors(c; seed = cfg.seed)
    vision = cfg.run_vision ? vision_report(c; samples = cfg.vision_samples,
        size = cfg.vision_size, seed = cfg.seed) : nothing
    acoustic = cfg.run_acoustic ? acoustic_report(c; samples = cfg.acoustic_samples,
        n = cfg.acoustic_n, seed = cfg.seed) : nothing
    sensors = vcat(process_sensors, vision === nothing ? SoftSensor[] : vision[:sensors],
        acoustic === nothing ? SoftSensor[] : acoustic[:sensors])
    soft = soft_sensor_report(c; sensors = sensors, seed = cfg.seed)

    figures = figure_set(c, kpi, fdd, compliance; twin = twin, mpc = mpc, vision = vision,
        acoustic = acoustic, soft = soft, alignment = alignment,
        optimization = optimization)

    bundle = Dict{Symbol,Any}(:design => design, :flowsheet => flowsheet, :campaign => c,
        :kpi => kpi, :fdd => fdd, :compliance => compliance, :twin => twin,
        :dynamic => dynamic, :linear => linear, :estimation => estimation,
        :alignment => alignment, :reconciliation => reconciliation,
        :optimization => optimization, :mpc => mpc, :soft => soft, :vision => vision,
        :acoustic => acoustic, :figures => figures,
        :config => cfg, :generated_at => string(now()),
        :elapsed_s => round(time() - t0, digits = 1))
    return bundle
end

"""Symbol-keyed summary of a bundle, the payload the manifest of the pipeline carries."""
function bundle_summary(b::Dict{Symbol,Any})
    kpi = b[:kpi]
    return Dict{Symbol,Any}(:site => kpi[:site][:name], :product => kpi[:site][:product],
        :seed => b[:campaign].meta[:seed], :days => kpi[:period][:days],
        :generated_at => b[:generated_at], :elapsed_s => b[:elapsed_s],
        :production => Dict{Symbol,Any}(:rom_t => kpi[:ore][:rom_t],
            :product_t => kpi[:product][:tonnes],
            :p2o5_recovery_pct => kpi[:product][:p2o5_recovery_pct]),
        :cost => Dict{Symbol,Any}(:per_t_product => kpi[:cost][:per_t_product],
            :margin_per_t => kpi[:cost][:margin_per_t], :currency => kpi[:cost][:currency]),
        :energy => kpi[:energy], :carbon => kpi[:carbon],
        :targets => target_counts(kpi),
        :diagnostics => b[:fdd][:summary], :verification => b[:fdd][:verification],
        :compliance => b[:compliance][:scorecard],
        :twin => b[:twin] === nothing ? nothing :
                Dict{Symbol,Any}(:status => b[:twin][:status],
                    :max_residual => b[:twin][:max_residual],
                    :validity_score => b[:alignment] === nothing ? NaN :
                                       b[:alignment][:validity_score]),
        :acid => kpi[:acid][:summary],
        :control => b[:mpc] === nothing ? nothing : get(b[:mpc], :summary, b[:mpc]),
        :optimization => b[:optimization] === nothing ? nothing :
                         get(b[:optimization], :summary, b[:optimization]),
        :sensors => get(b[:soft], :summary, b[:soft]),
        :reconciliation => get(b[:reconciliation], :summary, b[:reconciliation]),
        :figures => sort(collect(keys(b[:figures])); by = String))
end

"""
    export_bundle(bundle; cfg, root) -> Dict{Symbol,Any}

Write the deliverables of a bundle: the data exports (readings, deviations, registers,
the KPI and diagnostics payloads, the sound samples), one printout per group of
sections and the PDF of each of them, and return the manifest that says what exists.
"""
function export_bundle(b::Dict{Symbol,Any}; cfg::PipelineConfig = b[:config],
    root::AbstractString = cfg.root)
    data_dir = joinpath(root, cfg.data_dir)
    html_dir = joinpath(root, cfg.html_dir)
    pdf_dir = joinpath(root, cfg.pdf_dir)
    artifacts = Dict{Symbol,Any}(:data => String[], :html => String[], :pdf => String[],
        :audio => String[])
    if cfg.export_data
        append!(artifacts[:data], export_campaign(b[:campaign], data_dir))
        push!(artifacts[:data], write_json_payload(joinpath(data_dir, "kpi.json"), b[:kpi]))
        push!(artifacts[:data], write_json_payload(joinpath(data_dir, "findings.json"), b[:fdd]))
        push!(artifacts[:data], write_json_payload(joinpath(data_dir, "compliance.json"),
            b[:compliance]))
        push!(artifacts[:data], write_json_payload(joinpath(data_dir, "summary.json"),
            bundle_summary(b)))
        push!(artifacts[:data], write_json_payload(joinpath(data_dir, "design.json"),
            design_summary(b[:design])))
        write_table_csv(joinpath(data_dir, "targets.csv"), target_table(b[:kpi]),
            [:metric, :actual, :target, :unit, :comparator, :status, :margin_pct, :basis])
        write_table_csv(joinpath(data_dir, "compliance_register.csv"), b[:compliance][:register],
            [:framework, :clause, :title, :metric, :value, :unit, :target, :status, :margin_pct,
                :evidence])
        write_table_csv(joinpath(data_dir, "sensor_register.csv"), b[:soft][:rows],
            [:sensor, :target, :kind, :unit, :r2, :rmse, :bias, :rows, :in_domain_pct, :status])
        acid = b[:kpi][:acid]
        write_table_csv(joinpath(data_dir, "acid_balance.csv"), acid[:balance],
            [:destination, :p2o5_t, :share_pct, :note])
        write_table_csv(joinpath(data_dir, "acid_quality.csv"), acid[:quality][:rows],
            [:spec, :tag, :value, :limit, :unit, :comparator, :margin_pct, :status, :basis])
        write_table_csv(joinpath(data_dir, "acid_consumption.csv"), acid[:consumption],
            [:metric, :value, :unit, :basis, :note])
        write_json_payload(joinpath(data_dir, "acid.json"), acid)
        if b[:twin] !== nothing
            write_table_csv(joinpath(data_dir, "steady_state.csv"), b[:twin][:table],
                [:variable, :value, :unit, :description])
        end
        if b[:optimization] !== nothing
            write_table_csv(joinpath(data_dir, "blend.csv"), b[:optimization][:blend_rows],
                [:body, :tonnes_ph, :share_pct, :price, :cost_ph, :p2o5, :cao_p2o5, :fe_al, :mgo])
            write_table_csv(joinpath(data_dir, "sourcing.csv"),
                b[:optimization][:sourcing_rows],
                [:body, :tonnes, :share_pct, :price, :cost, :months_active, :p2o5])
        end
        if b[:mpc] !== nothing
            loop = b[:mpc][:mpc]
            write_table_csv(joinpath(data_dir, "loop_trajectory.csv"), loop[:rows],
                vcat([:hour, :kind], [Symbol(o, :_value) for o in loop[:outputs]],
                    [Symbol(i, :_percent) for i in loop[:inputs]]))
        end
        if b[:acoustic] !== nothing
            append!(artifacts[:audio], export_acoustic_samples(b[:acoustic], data_dir))
        end
    end
    for group in cfg.groups
        id = Symbol(group === :all ? :phosphate : group)
        html = group === :all ? report_html(b) : section_html(b, group)
        push!(artifacts[:html], write_printout(joinpath(html_dir, string(id, ".html")), html))
    end
    error_message = nothing
    if cfg.render_pdf
        if pdf_available(; explicit = cfg.chrome)
            for group in cfg.groups
                id = Symbol(group === :all ? :phosphate : group)
                try
                    push!(artifacts[:pdf], html_to_pdf(joinpath(html_dir, string(id, ".html")),
                        joinpath(pdf_dir, string(id, ".pdf")); chrome = cfg.chrome))
                catch err
                    error_message = string(id, ": ", sprint(showerror, err))
                    @warn "PDF printing failed" group = group exception = err
                end
            end
        else
            error_message = "no Chromium-based browser found; set CHROME_PATH to enable PDF printing"
            @warn error_message
        end
    end
    manifest = Dict{Symbol,Any}(:summary => bundle_summary(b), :artifacts => artifacts,
        :pdf => pdf_capability(),
        :status => (error_message === nothing || !isempty(artifacts[:pdf])) ? :ok : :partial)
    error_message === nothing || (manifest[:pdf_error] = error_message)
    cfg.export_data &&
        push!(artifacts[:data], write_json_payload(joinpath(data_dir, "manifest.json"), manifest))
    return manifest
end

"""
    run_pipeline(cfg = PipelineConfig()) -> Dict{Symbol,Any}

The whole chain in one call: build the bundle, write the data, the printouts and the
PDFs, and return `:bundle`, `:manifest` and `:artifacts`.
"""
function run_pipeline(cfg::PipelineConfig = PipelineConfig())
    @info "PHOSPHATE pipeline" root = cfg.root seed = cfg.seed days = cfg.days
    bundle = report_bundle(cfg)
    manifest = export_bundle(bundle; cfg = cfg)
    return Dict{Symbol,Any}(:bundle => bundle, :manifest => manifest,
        :artifacts => manifest[:artifacts], :config => cfg)
end

"""Print a short, human-readable run report to `io`."""
function report_manifest(manifest::Dict{Symbol,Any}; io::IO = stdout)
    s = manifest[:summary]
    println(io, "status            : ", code_string(manifest[:status]))
    println(io, "site              : ", s[:site], " | seed ", s[:seed], " | ", s[:days], " days")
    println(io, "ore / product     : ", round(s[:production][:rom_t] / 1000, digits = 1),
        " kt / ", round(s[:production][:product_t] / 1000, digits = 1), " kt at ",
        round(s[:production][:p2o5_recovery_pct], digits = 1), " % recovery")
    println(io, "cost / margin     : ", round(s[:cost][:per_t_product], digits = 1), " ",
        code_string(s[:cost][:currency]), " per t, margin ",
        round(s[:cost][:margin_per_t], digits = 1))
    println(io, "carbon            : ", round(s[:carbon][:intensity_kg_per_p2o5], digits = 1),
        " kgCO2e per t P2O5")
    t = s[:targets]
    println(io, "targets           : ", t[:compliant], " compliant, ", t[:at_risk], " at risk, ",
        t[:noncompliant], " non-compliant")
    println(io, "findings          : ", s[:diagnostics][:count], " worth ",
        round(s[:diagnostics][:cost_at_stake], digits = 0), " a year, ",
        round(s[:verification][:detection_rate_pct], digits = 1), " % of the injected caught")
    println(io, "compliance        : ", round(s[:compliance][:compliance_pct], digits = 1),
        " % of ", s[:compliance][:clause_count], " clauses (",
        code_string(s[:compliance][:overall_status]), ")")
    s[:twin] === nothing ||
        println(io, "twin              : ", code_string(s[:twin][:status]), ", residual ",
            s[:twin][:max_residual], ", validity ",
            round(s[:twin][:validity_score], digits = 1), " %")
    s[:control] === nothing ||
        println(io, "control           : MPC error ", round(s[:control][:mpc_iae], digits = 2),
            " bands against ", round(s[:control][:pi_iae], digits = 2), " for the PI baseline")
    println(io, "sensors           : ", s[:sensors][:sensors], " (median R2 ",
        round(s[:sensors][:median_r2], digits = 3), ")")
    println(io, "figures           : ", length(s[:figures]))
    for (kind, files) in sort(collect(manifest[:artifacts]); by = x -> String(x[1]))
        println(io, rpad(string(kind), 18), ": ", length(files), " file(s)")
        for f in first(files, 6)
            println(io, "    ", basename(f))
        end
        length(files) > 6 && println(io, "    ... ", length(files) - 6, " more")
    end
    haskey(manifest, :pdf_error) && println(io, "pdf error         : ", manifest[:pdf_error])
    return io
end




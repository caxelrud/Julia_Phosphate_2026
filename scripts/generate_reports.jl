#!/usr/bin/env julia
# =============================================================================
# generate_reports.jl -- run the whole reporting chain from the shell.
#
#   julia --project=. scripts/generate_reports.jl [options]
#
#     --seed=20260101        seed of the campaign (reproducibility)
#     --days=365             days of hourly interval data
#     --vision-samples=160   images rendered for the visual sensors
#     --acoustic-samples=120 windows rendered for the acoustic sensors
#     --mpc-steps=48         hours of closed-loop simulation
#     --groups=a,b,c         groups of sections to print (default: all plus five)
#     --chrome=PATH          browser executable used to print the PDFs
#     --no-data              skip the CSV/JSON export
#     --no-pdf               skip the PDF printing
#     --no-twin              skip the twin, the optimiser and the controller
#     --root=PATH            repository root (default: the working directory)
# =============================================================================

using PHOSPHATE
using Dates

"""Split a string at the first occurrence of `sep`."""
function partition_string(s::AbstractString, sep::Char)
    i = findfirst(==(sep), s)
    i === nothing && return (String(s), sep, "")
    return (String(s[1:(i - 1)]), sep, String(s[(i + 1):end]))
end

"""Parse `--key=value` command line options into a symbol-keyed dictionary."""
function parse_options(args::Vector{String})
    opts = Dict{Symbol,Any}()
    for a in args
        startswith(a, "--") || continue
        body = a[3:end]
        key, _, value = partition_string(body, '=')
        k = Sym(key)
        opts[k] = value == "" ? true :
                  k in (:seed, :days, :vision_samples, :acoustic_samples, :mpc_steps,
                        :vision_size, :acoustic_n) ? parse(Int, value) :
                  k === :groups ? Symbol.(split(value, ',')) :
                  String(value)
    end
    return opts
end

function main(args = ARGS)
    opts = parse_options(collect(args))
    root = get(opts, :root, pwd())
    cfg = PipelineConfig(
        root = root,
        seed = get(opts, :seed, 20260101),
        days = get(opts, :days, 365),
        vision_samples = get(opts, :vision_samples, 160),
        vision_size = get(opts, :vision_size, 96),
        acoustic_samples = get(opts, :acoustic_samples, 120),
        acoustic_n = get(opts, :acoustic_n, 4096),
        mpc_steps = get(opts, :mpc_steps, 48),
        groups = get(opts, :groups, [:all, :acid, :twin, :control, :sensors, :diagnostics,
        :compliance]),
        export_data = !get(opts, :no_data, false),
        render_pdf = !get(opts, :no_pdf, false),
        chrome = get(opts, :chrome, nothing),
    )
    if get(opts, :no_twin, false)
        cfg = PipelineConfig(; (f => getfield(cfg, f) for f in fieldnames(PipelineConfig)
                                 if !(f in (:run_twin, :run_dynamic, :run_optimization,
                                            :run_mpc, :run_vision, :run_acoustic)))...,
            run_twin = false, run_dynamic = false, run_optimization = false, run_mpc = false,
            run_vision = false, run_acoustic = false)
    end

    println("PHOSPHATE report generation")
    println("  root            : ", cfg.root)
    println("  seed / days     : ", cfg.seed, " / ", cfg.days)
    println("  sensors         : ", cfg.vision_samples, " images, ", cfg.acoustic_samples,
        " acoustic windows of ", cfg.acoustic_n, " samples")
    println("  control         : ", cfg.mpc_steps, " h of closed loop (", code_string(
        cfg.mpc_scenario), ")")
    println("  groups          : ", join(code_string.(cfg.groups), ", "))
    println("  pdf printing    : ", cfg.render_pdf ?
            (pdf_available(; explicit = cfg.chrome) ?
             string("enabled (", find_chrome(; explicit = cfg.chrome), ")") :
             "requested but no browser found") : "disabled")
    println()

    t0 = time()
    result = run_pipeline(cfg)
    ## ---- the phosphoric-acid document -------------------------------------------------
    ## The acid route printed on its own, under a title that says what it is, together
    ## with the printout the acid notebook writes in its last cell. Both come from the
    ## same bundle, so the file and what the notebook displays cannot disagree.
    if cfg.render_pdf
        acid_title = "Phosphoric acid: the balance, the specification and the cost"
        acid_html = joinpath(cfg.root, "reports", "html", "phosphoric_acid.html")
        acid_pdf = joinpath(cfg.root, "reports", "pdf", "phosphoric_acid.pdf")
        try
            write_printout(acid_html, section_html(result[:bundle], :acid; title = acid_title))
            html_to_pdf(acid_html, acid_pdf; chrome = cfg.chrome)
            notebook = print_report_pdf(result[:bundle]; id = :acid, group = :acid,
                root = cfg.root, chrome = cfg.chrome, title = acid_title)
            println("acid printout     : ", basename(acid_pdf), " (",
                round(filesize(acid_pdf) / 1.0e3, digits = 1), " kB) and ",
                basename(notebook[:pdf]), " (",
                round(notebook[:pdf_bytes] / 1.0e3, digits = 1), " kB)")
        catch err
            println("acid printout     : skipped (",
                first(replace(sprint(showerror, err), "\n" => " "), 120), ")")
        end
    end
    println()
    report_manifest(result[:manifest])
    println()
    println("elapsed         : ", round(time() - t0, digits = 1), " s")
    return result
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

#!/usr/bin/env julia
# =============================================================================
# run_notebooks.jl -- run every Pluto notebook headless and print its PDF.
#
#   julia --project=. scripts/run_notebooks.jl [options]
#
#     --only=00_Phosphate_Dashboard,01_Process   run only the listed notebooks
#     --no-pdf                                   do not print the extra PDFs
#     --days=120                                 days of the campaign of the run
#
# Each notebook runs headless through Pluto (`PHOSPHATE.run_notebook`) and its last
# cell writes the printout and prints its own PDF, so the files under
# `reports/pdf/notebook_*.pdf` come straight from the notebooks.
# =============================================================================

using PHOSPHATE
using Dates

const NOTEBOOK_DIR = joinpath(pwd(), "notebooks")

function main(args = ARGS)
    only = [a for a in args if startswith(a, "--only=")]
    selected = isempty(only) ? nothing : split(only[1][8:end], ',')
    days = let a = [a for a in args if startswith(a, "--days=")]
        isempty(a) ? 120 : parse(Int, split(a[1], '=')[2])
    end
    print_pdfs = !any(==("--no-pdf"), args)

    files = notebook_files(NOTEBOOK_DIR)
    selected === nothing ||
        (files = [f for f in files if any(s -> startswith(basename(f), s), selected)])
    println("running ", length(files), " notebook(s) from ", NOTEBOOK_DIR, "\n")

    reports = []
    for f in files
        push!(reports, run_notebook(f))
        print_notebook_report(reports[end])
    end
    println("\nnotebooks passed : ", count(r -> r[:ok], reports), " / ", length(reports))

    if print_pdfs && pdf_available()
        cfg = PipelineConfig(root = pwd(), days = days, render_pdf = true,
            groups = [:all, :twin, :control, :sensors])
        bundle = report_bundle(cfg)
        for group in cfg.groups
            out = print_report_pdf(bundle; id = group === :all ? :phosphate : group,
                group = group, root = pwd())
            println("printout         : ", code_string(out[:notebook]), " -> ",
                relpath(out[:pdf], pwd()), " (", round(out[:pdf_bytes] / 1024, digits = 0),
                " KB, ", out[:sections], " sections)")
        end
    end
    return reports
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

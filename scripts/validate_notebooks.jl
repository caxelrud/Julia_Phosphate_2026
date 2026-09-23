#!/usr/bin/env julia
# =============================================================================
# validate_notebooks.jl -- static checks of the Pluto notebooks.
#
#   julia --project=. scripts/validate_notebooks.jl [dir]
#
# The checks live in `PHOSPHATE.validate_notebooks`, so the test suite runs exactly
# the same rules; see its docstring for what is verified.
# =============================================================================

using PHOSPHATE

function main(args = ARGS)
    dir = isempty(args) ? "notebooks" : args[1]
    results = validate_notebooks(dir)
    for r in results
        println(r[:ok] ? "PASS  " : "FAIL  ", rpad(string(r[:notebook]), 30),
            " cells=", rpad(string(r[:cells]), 4), " code=", rpad(string(r[:code_cells]), 4),
            " md=", rpad(string(r[:markdown_cells]), 4), " printout cells=", r[:printout_cells])
        for p in r[:problems]
            println("      - ", p)
        end
    end
    failed = count(r -> !r[:ok], results)
    println("\n", length(results) - failed, " / ", length(results), " notebooks valid")
    return failed == 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main() ? 0 : 1)
end

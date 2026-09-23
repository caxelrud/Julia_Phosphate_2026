# =============================================================================
# notebooks.jl -- running the Pluto notebooks headless, and checking them.
#
# The notebooks are deliverables, so they are checked the way an executor would check
# them: the file has the Pluto header, every cell parses, every code cell holds
# exactly one top-level expression (the rule Pluto itself enforces), no cell
# references a global that does not exist, and the notebook writes its printout and
# its PDF. The same functions back the test suite and the script
# `scripts/validate_notebooks.jl`.
# =============================================================================

"""Pluto's cell delimiter and the marker of its `Cell order` section."""
const PLUTO_CELL_MARKER = string("# ", Char(0x2554), Char(0x2550), Char(0x2561), " ")
const PLUTO_ORDER_MARKER = string(PLUTO_CELL_MARKER, "Cell order:")

"""
    notebook_files(dir = "notebooks") -> Vector{String}

The notebooks of a repository in reading order (the numeric prefix first), skipping
Pluto's `backup` copies.
"""
function notebook_files(dir::AbstractString = "notebooks")
    isdir(dir) || return String[]
    files = sort(filter(f -> endswith(f, ".jl") && !occursin("backup", lowercase(f)) &&
                               occursin(r"^\d", f), readdir(dir)))
    return joinpath.(dir, files)
end

"""
    notebook_cells(path) -> (lines, Vector{(id, code)})

Read a Pluto notebook: its raw lines and its cells as `(cell id, code)` pairs.
"""
function notebook_cells(path::AbstractString)
    lines = readlines(path)
    cells = Tuple{String,String}[]
    current = nothing
    buffer = String[]
    for line in lines
        if startswith(line, PLUTO_ORDER_MARKER)
            current === nothing || push!(cells, (current, strip(join(buffer, "\n"))))
            current = nothing
            break
        elseif startswith(line, PLUTO_CELL_MARKER)
            current === nothing || push!(cells, (current, strip(join(buffer, "\n"))))
            current = strip(replace(line, PLUTO_CELL_MARKER => ""; count = 1))
            buffer = String[]
        elseif current !== nothing
            push!(buffer, line)
        end
    end
    current === nothing || push!(cells, (current, strip(join(buffer, "\n"))))
    return lines, cells
end

"""`true` when a cell body is a Markdown cell (`md"..."`)."""
is_markdown_cell(code::AbstractString) = startswith(code, "md\"\"\"")

"""Cell ids listed in the `Cell order` section at the end of a notebook."""
function cell_order_section(lines::Vector{String})
    ids = String[]
    seen = false
    for line in lines
        if startswith(line, PLUTO_ORDER_MARKER)
            seen = true
            continue
        end
        seen || continue
        startswith(line, "# ") || continue
        id = strip(replace(line, "# " => ""; count = 1), [Char(0x2560), Char(0x2554),
            Char(0x2550), Char(0x2561), ' '])
        isempty(id) || push!(ids, id)
    end
    return ids
end

"""Name bound by a left-hand side pattern (`:none` when there is none)."""
function bound_name(x)
    x isa Symbol && return x
    x isa Expr || return :none
    n = length(x.args)
    x.head === :(::) && n >= 1 && return bound_name(x.args[1])
    x.head === :call && n >= 1 && return bound_name(x.args[1])
    x.head === :curly && n >= 1 && return bound_name(x.args[1])
    x.head === :where && n >= 1 && return bound_name(x.args[1])
    x.head === :ref && n >= 1 && return bound_name(x.args[1])
    x.head === :tuple && n >= 1 && return bound_name(x.args[1])
    x.head === :(=) && n >= 1 && return bound_name(x.args[1])
    x.head === :kw && n >= 1 && return bound_name(x.args[1])
    return :none
end

## ---- the names a cell binds and the names it references -------------------------

# `bound_names!` collects every name a left-hand side pattern binds, including the names
# of a destructuring pattern (`(k, v)`, `(; a, b)`, `x::T`), which is what a comprehension
# or a loop over a `Dict` uses.
function bound_names!(x, acc::Set{Symbol})
    if x isa Symbol
        push!(acc, x)
        return acc
    end
    x isa Expr || return acc
    if x.head === :tuple || x.head === :parameters
        for a in x.args
            bound_names!(a, acc)
        end
    elseif x.head === :(::) || x.head === :(...)
        isempty(x.args) || bound_names!(x.args[1], acc)
    elseif x.head === :(=) || x.head === :kw
        bound_names!(x.args[1], acc)
    elseif x.head === :call || x.head === :curly || x.head === :where || x.head === :ref
        isempty(x.args) || bound_names!(x.args[1], acc)
    end
    return acc
end

# `param_names!` collects the parameters of an anonymous function. The parser reads
# `x => v -> f(v)` as a call, so the parameter can also be the last argument of a call:
# what matters is that the names the body may use are found and not reported as globals.
function param_names!(x, acc::Set{Symbol})
    if x isa Symbol
        push!(acc, x)
        return acc
    end
    x isa Expr || return acc
    if x.head === :tuple || x.head === :parameters
        for a in x.args
            param_names!(a, acc)
        end
    elseif x.head === :(::) || x.head === :(...)
        isempty(x.args) || param_names!(x.args[1], acc)
    elseif x.head === :call
        isempty(x.args) || param_names!(x.args[end], acc)
    elseif x.head === :kw
        isempty(x.args) || param_names!(x.args[1], acc)
    end
    return acc
end

function expression_bindings(expr, acc::Set{Symbol} = Set{Symbol}())
    expr isa Expr || return acc
    if expr.head === :(=) || expr.head === :(+=) || expr.head === :(-=)
        bound_names!(expr.args[1], acc)
        length(expr.args) >= 2 && expression_bindings(expr.args[2], acc)
        return acc
    elseif expr.head === :function || expr.head === :macro
        bound_names!(expr.args[1], acc)
        return acc
    elseif expr.head === :struct || expr.head === :abstract || expr.head === :primitive
        n = length(expr.args) >= 2 ? bound_name(expr.args[2]) : :none
        n === :none || push!(acc, n)
        return acc
    elseif expr.head === :const || expr.head === :global || expr.head === :local
        length(expr.args) >= 1 && bound_names!(expr.args[1], acc)
        return acc
    elseif expr.head === :using || expr.head === :import
        for a in expr.args
            a isa Symbol && push!(acc, a)
            a isa Expr && a.head === :. && (a.args[1] isa Symbol && push!(acc, a.args[1]))
        end
        return acc
    elseif expr.head === :block || expr.head === :toplevel
        for a in expr.args
            expression_bindings(a, acc)
        end
        return acc
    elseif expr.head === :for
        length(expr.args) >= 1 && bound_names!(expr.args[1], acc)
        expression_bindings(expr.args[end], acc)
        return acc
    elseif expr.head === :module
        n = bound_name(expr.args[2])
        n === :none || push!(acc, n)
        return acc
    end
    return acc
end

"""Names bound by a cell of a notebook."""
cell_bindings(exprs::AbstractVector) = begin
    acc = Set{Symbol}()
    for e in exprs
        expression_bindings(e, acc)
    end
    acc
end

"""Names referenced by one parsed expression, skipping the qualified and the quoted ones."""
function expression_references(expr, acc::Set{Symbol} = Set{Symbol}())
    if expr isa Symbol
        push!(acc, expr)
        return acc
    end
    expr isa QuoteNode && return acc
    expr isa Expr || return acc
    expr.head === :. && return acc            ## a.b: b is a field, not a global
    expr.head === :quote && return acc        ## quoted code is not executed
    expr.head === :macrocall && return acc    ## the macro expands elsewhere
    if expr.head === :kw
        ## a keyword argument: the name is a parameter of the call, not a global
        length(expr.args) >= 2 && expression_references(expr.args[2], acc)
        return acc
    end
    if expr.head === :parameters
        for a in expr.args
            expression_references(a, acc)
        end
        return acc
    end
    if expr.head === :(->)
        ## an anonymous function: its parameters are local to its body
        local_names = Set{Symbol}()
        length(expr.args) >= 1 && param_names!(expr.args[1], local_names)
        inner = Set{Symbol}()
        length(expr.args) >= 2 && expression_references(expr.args[2], inner)
        union!(acc, setdiff(inner, local_names))
        return acc
    end
    if expr.head === :generator || expr.head === :flatten
        ## a comprehension: its iteration variables are local to the expression
        local_names = Set{Symbol}()
        for clause in expr.args[2:end]
            expression_bindings(clause, local_names)
        end
        inner = Set{Symbol}()
        expression_references(expr.args[1], inner)
        union!(acc, setdiff(inner, local_names))
        return acc
    end
    if expr.head === :comprehension
        for a in expr.args
            expression_references(a, acc)
        end
        return acc
    end
    if expr.head === :(=)
        length(expr.args) >= 1 && expression_references_lhs(expr.args[1], acc)
        length(expr.args) >= 2 && expression_references(expr.args[2], acc)
        return acc
    end
    for a in expr.args
        expression_references(a, acc)
    end
    return acc
end

"""References on the left-hand side of an assignment: the indices, not the bound name."""
function expression_references_lhs(expr, acc::Set{Symbol})
    expr isa Expr || return acc
    if expr.head === :ref
        for a in expr.args[2:end]
            expression_references(a, acc)
        end
        return acc
    elseif expr.head === :(::)
        return expression_references_lhs(expr.args[1], acc)
    end
    return acc
end

"""Names referenced by a cell of a notebook."""
cell_references(exprs::AbstractVector) = begin
    acc = Set{Symbol}()
    for e in exprs
        expression_references(e, acc)
    end
    acc
end

"""The names a notebook may reference without defining them: the package, Base and the stdlibs."""
function known_notebook_names()
    ## the set is filled one name at a time: a literal that mixes quoted symbols with the
    ## Greek letters of the code base is not worth the encoding risk in a source file
    known = Set{Symbol}()
    for kw in (:end, :do, :where, :none, Symbol("true"), Symbol("false"), :nothing, :Inf,
        :NaN, :missing, :pi, Symbol("\u03c0"))
        push!(known, kw)
    end
    ## every module the package uses: their names are what a notebook cell may reference.
    ## The listing is walked one name at a time, because `names(all = true)` returns values
    ## that are not names at all (operators and docstrings, and the `Bool`s of `Core`).
    modules = (Base, Core, Main, PHOSPHATE, ModelingToolkit, OrdinaryDiffEq, NonlinearSolve,
        Symbolics, JuMP, Ipopt, HiGHS, MPC, Plots, FFTW, DSP, Dates, Statistics, Printf,
        Random, LinearAlgebra, JSON3)
    for m in modules
        for name in names(m; all = true)
            name isa Symbol && push!(known, name)
        end
    end
    ## and the names a notebook uses for itself, which the package does not import: the
    ## notebook stdlibs and the binding names its cells introduce
    for extra in (:Markdown, :InteractiveUtils, :Pluto, :Pkg, :ROOT, :bundle, :cfg, :report,
        :design, :campaign, :kpi, :fdd, :compliance, :figures, :twin, :mpc, :optimization,
        :soft, :vision, :acoustic, :sensors, :loop, :envelope, :linear, :dynamic,
        :estimation, :alignment, :reconciliation, :printout, :figs, :rows, :row, :plot)
        push!(known, extra)
    end
    return known
end

"""
    validate_notebook(path; known) -> NamedTuple

Check one notebook the way an executor would: the Pluto header, unique cell ids, a
`Cell order` section that matches the cells, every code cell parsing into exactly one
top-level expression, no reference to an undefined global, and a printout cell.
"""
function validate_notebook(path::AbstractString; known::Set{Symbol} = known_notebook_names())
    lines, cells = notebook_cells(path)
    problems = String[]

    isempty(lines) || lines[1] == "### A Pluto.jl notebook ###" ||
        push!(problems, "missing the Pluto header line")

    ids = first.(cells)
    length(unique(ids)) == length(ids) || push!(problems, "duplicate cell ids")
    order = cell_order_section(lines)
    Set(order) == Set(ids) ||
        push!(problems, string("Cell order mismatch: ", length(order), " listed against ",
            length(ids), " cells"))

    code_cells = [(id, code) for (id, code) in cells if !is_markdown_cell(code)]
    markdown_cells = [(id, code) for (id, code) in cells if is_markdown_cell(code)]
    ## Pluto is reactive: a cell may reference any name the notebook binds anywhere, in any
    ## order, so the bindings of the whole notebook are collected before the references are
    ## checked. Only a name the notebook never binds (and the package does not export) is an
    ## undefined global.
    parsed_cells = Vector{Tuple{String,Any}}()
    for (id, code) in code_cells
        parsed = try
            Meta.parseall(code)
        catch err
            push!(problems, string("cell ", first(id, 8), " does not parse: ",
                sprint(showerror, err)))
            nothing
        end
        parsed === nothing || push!(parsed_cells, (id, parsed))
    end
    bindings = Set{Symbol}()
    for (_, parsed) in parsed_cells
        exprs = Meta.isexpr(parsed, :toplevel) ? parsed.args : [parsed]
        union!(bindings, cell_bindings([e for e in exprs if !(e isa LineNumberNode)]))
    end
    defined = union(copy(known), bindings)

    printout_cells = 0
    for (id, code) in code_cells
        parsed = Meta.parseall(code)
        via_input = Base.parse_input_line(code)
        if Meta.isexpr(via_input, :toplevel) &&
           count(a -> !(a isa LineNumberNode), via_input.args) > 1
            push!(problems, string("cell ", first(id, 8),
                " holds more than one top-level expression; wrap it in begin ... end"))
        end
        exprs = Meta.isexpr(parsed, :toplevel) ? parsed.args : [parsed]
        exprs = [e for e in exprs if !(e isa LineNumberNode)]
        without = setdiff(cell_references(exprs), defined)
        isempty(without) || push!(problems, string("cell ", first(id, 8),
            " references undefined ", join(sort(string.(without)), ", ")))
        occursin("print_report_pdf", code) && (printout_cells += 1)
    end

    printout_cells > 0 || push!(problems, "no cell writes the notebook printout and its PDF")

    return (notebook = Sym(basename(path)), path = String(path), ok = isempty(problems),
        problems = problems, cells = length(cells), code_cells = length(code_cells),
        markdown_cells = length(markdown_cells), printout_cells = printout_cells)
end

"""Validate every notebook of a repository."""
function validate_notebooks(dir::AbstractString = "notebooks")
    known = known_notebook_names()
    return [validate_notebook(f; known = known) for f in notebook_files(dir)]
end

"""
    pluto_module()

`Pluto`, imported on first use so that an analysis-only session (and the test suite)
does not pay for the notebook server. The binding is fetched with `invokelatest`
because Julia enforces world-age rules for globals defined at run time.
"""
function pluto_module()
    isdefined(@__MODULE__, :Pluto) || @eval import Pluto
    return Base.invokelatest(getfield, @__MODULE__, :Pluto)
end

"""
    run_notebook(path; passes = 2, save = true) -> Dict{Symbol,Any}

Run one notebook headless in Pluto and report the outcome. Each pass runs every cell,
and a notebook passes when no cell reports an error; two passes are allowed because
the first one may have to install the package into the notebook environment before
`using PHOSPHATE` can succeed.
"""
function run_notebook(path::AbstractString; passes::Int = 2, save::Bool = true)
    pluto = pluto_module()
    t0 = time()
    report = Base.invokelatest(run_notebook_impl, pluto, String(path), passes, save)
    report[:seconds] = round(time() - t0, digits = 1)
    return report
end

"""Body of [`run_notebook`](@ref), called through `invokelatest` exactly once."""
function run_notebook_impl(pluto, path::String, passes::Int, save::Bool)
    session = pluto.ServerSession()
    nb = pluto.SessionActions.open(session, path; run_async = false)
    errors = Any[]
    for _ in 1:passes
        pluto.update_save_run!(session, nb, nb.cells; run_async = false)
        errors = [(i, c.output.body) for (i, c) in enumerate(nb.cells) if c.errored]
        isempty(errors) && break
    end
    save && pluto.save_notebook(nb)
    return Dict{Symbol,Any}(:notebook => Sym(basename(path)), :path => path,
        :ok => isempty(errors), :cells => length(nb.cells),
        :code_cells => count(c -> !isempty(strip(c.code)), nb.cells),
        :errors => errors, :seconds => 0.0)
end

"""One line per notebook run, with the first lines of every cell error."""
function print_notebook_report(r::Dict{Symbol,Any}; io::IO = stdout)
    println(io, (r[:ok] ? "PASS  " : "FAIL  "), rpad(string(r[:notebook]), 28),
        lpad(string(r[:code_cells]), 3), " code cells", lpad(string(r[:seconds]), 8), " s")
    for (i, msg) in r[:errors]
        println(io, "      cell ", i, " -> ", first(replace(string(msg), "\n" => " "), 400))
    end
    return io
end



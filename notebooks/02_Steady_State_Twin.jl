### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 0d300001
begin
	import Pkg
	const ROOT = isfile(joinpath(@__DIR__, "..", "Project.toml")) ?
		normpath(joinpath(@__DIR__, "..")) : pwd()
	Pkg.develop(path = ROOT)
	using PHOSPHATE
	using Dates, Statistics, Plots
end

# ╔═╡ 0d300002
md"""
# The steady-state digital twin

The reaction train written **once** as a square system of fifteen nonlinear balances
with ModelingToolkit: feed, acidulation, digestion, the water balance of the filters,
evaporation and ammoniation. The unknown of the balance is the operating point; the
parameters are the design and the levers the operator has.

Two properties make it a twin rather than a spreadsheet: the algebraic loop of the
recycle acid is *solved*, and the residual of every equation is returned with the
solution -- so the notebook can say how well the twin is solved instead of claiming it.
"""

# ╔═╡ 0d300003
begin
	design = default_design()
	parameters = steady_state_parameters(design)
	(length(STEADY_UNKNOWNS), length(STEADY_PARAMETERS), sort(collect(parameters); by = x -> String(x[1])))
end

# ╔═╡ 0d300004
md"""
## 1. The equations of the balance

`steady_state_system` returns the symbolic system, and `MTK.unknowns`,
`MTK.parameters` and `MTK.equations` let the notebook show it as it is written.
"""

# ╔═╡ 0d300005
begin
	system = steady_state_system(design)
	equations = [string(eq.lhs, " = ", eq.rhs) for eq in MTK.equations(system)]
	first(equations, 6)
end

# ╔═╡ 0d300006
md"""
## 2. The solution and its residuals

`mtkcompile` simplifies the system and `NonlinearProblem` + `NewtonRaphson` solve it.
The residuals below are the proof: they are recomputed from the correlations, not read
back from the solver.
"""

# ╔═╡ 0d300007
solution = solve_steady_state(design)

# ╔═╡ 0d300008
table_html(solution[:table];
	columns = [:variable, :value, :unit, :description],
	headers = Dict{Symbol,String}(:variable => "Unknown", :value => "Value", :unit => "Unit",
		:description => "Description"),
	formats = Dict{Symbol,Function}(:variable => v -> code_string(v),
		:unit => v -> code_string(v), :value => v -> fmt_number(v, digits = 4)))

# ╔═╡ 0d300009
begin
	residuals = solution[:residuals]
	[maximum(abs.(values(residuals))), solution[:max_residual], solution[:seconds],
		solution[:status]]
end

# ╔═╡ 0d30000a
md"""
## 3. The operating window at the solution

The battery limits of the design against what the twin solved: this is the table that
says whether the operating point is inside the crystallisation window and the steam
header of the plant.
"""

# ╔═╡ 0d30000b
table_html(battery_limits_check(design, solution);
	columns = [:variable, :value, :low, :high, :unit, :margin_low, :margin_high, :status],
	headers = Dict{Symbol,String}(:variable => "Variable", :value => "Solved", :low => "Low",
		:high => "High", :unit => "Unit", :status => "Status"),
	formats = Dict{Symbol,Function}(:variable => v -> code_string(v),
		:unit => v -> code_string(v), :status => v -> badge(v)))

# ╔═╡ 0d30000c
md"""
## 4. What the twin answers: the sensitivities

From the implicit function theorem on the same equations,
`du/dp = -(dF/du)^-1 dF/dp`. A one per cent move of the acid flow moves the free
sulphate; a one per cent move of the wash water moves the strength of the filtrate. The
table is the operating manual the twin writes for itself.
"""

# ╔═╡ 0d30000d
sens = sensitivity_table(design; solution = solution[:solution], parameters = parameters)

# ╔═╡ 0d30000e
table_html(first(sens, 20);
	columns = [:unknown, :parameter, :sensitivity, :elasticity_pct, :unit],
	headers = Dict{Symbol,String}(:unknown => "Unknown", :parameter => "Parameter",
		:sensitivity => "Sensitivity", :elasticity_pct => "Elasticity %", :unit => "Unit"),
	formats = Dict{Symbol,Function}(:unknown => v -> code_string(v),
		:parameter => v -> code_string(v), :unit => v -> code_string(v)))

# ╔═╡ 0d30000f
md"""
## 5. The operating envelope

Re-solve the twin along a sweep of the ore grade: where the product, the steam and the
temperature go when the mine changes the blend.
"""

# ╔═╡ 0d300010
envelope = steady_state_envelope(design; values = range(0.25, 0.33; length = 9))

# ╔═╡ 0d300011
fig_envelope(envelope; tracked = [:product, :steam, :p2o5_acid],
	title = "Envelope of the reaction train against the grade of the blend")

# ╔═╡ 0d300012
table_html(envelope;
	columns = [:value, :product, :steam, :acid_strength_weak, :temperature, :efficiency,
		:max_residual],
	headers = Dict{Symbol,String}(:value => "Grade", :product => "Product t/h",
		:steam => "Steam t/h", :acid_strength_weak => "Weak acid %",
		:temperature => "Temperature C", :efficiency => "Efficiency",
		:max_residual => "Residual"))

# ╔═╡ 0d300013
md"""
## 6. The report of the twin

The same twin as the pipeline uses, printed as a section of the report and as a PDF.
"""

# ╔═╡ 0d300014
twin = twin_report(design)

# ╔═╡ 0d300015
begin
	report = report_bundle(PipelineConfig(root = ROOT, days = 60, seed = 20260101,
		run_mpc = false, run_vision = false, run_acoustic = false, groups = [:twin]))
	preview_twin(report)
end

# ╔═╡ 0d300016
print_report_pdf(report; id = :steady_twin, group = :twin, root = ROOT)

# ╔═╡ Cell order:
# ╠═0d300001
# ╠═0d300002
# ╠═0d300003
# ╠═0d300004
# ╠═0d300005
# ╠═0d300006
# ╠═0d300007
# ╠═0d300008
# ╠═0d300009
# ╠═0d30000a
# ╠═0d30000b
# ╠═0d30000c
# ╠═0d30000d
# ╠═0d30000e
# ╠═0d30000f
# ╠═0d300010
# ╠═0d300011
# ╠═0d300012
# ╠═0d300013
# ╠═0d300014
# ╠═0d300015
# ╠═0d300016

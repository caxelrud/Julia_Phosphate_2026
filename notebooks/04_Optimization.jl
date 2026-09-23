### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 0d500001
begin
	import Pkg
	const ROOT = isfile(joinpath(@__DIR__, "..", "Project.toml")) ?
		normpath(joinpath(@__DIR__, "..")) : pwd()
	Pkg.develop(path = ROOT)
	using PHOSPHATE
	using Dates, Statistics, Plots
end

# ╔═╡ 0d500002
md"""
# Optimisation: the blend, the operating point and the sourcing

Three models of the same plant, solved every day:

1. **which ore to buy**, a linear program over the registered assays with the
   specifications of the reaction section -- iron, magnesium, silica, carbonate and the
   CaO:P2O5 ratio -- whose dual prices say what one more tenth of a per cent is worth;
2. **where to run the plant**, a nonlinear program over the correlations of the twin,
   whose optimum is the operating point that maximises the margin of the day;
3. **when to buy it**, a mixed-integer program, because a body is bought by the
   shipload and not by the tonne.
"""

# ╔═╡ 0d500003
begin
	design = default_design()
	campaign = generate_campaign(design; days = 90, seed = 20260101)
	kpi = site_kpis(campaign)
	(length(ore_bodies()), length(PERFORMANCE_TARGETS))
end

# ╔═╡ 0d500004
md"""
## 1. The optimal blend

The digester, the filters and the granulator each impose a specification on the blend.
The program finds the cheapest mix of the six registered bodies that satisfies all of
them at the design P2O5 rate, and the dual prices answer the buyer's question.
"""

# ╔═╡ 0d500005
blend = blend_optimization(campaign; design = design)

# ╔═╡ 0d500006
fig_blend(blend)

# ╔═╡ 0d500007
table_html(blend[:rows];
	columns = [:body, :tonnes_ph, :share_pct, :price, :cost_ph, :p2o5, :cao_p2o5, :fe_al, :mgo],
	headers = Dict{Symbol,String}(:body => "Ore body", :tonnes_ph => "t/h", :share_pct => "Share %",
		:price => "Price", :cost_ph => "Cost/h", :p2o5 => "P2O5 %", :cao_p2o5 => "CaO:P2O5",
		:fe_al => "Fe+Al %", :mgo => "MgO %"),
	formats = Dict{Symbol,Function}(:body => v -> code_string(v)))

# ╔═╡ 0d500008
table_html([Dict{Symbol,Any}(:constraint => k, :dual => v)
		for (k, v) in sort(collect(blend[:duals]); by = x -> -abs(x[2]))];
	columns = [:constraint, :dual],
	headers = Dict{Symbol,String}(:constraint => "Specification", :dual => "Shadow price"),
	formats = Dict{Symbol,Function}(:constraint => v -> code_string(v)))

# ╔═╡ 0d500009
md"""
## 2. The operating point of the reaction train

The nonlinear program maximises the margin of the day -- product value plus merchant
acid minus rock, acid, ammonia, steam, power, water and gypsum disposal -- inside the
operating window of the design. What comes out is the operating manual of the section:
where the temperature should sit, how much excess acid to run and what the plant is
limited by.
"""

# ╔═╡ 0d50000a
point = operating_point_optimization(campaign; design = design)

# ╔═╡ 0d50000b
table_html(point[:row]; columns = [:variable, :value],
	headers = Dict{Symbol,String}(:variable => "Decision", :value => "Optimum"),
	formats = Dict{Symbol,Function}(:variable => v -> code_string(v)))

# ╔═╡ 0d50000c
table_html(point[:controlled_row]; columns = [:variable, :value],
	headers = Dict{Symbol,String}(:variable => "Controlled variable", :value => "At the optimum"),
	formats = Dict{Symbol,Function}(:variable => v -> code_string(v)))

# ╔═╡ 0d50000d
(termination = point[:termination], iterations = point[:iterations],
	margin_per_t_product = point[:margin_per_t_product], product_tph = point[:product_tph],
	solved_in_s = point[:solve_time_s])

# ╔═╡ 0d50000e
md"""
## 3. The annual sourcing plan

The same decision seen over a year: which body to buy in which month, with at most two
bodies in a month and a fixed cost per campaign change-over. The integrality is what
makes it a MILP -- and what makes the plan something a supply chain can execute.
"""

# ╔═╡ 0d50000f
sourcing = sourcing_optimization(campaign; design = design, months = 12)

# ╔═╡ 0d500010
table_html(sourcing[:rows];
	columns = [:body, :tonnes, :share_pct, :price, :cost, :months_active, :p2o5],
	headers = Dict{Symbol,String}(:body => "Ore body", :tonnes => "t per year",
		:share_pct => "Share %", :price => "Price", :cost => "Cost", :months_active => "Months",
		:p2o5 => "P2O5 %"),
	formats = Dict{Symbol,Function}(:body => v -> code_string(v)))

# ╔═╡ 0d500011
table_html(sourcing[:months];
	columns = [:month, :rock_t, :p2o5_t, :bodies, :cost],
	headers = Dict{Symbol,String}(:month => "Month", :rock_t => "Rock t", :p2o5_t => "P2O5 t",
		:bodies => "Bodies bought", :cost => "Cost"))

# ╔═╡ 0d500012
begin
	report = report_bundle(PipelineConfig(root = ROOT, days = 60, seed = 20260101,
		run_mpc = false, run_vision = false, run_acoustic = false, groups = [:optimization]))
	preview_optimization(report)
end

# ╔═╡ 0d500013
print_report_pdf(report; id = :optimization, group = :optimization, root = ROOT)

# ╔═╡ Cell order:
# ╠═0d500001
# ╠═0d500002
# ╠═0d500003
# ╠═0d500004
# ╠═0d500005
# ╠═0d500006
# ╠═0d500007
# ╠═0d500008
# ╠═0d500009
# ╠═0d50000a
# ╠═0d50000b
# ╠═0d50000c
# ╠═0d50000d
# ╠═0d50000e
# ╠═0d50000f
# ╠═0d500010
# ╠═0d500011
# ╠═0d500012
# ╠═0d500013

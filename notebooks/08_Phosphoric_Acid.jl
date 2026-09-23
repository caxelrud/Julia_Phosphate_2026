### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 0d900001
begin
	import Pkg
	const ROOT = isfile(joinpath(@__DIR__, "..", "Project.toml")) ?
		normpath(joinpath(@__DIR__, "..")) : pwd()
	Pkg.develop(path = ROOT)
	using PHOSPHATE
	using Dates, Statistics, Plots
end

# ╔═╡ 0d900002
md"""
# Phosphoric acid: the balance, the specification and the cost

The acid train of the complex -- attack, filtration, evaporation -- read as a product
in its own right: how much P2O5 reaches the filters and where it goes from there, what
the merchant grade has to satisfy, and what a tonne of P2O5 costs as acid against what
it sells for.

The acid of the wet process is the intermediate of the fertiliser route and the product
of the merchant route at the same time, so an evaluation of the acid has to say which
tonne it is talking about: this notebook keeps the two denominators apart, *per tonne of
P2O5 sold as acid* for the feed, *per tonne of P2O5 concentrated* for the evaporators.
"""

# ╔═╡ 0d900003
begin
	design = default_design()
	campaign = generate_campaign(design; days = 90, seed = 20260101)
	kpi = site_kpis(campaign)
	acid = kpi[:acid]
	(days = campaign.meta[:days], signals = length(campaign.book),
		intervals = length(campaign.schedule[:mode]))
end

# ╔═╡ 0d900004
md"""
## 1. The merchant acid of the campaign

`acid_evaluation` reads the historian and returns the bundle this notebook walks
through: the balance, the specification, the consumption and the cost. The grade of the
acid is classified with `acid_grade_of`, so what leaves the evaporators is labelled the
way the market labels it.
"""

# ╔═╡ 0d900005
kv_table([
	"Merchant acid" => string(fmt_number(acid[:summary][:merchant_kt], digits = 1), " kt (",
		fmt_number(acid[:summary][:merchant_p2o5_kt], digits = 1), " kt P2O5, ",
		fmt_number(acid[:summary][:merchant_h3po4_kt], digits = 1), " kt as H3PO4)"),
	"Grade" => string(fmt_number(acid[:summary][:grade_p2o5], digits = 2), " % P2O5 (",
		fmt_number(acid[:summary][:grade_h3po4], digits = 2), " % H3PO4), ",
		code_string(acid[:summary][:grade])),
	"Acid yield" => string(fmt_number(acid[:summary][:filtration_yield_pct], digits = 2),
		" % of the P2O5 fed reaches the filters, the evaporation closes at ",
		fmt_number(acid[:summary][:concentration_yield_pct], digits = 2), " %"),
	"Concentration" => string(fmt_number(acid[:summary][:water_per_p2o5], digits = 2),
		" m3 of feed and ", fmt_number(acid[:summary][:thermal_gj_per_p2o5], digits = 2),
		" GJ of steam per t P2O5, economy ",
		fmt_number(acid[:summary][:economy], digits = 2)),
	"Cost" => string(fmt_number(acid[:summary][:cost_per_t_p2o5], digits = 0), " ",
		code_string(acid[:cost][:currency]), " per t P2O5 as acid, margin ",
		fmt_number(acid[:summary][:margin_per_t_p2o5], digits = 0), " per t"),
	"Specification" => string("the acid is ", code_string(acid[:quality][:status]),
		" against the limits of the ", code_string(acid[:quality][:grade]), " grade"),
]; title = "The acid route of the campaign")

# ╔═╡ 0d900006
md"""
## 2. Where the P2O5 of the attack goes

The attack feeds the filters, and the filters feed two products: the merchant acid of
the storage tank and the concentrated acid of the granulation line. The cake takes the
water-soluble loss. The four rows add up to the P2O5 fed -- the row that does not is the
one the accountant should look at.
"""

# ╔═╡ 0d900007
table_html(acid[:balance]; columns = [:destination, :p2o5_t, :share_pct, :note],
	headers = Dict{Symbol,String}(:destination => "Destination", :p2o5_t => "t P2O5",
		:share_pct => "Share %", :note => "Note"),
	formats = Dict{Symbol,Function}(:destination => v -> to_string(v)),
	title = "The P2O5 of the attack, by destination")

# ╔═╡ 0d900008
fig_acid_balance(acid[:balance])

# ╔═╡ 0d900009
md"""
## 3. The specification of the merchant grade

The acid leaves the plant against a contract: 52 % P2O5 at least, and sulphate,
fluorine, solids, iron and colour under their limits. `ACID_SPECIFICATIONS` is that
table, and each row names the instrument that evidences it -- the analyser of the
storage tank is a soft sensor here, like every other variable nobody measures every
hour.
"""

# ╔═╡ 0d90000a
table_html(acid[:quality][:rows];
	columns = [:spec, :tag, :value, :limit, :unit, :comparator, :margin_pct, :status],
	headers = Dict{Symbol,String}(:spec => "Specification", :tag => "Instrument",
		:value => "Campaign", :limit => "Limit", :unit => "Unit", :comparator => "Direction",
		:margin_pct => "Margin %", :status => "Status"),
	formats = Dict{Symbol,Function}(:spec => v -> to_string(v), :tag => v -> code_string(v),
		:unit => v -> code_string(v), :comparator => v -> code_string(v),
		:status => v -> badge(v)),
	title = "The merchant acid against the specification")

# ╔═╡ 0d90000b
fig_acid_quality(acid[:quality][:rows])

# ╔═╡ 0d90000c
md"""
## 4. What a tonne of P2O5 costs in the acid route

The evaporators concentrate the acid of both products, so their steam and power are
reported per tonne of P2O5 *concentrated*; the feed is allocated to the acid by the
share of the P2O5 that leaves as merchant acid, which is what `allocation_pct` says.
The cost per tonne of P2O5 as acid is then comparable with the price of the merchant
market.
"""

# ╔═╡ 0d90000d
table_html(acid[:consumption]; columns = [:metric, :value, :unit, :basis, :note],
	headers = Dict{Symbol,String}(:metric => "Consumption", :value => "Value", :unit => "Unit",
		:basis => "Basis", :note => "Note"),
	formats = Dict{Symbol,Function}(:metric => v -> to_string(v), :unit => v -> code_string(v),
		:basis => v -> code_string(v)),
	title = string("Consumption of the acid route (allocation ",
		fmt_number(acid[:cost][:allocation_pct], digits = 1), " % of the fed P2O5)")

# ╔═╡ 0d90000e
fig_acid_cost(acid[:cost][:rows])

# ╔═╡ 0d90000f
md"""
## 5. The virtual analyser of the evaporator house

The grade of the acid is measured in the laboratory once a shift; the boiling point of
the acid, the vacuum of the evaporator and its steam are measured every hour. The
process soft sensor of the catalogue that infers the strength from those three is
trained on the same campaign: its `R2` is how much of the analyser an instrument can
replace. It is not one -- a deviation injected at the analyser itself is a fault no
instrument of the evaporator can see, and the sensor register says so.
"""

# ╔═╡ 0d900010
begin
	sensors = train_process_sensors(campaign)
	acid_sensor = first(s for s in sensors if s.target === :STRONG_ACID_P2O5)
	(id = acid_sensor.id, target = acid_sensor.target, inputs = acid_sensor.inputs,
		r2 = round(acid_sensor.r2, digits = 3), rmse = round(acid_sensor.rmse, digits = 3))
end

# ╔═╡ 0d900011
table_html(sensor_table([acid_sensor], campaign);
	columns = [:sensor, :target, :unit, :r2, :rmse, :bias, :rows, :in_domain_pct, :status],
	headers = Dict{Symbol,String}(:sensor => "Sensor", :target => "Infers", :unit => "Unit",
		:r2 => "R2", :rmse => "RMSE", :bias => "Bias", :rows => "Samples",
		:in_domain_pct => "In domain %", :status => "Status"),
	formats = Dict{Symbol,Function}(:sensor => v -> code_string(v),
		:target => v -> code_string(v), :unit => v -> code_string(v),
		:status => v -> badge(v)))

# ╔═╡ 0d900012
md"""
## 6. The acid section of the report

The same bundle the PDF is printed from: the section, the figures and the tables of the
acid route, ready for the customer or the auditor.
"""

# ╔═╡ 0d900013
begin
	bundle = report_bundle(PipelineConfig(root = ROOT, days = 60, seed = 20260101,
		run_vision = false, run_acoustic = false, groups = [:acid]))
	preview_acid(bundle)
end

# ╔═╡ 0d900014
print_report_pdf(bundle; id = :acid, group = :acid, root = ROOT)

# ╔═╡ Cell order:
# ╠═0d900001
# ╠═0d900002
# ╠═0d900003
# ╠═0d900004
# ╠═0d900005
# ╠═0d900006
# ╠═0d900007
# ╠═0d900008
# ╠═0d900009
# ╠═0d90000a
# ╠═0d90000b
# ╠═0d90000c
# ╠═0d90000d
# ╠═0d90000e
# ╠═0d90000f
# ╠═0d900010
# ╠═0d900011
# ╠═0d900012
# ╠═0d900013
# ╠═0d900014

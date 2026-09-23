### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 0d200001
begin
	import Pkg
	const ROOT = isfile(joinpath(@__DIR__, "..", "Project.toml")) ?
		normpath(joinpath(@__DIR__, "..")) : pwd()
	Pkg.develop(path = ROOT)
	using PHOSPHATE
	using Dates, Statistics, Plots
end

# ╔═╡ 0d200002
md"""
# The process and its metallurgy

Ore preparation, flotation, attack, filtration and granulation, from the registered
design and from the campaign: what the plant did to the ore, and what the ore did to
the plant.
"""

# ╔═╡ 0d200003
md"""
## 1. The ore bodies of the blend

The assays are representative published figures for the sedimentary and igneous
phosphate rocks the industry treats. They are screening values, not the assay of any
particular mine, and every one of them is a `Composition`, so they can be blended,
digested and diluted by the same arithmetic.
"""

# ╔═╡ 0d200004
begin
	design = default_design()
	campaign = generate_campaign(design; days = 120, seed = 20260101)
	kpi = site_kpis(campaign)
	fdd = fault_detection_report(campaign, kpi)
	compliance = compliance_report(kpi, fdd)
	figures = figure_set(campaign, kpi, fdd, compliance)
	(length(ORE_BODIES), sort(ore_bodies(); by = String))
end

# ╔═╡ 0d200005
table_html(ore_grade_table();
	columns = [:body, :p2o5, :bpl, :cao, :sio2, :fe2o3, :mgo, :f, :co2, :cao_p2o5, :gangue],
	headers = Dict{Symbol,String}(:body => "Ore body", :p2o5 => "P2O5 %", :bpl => "BPL %",
		:cao => "CaO %", :sio2 => "SiO2 %", :fe2o3 => "Fe2O3 %", :mgo => "MgO %", :f => "F %",
		:co2 => "CO2 %", :cao_p2o5 => "CaO:P2O5", :gangue => "Gangue %"),
	formats = Dict{Symbol,Function}(:body => v -> code_string(v)))

# ╔═╡ 0d200006
md"""
## 2. The acidulation demand of an assay

The sulphuric acid a tonne of rock needs is the stoichiometry of the fluorapatite plus
the demand of the free carbonate -- which is why the CaO:P2O5 ratio of the blend is an
operating variable and not a laboratory curiosity.
"""

# ╔═╡ 0d200007
begin
	blend = blend([ore_body(:khouribga), ore_body(:gafsa)], [0.6, 0.4])
	demand = acid_requirement(1000.0, blend; excess = design.acid_excess)
	(blend_grade = p2o5_grade(blend), bpl = bpl_grade(blend), cao_p2o5 = ratio(blend, :cao, :p2o5),
		acid_stoichiometric = demand.stoich, acid_carbonate = demand.carbonate,
		acid_total = demand.total,
		gypsum = gypsum_production(1000.0, blend), co2 = carbonate_co2(1000.0, blend))
end

# ╔═╡ 0d200008
md"""
## 3. Flotation: the two-product balance

The concentrate grade and the tailings grade of the same hour have to satisfy the
two-product formula of a two-product separation. The balance closes by construction in
the plant model, which is exactly what a metallurgist checks on a shift report.
"""

# ╔═╡ 0d200009
begin
	m = mode_mask(campaign)
	feed = masked_mean(campaign, :FLOT_FEED_P2O5, m)
	conc = masked_mean(campaign, :CONC_P2O5, m)
	tail = masked_mean(campaign, :TAIL_P2O5, m)
	rom = masked_sum(campaign, :ROM_FEED, m)
	rock = masked_sum(campaign, :ROCK_FEED, m) / 0.985
	(ore_t = rom, concentrate_t = rock, feed_grade = feed, concentrate_grade = conc,
		tailings_grade = tail, recovery_pct = kpi[:beneficiation][:recovery_pct],
		implied_ratio = (feed - tail) / (conc - tail), measured_ratio = rock / rom)
end

# ╔═╡ 0d20000a
data = campaign_table(campaign)

# ╔═╡ 0d20000b
table_html(first(data, 20);
	columns = [:tag, :area, :unit, :nominal, :mean, :completeness_pct],
	headers = Dict{Symbol,String}(:tag => "Signal", :area => "Area", :unit => "Unit",
		:nominal => "Nominal", :mean => "Campaign mean", :completeness_pct => "Data %"),
	formats = Dict{Symbol,Function}(:tag => v -> code_string(v), :area => v -> code_string(v),
		:unit => v -> code_string(v)))

# ╔═╡ 0d20000c
md"""
## 4. The reaction train, filtration and evaporation

The same numbers the monthly report carries, section by section, with the figures that
show the trend of the grade, the temperature and the strength of the acid.
"""

# ╔═╡ 0d20000d
Dict{Symbol,Any}(:attack => kpi[:attack], :filtration => kpi[:filtration],
	:evaporation => kpi[:evaporation], :granulation => kpi[:granulation])


# ╔═╡ 0d20000e
figures[:grade][:plot]

# ╔═╡ 0d20000f
figures[:temperature][:plot]

# ╔═╡ 0d200010
figures[:acid][:plot]

# ╔═╡ 0d200011
figures[:free_so4][:plot]

# ╔═╡ 0d200012
md"""
## 5. The product, the energy and the cost

Granulation and finishing on one side; the energy, the cost and the carbon of the
tonne of product on the other.
"""

# ╔═╡ 0d200013
figures[:energy_split][:plot]

# ╔═╡ 0d200014
figures[:cost_split][:plot]

# ╔═╡ 0d200015
begin
	report = report_bundle(PipelineConfig(root = ROOT, days = 90, seed = 20260101,
		run_mpc = false, run_vision = false, run_acoustic = false, groups = [:ore, :reaction,
			:product, :targets]))
	preview_ore(report)
end

# ╔═╡ 0d200016
preview_reaction(report)

# ╔═╡ 0d200017
preview_product(report)

# ╔═╡ 0d200018
print_report_pdf(report; id = :process, group = :ore, root = ROOT)

# ╔═╡ Cell order:
# ╠═0d200001
# ╠═0d200002
# ╠═0d200003
# ╠═0d200004
# ╠═0d200005
# ╠═0d200006
# ╠═0d200007
# ╠═0d200008
# ╠═0d200009
# ╠═0d20000a
# ╠═0d20000b
# ╠═0d20000c
# ╠═0d20000d
# ╠═0d20000e
# ╠═0d20000f
# ╠═0d200010
# ╠═0d200011
# ╠═0d200012
# ╠═0d200013
# ╠═0d200014
# ╠═0d200015
# ╠═0d200016
# ╠═0d200017
# ╠═0d200018

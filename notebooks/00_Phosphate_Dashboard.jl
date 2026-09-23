### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 0d100001
begin
	import Pkg
	const ROOT = isfile(joinpath(@__DIR__, "..", "Project.toml")) ?
		normpath(joinpath(@__DIR__, "..")) : pwd()
	Pkg.develop(path = ROOT)
	using PHOSPHATE
	using Dates, Statistics, Plots
end

# ╔═╡ 0d100002
md"""
# Phosphate complex dashboard

A phosphate complex from the ore to the bagged fertiliser: the beneficiation plant,
the wet-process acid train, the granulation line, the digital twin of the reaction
section, the optimiser that decides the blend and the operating point, the predictive
controller, and the soft sensors that infer what nobody instruments.

Every categorical value in this notebook is a **`Symbol`** -- the areas
(`:beneficiation`, `:flotation`, `:attack`, `:filtration`, `:evaporation`,
`:acid_plant`, `:granulation`, `:utilities`, `:tailings`), the species, the streams,
the equipment tags, the units, the signal tags and the statuses. The tables, the cards
and the figures below are produced by the same functions that render the PDF
printout, so the notebook and the printout cannot drift apart.
"""

# ╔═╡ 0d100003
md"""
## 1. The vocabulary and the registered design

`validate_vocabulary` proves the vocabulary is consistent before a single number is
produced, and `default_design` is the design every model of the package reads.
"""

# ╔═╡ 0d100004
validate_vocabulary()

# ╔═╡ 0d100005
design = default_design()

# ╔═╡ 0d100006
design_summary(design)

# ╔═╡ 0d100007
md"""
## 2. The flowsheet

Thirty-four unit operations from the crusher to the coated product, with the streams
each one takes and produces. `default_flowsheet` builds them from the design, so a
capacity change travels through the whole package.
"""

# ╔═╡ 0d100008
flowsheet = default_flowsheet(design)

# ╔═╡ 0d100009
flowsheet_summary(flowsheet)

# ╔═╡ 0d10000a
begin
	rows = flowsheet_table(flowsheet)
	table_html(rows; columns = [:unit, :area, :kind, :feeds, :products, :capacity],
		headers = Dict{Symbol,String}(:unit => "Unit", :area => "Area", :kind => "Kind",
			:feeds => "Feeds", :products => "Products", :capacity => "Capacity"),
		formats = Dict{Symbol,Function}(:unit => v -> code_string(v),
			:area => v -> code_string(v), :kind => v -> code_string(v)))
end

# ╔═╡ 0d10000b
md"""
## 3. The campaign

`generate_campaign` runs the plant model for a year of hourly intervals: a production
schedule with planned outages, an ore blend that changes every week, and fifteen
deviations injected on purpose (a fouled cooler, a blinded filter cloth, a worn mill
liner, an ammonia overfeed) so that the fault detector can be scored.
"""

# ╔═╡ 0d10000c
campaign = generate_campaign(design; days = 120, seed = 20260101)

# ╔═╡ 0d10000d
campaign_summary(campaign)

# ╔═╡ 0d10000e
deviation_table(campaign.deviations)

# ╔═╡ 0d10000f
md"""
## 4. The performance of the campaign

One symbol-keyed bundle: ore and concentrate, the acidulation ratios of the reaction
section, the steam and power of the tonne of P2O5, the quality of the product, the
emissions, the cost and the carbon.
"""

# ╔═╡ 0d100010
kpi = site_kpis(campaign)

# ╔═╡ 0d100011
sort(collect(keys(kpi)); by = String)

# ╔═╡ 0d100012
begin
	fdd = fault_detection_report(campaign, kpi)
	compliance = compliance_report(kpi, fdd)
	figures = figure_set(campaign, kpi, fdd, compliance)
	(bundle_ready = true, figures = length(figures), findings = fdd[:summary][:count],
		compliance = compliance[:status])
end

# ╔═╡ 0d100013
Cards = area_cards(kpi)

# ╔═╡ 0d100014
PrintableHTML(cards_html(Cards; columns = 5))

# ╔═╡ 0d100015
figures[:recovery_cascade][:plot]

# ╔═╡ 0d100016
figures[:production][:plot]

# ╔═╡ 0d100017
figures[:targets][:plot]

# ╔═╡ 0d100018
md"""
## 5. The printout and its PDF

The next cells build the report bundle -- the same object the pipeline builds -- and
print it. The last cell writes the printout and prints it to PDF with the headless
browser, so the PDF of this notebook and the HTML it displays are the same document.
"""

# ╔═╡ 0d100019
report = report_bundle(PipelineConfig(root = ROOT, days = 100, seed = 20260101,
	vision_samples = 60, vision_size = 64, acoustic_samples = 40, acoustic_n = 2048,
	mpc_steps = 12, dynamic_hours = 24.0, groups = [:all], render_pdf = false))

# ╔═╡ 0d10001a
preview_executive(report)

# ╔═╡ 0d10001b
preview_quality(report)

# ╔═╡ 0d10001c
print_report_pdf(report; id = :dashboard, group = :all, root = ROOT)

# ╔═╡ 0d10001d
md"""
---
*Everything in this notebook and in its PDF comes from the same bundle, and the bundle
comes from the design and the seed recorded above.*
"""

# ╔═╡ Cell order:
# ╠═0d100001
# ╠═0d100002
# ╠═0d100003
# ╠═0d100004
# ╠═0d100005
# ╠═0d100006
# ╠═0d100007
# ╠═0d100008
# ╠═0d100009
# ╠═0d10000a
# ╠═0d10000b
# ╠═0d10000c
# ╠═0d10000d
# ╠═0d10000e
# ╠═0d10000f
# ╠═0d100010
# ╠═0d100011
# ╠═0d100012
# ╠═0d100013
# ╠═0d100014
# ╠═0d100015
# ╠═0d100016
# ╠═0d100017
# ╠═0d100018
# ╠═0d100019
# ╠═0d10001a
# ╠═0d10001b
# ╠═0d10001c
# ╠═0d10001d

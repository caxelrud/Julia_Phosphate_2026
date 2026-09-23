### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ f457d1a0-b787-11f1-afcc-5b9fb13a16b6
begin
	import Pkg
	const ROOT = isfile(joinpath(@__DIR__, "..", "Project.toml")) ?
		normpath(joinpath(@__DIR__, "..")) : pwd()
	Pkg.develop(path = ROOT)
	using PHOSPHATE
	using Dates, Statistics, Plots
end

# ╔═╡ f45846d0-b787-11f1-8af8-8531034c75ee
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

# ╔═╡ f45846d0-b787-11f1-8d0b-f3de8316b9b5
md"""
## 1. The vocabulary and the registered design

`validate_vocabulary` proves the vocabulary is consistent before a single number is
produced, and `default_design` is the design every model of the package reads.
"""

# ╔═╡ f45846d0-b787-11f1-8e81-b199ac13790c
validate_vocabulary()

# ╔═╡ f45846d0-b787-11f1-b852-b9721ae5cef8
design = default_design()

# ╔═╡ f45846d0-b787-11f1-bd25-99591ada31a1
design_summary(design)

# ╔═╡ f45846d0-b787-11f1-95a6-5190d647baa9
md"""
## 2. The flowsheet

Thirty-four unit operations from the crusher to the coated product, with the streams
each one takes and produces. `default_flowsheet` builds them from the design, so a
capacity change travels through the whole package.
"""

# ╔═╡ f45846d0-b787-11f1-ab3c-f50dbc5c5638
flowsheet = default_flowsheet(design)

# ╔═╡ f45846d0-b787-11f1-b37f-a3ca08fa8a23
flowsheet_summary(flowsheet)

# ╔═╡ f45846d0-b787-11f1-b325-33532701b08d
begin
	rows = flowsheet_table(flowsheet)
	table_html(rows; columns = [:unit, :area, :kind, :feeds, :products, :capacity],
		headers = Dict{Symbol,String}(:unit => "Unit", :area => "Area", :kind => "Kind",
			:feeds => "Feeds", :products => "Products", :capacity => "Capacity"),
		formats = Dict{Symbol,Function}(:unit => v -> code_string(v),
			:area => v -> code_string(v), :kind => v -> code_string(v)))
end

# ╔═╡ f45846d0-b787-11f1-b8f0-3185f0fe2793
md"""
## 3. The campaign

`generate_campaign` runs the plant model for a year of hourly intervals: a production
schedule with planned outages, an ore blend that changes every week, and fifteen
deviations injected on purpose (a fouled cooler, a blinded filter cloth, a worn mill
liner, an ammonia overfeed) so that the fault detector can be scored.
"""

# ╔═╡ f45846d0-b787-11f1-b6fc-dd2e00b82fd9
campaign = generate_campaign(design; days = 120, seed = 20260101)

# ╔═╡ f45846d0-b787-11f1-abce-cd0be40f374a
campaign_summary(campaign)

# ╔═╡ f45846d0-b787-11f1-8e8a-d39ab7fbcf77
deviation_table(campaign.deviations)

# ╔═╡ f45846d0-b787-11f1-8bbe-517d2ebb06c0
md"""
## 4. The performance of the campaign

One symbol-keyed bundle: ore and concentrate, the acidulation ratios of the reaction
section, the steam and power of the tonne of P2O5, the quality of the product, the
emissions, the cost and the carbon.
"""

# ╔═╡ f45846d0-b787-11f1-8627-77867eeb7769
kpi = site_kpis(campaign)

# ╔═╡ f45846d0-b787-11f1-ad36-2348bf739223
sort(collect(keys(kpi)); by = String)

# ╔═╡ f45846d0-b787-11f1-8965-af293ae05cf0
begin
	fdd = fault_detection_report(campaign, kpi)
	compliance = compliance_report(kpi, fdd)
	figures = figure_set(campaign, kpi, fdd, compliance)
	(bundle_ready = true, figures = length(figures), findings = fdd[:summary][:count],
		compliance = compliance[:status])
end

# ╔═╡ f45846d0-b787-11f1-a780-65f3f25d2446
Cards = area_cards(kpi)

# ╔═╡ f45846d0-b787-11f1-b9fe-157492a27086
PrintableHTML(cards_html(Cards; columns = 5))

# ╔═╡ f45846d0-b787-11f1-87fd-79ddf441ca6d
figures[:recovery_cascade][:plot]

# ╔═╡ f45846d0-b787-11f1-9d1f-2f38283a4910
figures[:production][:plot]

# ╔═╡ f45846d0-b787-11f1-bc34-b398d1f397fd
figures[:targets][:plot]

# ╔═╡ f45846d0-b787-11f1-8933-edd7a1d7633a
md"""
## 5. The printout and its PDF

The next cells build the report bundle -- the same object the pipeline builds -- and
print it. The last cell writes the printout and prints it to PDF with the headless
browser, so the PDF of this notebook and the HTML it displays are the same document.
"""

# ╔═╡ f45846d0-b787-11f1-bd7f-094fcf43249b
report = report_bundle(PipelineConfig(root = ROOT, days = 100, seed = 20260101,
	vision_samples = 60, vision_size = 64, acoustic_samples = 40, acoustic_n = 2048,
	mpc_steps = 12, dynamic_hours = 24.0, groups = [:all], render_pdf = false))

# ╔═╡ f45846d0-b787-11f1-8244-f57fb58e744b
preview_executive(report)

# ╔═╡ f45846d0-b787-11f1-bacb-7f52e8079f0c
preview_quality(report)

# ╔═╡ f45846d0-b787-11f1-b724-4b6d5f09979c
print_report_pdf(report; id = :dashboard, group = :all, root = ROOT)

# ╔═╡ f45846d0-b787-11f1-94f3-57ea6d9dad8d
md"""
---
*Everything in this notebook and in its PDF comes from the same bundle, and the bundle
comes from the design and the seed recorded above.*
"""

# ╔═╡ Cell order:
# ╠═f457d1a0-b787-11f1-afcc-5b9fb13a16b6
# ╠═f45846d0-b787-11f1-8af8-8531034c75ee
# ╠═f45846d0-b787-11f1-8d0b-f3de8316b9b5
# ╠═f45846d0-b787-11f1-8e81-b199ac13790c
# ╠═f45846d0-b787-11f1-b852-b9721ae5cef8
# ╠═f45846d0-b787-11f1-bd25-99591ada31a1
# ╠═f45846d0-b787-11f1-95a6-5190d647baa9
# ╠═f45846d0-b787-11f1-ab3c-f50dbc5c5638
# ╠═f45846d0-b787-11f1-b37f-a3ca08fa8a23
# ╠═f45846d0-b787-11f1-b325-33532701b08d
# ╠═f45846d0-b787-11f1-b8f0-3185f0fe2793
# ╠═f45846d0-b787-11f1-b6fc-dd2e00b82fd9
# ╠═f45846d0-b787-11f1-abce-cd0be40f374a
# ╠═f45846d0-b787-11f1-8e8a-d39ab7fbcf77
# ╠═f45846d0-b787-11f1-8bbe-517d2ebb06c0
# ╠═f45846d0-b787-11f1-8627-77867eeb7769
# ╠═f45846d0-b787-11f1-ad36-2348bf739223
# ╠═f45846d0-b787-11f1-8965-af293ae05cf0
# ╠═f45846d0-b787-11f1-a780-65f3f25d2446
# ╠═f45846d0-b787-11f1-b9fe-157492a27086
# ╠═f45846d0-b787-11f1-87fd-79ddf441ca6d
# ╠═f45846d0-b787-11f1-9d1f-2f38283a4910
# ╠═f45846d0-b787-11f1-bc34-b398d1f397fd
# ╠═f45846d0-b787-11f1-8933-edd7a1d7633a
# ╠═f45846d0-b787-11f1-bd7f-094fcf43249b
# ╠═f45846d0-b787-11f1-8244-f57fb58e744b
# ╠═f45846d0-b787-11f1-bacb-7f52e8079f0c
# ╠═f45846d0-b787-11f1-b724-4b6d5f09979c
# ╠═f45846d0-b787-11f1-94f3-57ea6d9dad8d

### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 0d800001
begin
	import Pkg
	const ROOT = isfile(joinpath(@__DIR__, "..", "Project.toml")) ?
		normpath(joinpath(@__DIR__, "..")) : pwd()
	Pkg.develop(path = ROOT)
	using PHOSPHATE
	using Dates, Statistics, Plots
end

# ╔═╡ 0d800002
md"""
# Diagnostics, compliance and the quality of the data

Three questions an auditor and an operator both ask: *is anything wrong with the plant,
what is it worth fixing, and what has to be shown as evidence?* The detector answers the
first, the money at stake answers the second, and the clause register of nine frameworks
answers the third -- from the same numbers, in the same session.
"""

# ╔═╡ 0d800003
begin
	design = default_design()
	campaign = generate_campaign(design; days = 120, seed = 20260101)
	kpi = site_kpis(campaign)
	(seed = campaign.meta[:seed], signals = length(campaign.book),
		intervals = length(campaign.schedule[:mode]))
end

# ╔═╡ 0d800004
md"""
## 1. The detector

Twenty rules watch the historian the way a plant engineer would: a value against its
reference, a specific consumption against the stoichiometric expectation, a cross-signal
balance and a permit limit. A rule fires when the rolling mean of its metric stays
outside the reference for a minimum number of intervals, and every finding carries the
money at stake.
"""

# ╔═╡ 0d800005
fdd = fault_detection_report(campaign, kpi)

# ╔═╡ 0d800006
fdd[:summary]

# ╔═╡ 0d800007
table_html(fdd[:rows];
	columns = [:severity, :area, :rule, :tag, :metric, :reference, :unit, :deviation_pct, :from,
		:to, :intervals, :cost_at_stake],
	headers = Dict{Symbol,String}(:severity => "Severity", :area => "Area", :rule => "Rule",
		:tag => "Signal", :metric => "Measured", :reference => "Reference", :unit => "Unit",
		:deviation_pct => "Deviation %", :from => "From", :to => "To", :intervals => "Hours",
		:cost_at_stake => "Value at stake"),
	formats = Dict{Symbol,Function}(:severity => v -> badge(v), :area => v -> code_string(v),
		:rule => v -> code_string(v), :tag => v -> code_string(v), :unit => v -> code_string(v),
		:from => v -> string(v), :to => v -> string(v)))

# ╔═╡ 0d800008
md"""
## 2. Did the detector catch what the campaign injected?

The campaign injected fifteen deviations on purpose and recorded them, so the detector can
be *scored* instead of trusted. The table below is the scoring: for every injected
deviation, whether a rule of the expected family fired inside its window.
"""

# ╔═╡ 0d800009
table_html(fdd[:verification][:rows];
	columns = [:fault, :role, :kind, :magnitude, :unit, :from_hour, :to_hour, :detected, :rule,
		:findings],
	headers = Dict{Symbol,String}(:fault => "Injected deviation", :role => "Role", :kind => "Kind",
		:magnitude => "Magnitude", :unit => "Unit", :from_hour => "From h", :to_hour => "To h",
		:detected => "Detected", :rule => "Rule", :findings => "Findings"),
	formats = Dict{Symbol,Function}(:fault => v -> code_string(v), :role => v -> code_string(v),
		:kind => v -> code_string(v), :unit => v -> code_string(v), :rule => v -> code_string(v)))

# ╔═╡ 0d80000a
(fdd[:verification][:detected], fdd[:verification][:injected],
	fdd[:verification][:detection_rate_pct], fdd[:verification][:status])

# ╔═╡ 0d80000b
md"""
## 3. The compliance register

The clause register of the plant: ISO 50001 and ISO 14001, ISO 46001, ISO 9001, the GHG
Protocol, the EU Industrial Emissions Directive, the US EPA subpart for phosphoric acid,
the IFA best-available-technique document and the phosphogypsum stack code. Every clause
is evidenced by a metric the report already publishes, so the scorecard cannot disagree
with the numbers.
"""

# ╔═╡ 0d80000c
compliance = compliance_report(kpi, fdd)

# ╔═╡ 0d80000d
compliance[:scorecard][:by_framework][:ifa_bat]

# ╔═╡ 0d80000e
table_html(compliance[:register];
	columns = [:framework, :clause, :title, :metric, :value, :target, :unit, :margin_pct, :status],
	headers = Dict{Symbol,String}(:framework => "Framework", :clause => "Clause", :title => "Title",
		:metric => "Metric", :value => "Value", :target => "Target", :unit => "Unit",
		:margin_pct => "Margin %", :status => "Status"),
	formats = Dict{Symbol,Function}(:framework => v -> code_string(v),
		:clause => v -> code_string(v), :metric => v -> code_string(v), :unit => v -> code_string(v),
		:status => v -> badge(v)))

# ╔═╡ 0d80000f
table_html(compliance[:actions];
	columns = [:framework, :clause, :metric, :value, :target, :gap_pct, :status, :action],
	headers = Dict{Symbol,String}(:framework => "Framework", :clause => "Clause", :metric => "Metric",
		:value => "Value", :target => "Target", :gap_pct => "Gap %", :status => "Status",
		:action => "Corrective action"),
	formats = Dict{Symbol,Function}(:framework => v -> code_string(v),
		:clause => v -> code_string(v), :metric => v -> code_string(v), :status => v -> badge(v)))

# ╔═╡ 0d800010
md"""
## 4. The quality of the historian and the reconciliation of the flows

The historian contains gaps, stalls and drifts on purpose, so the data-quality section has
something to account for; and the flows of the campaign are reconciled against the
stoichiometry of the reaction section, with the global test of the chi-square telling
whether the measurements are consistent with the balances.
"""

# ╔═╡ 0d800011
reconciliation = reconcile_measurements(campaign)

# ╔═╡ 0d800012
table_html(reconciliation[:rows];
	columns = [:tag, :measured, :reconciled, :adjustment, :adjustment_sigma, :unit, :gross_error],
	headers = Dict{Symbol,String}(:tag => "Signal", :measured => "Measured",
		:reconciled => "Reconciled", :adjustment => "Adjustment", :adjustment_sigma => "In sigma",
		:unit => "Unit", :gross_error => "Gross error"),
	formats = Dict{Symbol,Function}(:tag => v -> code_string(v), :unit => v -> code_string(v)))

# ╔═╡ 0d800013
(statistic = reconciliation[:statistic], critical = reconciliation[:critical],
	dof = reconciliation[:dof], balance_pass = reconciliation[:balance_pass],
	status = reconciliation[:status])

# ╔═╡ 0d800014
begin
	bundle = report_bundle(PipelineConfig(root = ROOT, days = 60, seed = 20260101,
		run_mpc = false, run_vision = false, run_acoustic = false,
		groups = [:diagnostics, :compliance, :quality]))
	preview_diagnostics(bundle)
end

# ╔═╡ 0d800015
preview_compliance(bundle)

# ╔═╡ 0d800016
preview_quality(bundle)

# ╔═╡ 0d800017
print_report_pdf(bundle; id = :diagnostics, group = :diagnostics, root = ROOT)

# ╔═╡ Cell order:
# ╠═0d800001
# ╠═0d800002
# ╠═0d800003
# ╠═0d800004
# ╠═0d800005
# ╠═0d800006
# ╠═0d800007
# ╠═0d800008
# ╠═0d800009
# ╠═0d80000a
# ╠═0d80000b
# ╠═0d80000c
# ╠═0d80000d
# ╠═0d80000e
# ╠═0d80000f
# ╠═0d800010
# ╠═0d800011
# ╠═0d800012
# ╠═0d800013
# ╠═0d800014
# ╠═0d800015
# ╠═0d800016
# ╠═0d800017


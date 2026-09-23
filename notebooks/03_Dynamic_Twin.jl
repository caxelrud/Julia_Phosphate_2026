### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 0d400001
begin
	import Pkg
	const ROOT = isfile(joinpath(@__DIR__, "..", "Project.toml")) ?
		normpath(joinpath(@__DIR__, "..")) : pwd()
	Pkg.develop(path = ROOT)
	using PHOSPHATE
	using Dates, Statistics, Plots
end

# ╔═╡ 0d400002
md"""
# The dynamic digital twin

Eleven states on the **hourly clock** of the plant: the two P2O5 holdups and the acid
holdup of the attack tanks, the water of the filtrate, the temperature, the strength of
the merchant acid, the moisture and the temperature of the granulator bed, the holdup
and the grind of the mills, and the fouling of the evaporator tubes.

The state vector is the one the Kalman filter estimates and the controller regulates:
one definition of the plant, used three times.
"""

# ╔═╡ 0d400003
begin
	design = default_design()
	inputs = dynamic_inputs(design)
	parameters = dynamic_parameters(design)
	(DYNAMIC_STATES, DYNAMIC_INPUTS, DYNAMIC_OUTPUTS)
end

# ╔═╡ 0d400004
md"""
## 1. The equations of the twin

Every equation is a balance of a holdup against the flows that fill it and empty it.
`dynamic_twin` returns the `System` and the symbolic vocabulary the rest of the package
addresses it with.
"""

# ╔═╡ 0d400005
begin
	twin = dynamic_twin(design)
	equations = [string(eq.lhs, " = ", eq.rhs) for eq in MTK.equations(twin.sys)]
	first(equations, 5)
end

# ╔═╡ 0d400006
md"""
## 2. The open loop: what the plant does when nothing moves

Start from the steady state of the twin and integrate for two days. A stable twin is a
flat line, which is the first thing to check before a controller is built on it.
"""

# ╔═╡ 0d400007
initial = dynamic_initial_state(design)

# ╔═╡ 0d400008
simulation = simulate_dynamic(design; tspan = (0.0, 48.0), sample = 0.5)

# ╔═╡ 0d400009
begin
	Plots.plot(simulation[:hours], simulation[:outputs][:temperature];
		label = "Attack temperature (C)", color = AREA_COLOURS[:attack], linewidth = 2,
		xlabel = "hours", ylabel = "C", legend = :right,
		title = "Open loop of the reaction train")
	Plots.plot!(simulation[:hours], simulation[:outputs][:acid_strength];
		label = "Merchant acid (% P2O5)", color = AREA_COLOURS[:evaporation], linewidth = 1.6,
		linestyle = :dash)
end

# ╔═╡ 0d40000a
simulation[:balance]

# ╔═╡ 0d40000b
md"""
## 3. The step response: how long the plant takes

A step of the acid flow, and the time every output takes to reach 63 % of its change.
This is the identification a control engineer would run on the plant; here it runs on
the twin, in a second.
"""

# ╔═╡ 0d40000c
response = step_response(design; input = :acid_flow, delta = 0.05, tspan = (0.0, 12.0))

# ╔═╡ 0d40000d
fig_step_response(response; outputs = [:temperature, :free_so4, :acid_strength_weak])

# ╔═╡ 0d40000e
table_html([Dict{Symbol,Any}(:output => o, :initial => g[:initial], :final => g[:final],
		:gain => g[:gain], :gain_pct => g[:gain_pct], :t63_h => g[:t63_h])
		for (o, g) in sort(collect(response[:gains]); by = x -> String(x[1]))];
	columns = [:output, :initial, :final, :gain, :gain_pct, :t63_h],
	headers = Dict{Symbol,String}(:output => "Output", :initial => "Before", :final => "After",
		:gain => "Gain", :gain_pct => "Gain %", :t63_h => "63 % in (h)"),
	formats = Dict{Symbol,Function}(:output => v -> code_string(v)))

# ╔═╡ 0d40000f
md"""
## 4. The linear model of the controller

Linearise the twin at its operating point with the symbolic Jacobians and discretise it
with a zero-order hold. The poles give the time constants of the plant, and the
controllability and observability measures say whether a predictive controller can be
built on it at all.
"""

# ╔═╡ 0d400010
begin
	linear = linearize_twin(design)
	(model_states = size(linear[:Ad]), inputs = length(linear[:inputs]),
		outputs = length(linear[:outputs]), Ts = linear[:Ts],
		poles_max = maximum(abs.(linear[:poles])), controllability = linear[:controllability],
		observability = linear[:observability], status = linear[:status])
end

# ╔═╡ 0d400011
begin
	time_constants = linear[:time_constants_h]
	[round(t, digits = 3) for t in first(time_constants, 8)]
end

# ╔═╡ 0d400012
md"""
## 5. The state estimation: the states nobody measures

A Kalman filter on the linearised twin, driven by the inputs and corrected by the
measurements of the historian. The output is the estimate of the eleven states --
including the fouling of the evaporator and the holdup of the mills -- and the
innovation of every measurement, which is what a soft sensor is built on.
"""

# ╔═╡ 0d400013
campaign = generate_campaign(design; days = 40, seed = 20260101)

# ╔═╡ 0d400014
estimation = filter_states(design, campaign, linear; from = 1, to = 240)

# ╔═╡ 0d400015
table_html([Dict{Symbol,Any}(:output => o, :rmse => v[:rmse], :bias => v[:bias], :n => v[:n])
		for (o, v) in sort(collect(estimation[:rmse]); by = x -> String(x[1]))];
	columns = [:output, :rmse, :bias, :n],
	headers = Dict{Symbol,String}(:output => "Measurement", :rmse => "RMSE of the innovation",
		:bias => "Bias", :n => "Intervals"),
	formats = Dict{Symbol,Function}(:output => v -> code_string(v)))

# ╔═╡ 0d400016
begin
	rows = estimation[:rows]
	Plots.plot([r[:hour] for r in rows], [r[:temperature_measured] for r in rows];
		label = "measured", color = AREA_COLOURS[:attack], linewidth = 1.4, xlabel = "hour",
		ylabel = "C", legend = :right, title = "Measurement against the estimate of the filter")
	Plots.plot!([r[:hour] for r in rows], [r[:temperature_estimate] for r in rows];
		label = "estimate", color = AREA_COLOURS[:flotation], linewidth = 1.4,
		linestyle = :dash)
end

# ╔═╡ 0d400017
md"""
## 6. The twin against the plant

The steady state of the twin against the operating averages of the campaign: the table a
commissioning uses to absorb the systematic differences as a bias, and the score that
says how much the twin can be trusted.
"""

# ╔═╡ 0d400018
begin
	kpi = site_kpis(campaign)
	alignment = align_twin(design, campaign; kpi = kpi)
	(validity_score = alignment[:validity_score], status = alignment[:status])
end

# ╔═╡ 0d400019
fig_alignment(alignment[:rows])

# ╔═╡ 0d40001a
begin
	report = report_bundle(PipelineConfig(root = ROOT, days = 60, seed = 20260101,
		run_mpc = false, run_vision = false, run_acoustic = false, groups = [:twin]))
	preview_dynamic(report)
end

# ╔═╡ 0d40001b
print_report_pdf(report; id = :dynamic_twin, group = :twin, root = ROOT)

# ╔═╡ Cell order:
# ╠═0d400001
# ╠═0d400002
# ╠═0d400003
# ╠═0d400004
# ╠═0d400005
# ╠═0d400006
# ╠═0d400007
# ╠═0d400008
# ╠═0d400009
# ╠═0d40000a
# ╠═0d40000b
# ╠═0d40000c
# ╠═0d40000d
# ╠═0d40000e
# ╠═0d40000f
# ╠═0d400010
# ╠═0d400011
# ╠═0d400012
# ╠═0d400013
# ╠═0d400014
# ╠═0d400015
# ╠═0d400016
# ╠═0d400017
# ╠═0d400018
# ╠═0d400019
# ╠═0d40001a
# ╠═0d40001b


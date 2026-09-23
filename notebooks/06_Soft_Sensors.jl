### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 0d700001
begin
	import Pkg
	const ROOT = isfile(joinpath(@__DIR__, "..", "Project.toml")) ?
		normpath(joinpath(@__DIR__, "..")) : pwd()
	Pkg.develop(path = ROOT)
	using PHOSPHATE
	using Dates, Statistics, Plots
end

# ╔═╡ 0d700002
md"""
# The inferential sensors

An instrument the plant does not have is a model: the strength of the acid from its
density and temperature, the free P2O5 of the cake from the wash ratio, the grind from
the power of the mill -- and, at the other end of the plant, the grade of the concentrate
from a photograph of the froth and the load of the mill from the sound it makes.

Every sensor here is validated on a holdout it never saw, and every one of them carries
an **applicability domain**: outside the conditions it was fitted on, it reports that it
cannot answer instead of guessing.
"""

# ╔═╡ 0d700003
begin
	design = default_design()
	campaign = generate_campaign(design; days = 90, seed = 20260101)
	(length(PROCESS_SENSOR_SPECS), length(IMAGE_FEATURE_NAMES), length(ACOUSTIC_FEATURE_NAMES))
end

# ╔═╡ 0d700004
md"""
## 1. The process sensors

Ten inferences from the instruments that report every hour: the two acid strengths, the
water-soluble loss, the grind, a virtual redundancy of the mill power, the nitrogen of
the product between two laboratory samples, the filter rate, the two-product formula as a
virtual analyser of the concentrate, the temperature of the attack tanks and the load of
the evaporators.
"""

# ╔═╡ 0d700005
process_sensors = train_process_sensors(campaign)

# ╔═╡ 0d700006
table_html(sensor_table(process_sensors, campaign);
	columns = [:sensor, :target, :unit, :r2, :rmse, :bias, :rows, :in_domain_pct, :status, :inputs],
	headers = Dict{Symbol,String}(:sensor => "Sensor", :target => "Infers", :unit => "Unit",
		:r2 => "R2", :rmse => "RMSE", :bias => "Bias", :rows => "Samples",
		:in_domain_pct => "In domain %", :status => "Status", :inputs => "Inputs"),
	formats = Dict{Symbol,Function}(:sensor => v -> code_string(v), :target => v -> code_string(v),
		:unit => v -> code_string(v), :status => v -> badge(v),
		:r2 => v -> fmt_number(v, digits = 3)))

# ╔═╡ 0d700007
begin
	best = process_sensors[argmax([s.r2 for s in process_sensors])]
	table_html([Dict{Symbol,Any}(:input => k, :elasticity_pct => v)
			for (k, v) in sort(collect(sensor_elasticity(best, campaign)); by = x -> -abs(x[2]))];
		columns = [:input, :elasticity_pct],
		headers = Dict{Symbol,String}(:input => "Input", :elasticity_pct => "Elasticity %"),
		formats = Dict{Symbol,Function}(:input => v -> code_string(v)))
end

# ╔═╡ 0d700008
begin
	series = predict_series(best, campaign)
	Plots.plot(series.stamps, series.values; label = string("sensor ", code_string(best.id)),
		color = AREA_COLOURS[:flotation], linewidth = 1.2, title = "What the sensor says",
		ylabel = string(code_string(series.unit)))
	Plots.plot!(campaign.book[best.target].stamps, campaign.book[best.target].values;
		label = "measurement", color = AREA_COLOURS[:attack], linewidth = 1.0, linestyle = :dash)
end

# ╔═╡ 0d700009
md"""
## 2. The vision sensor: what the camera sees

Flotation is controlled by looking at the froth: the size of the bubbles, the brightness
of the film and the roughness of the texture change before the analyser reports anything.
The generator renders a froth whose texture follows the state of the plant, the features
are the ones an industrial camera computes (statistics, spectral bands, texture and the
morphology of the bubbles), and the sensor is a linear model of the grade on those
features -- validated on images it never saw.
"""

# ╔═╡ 0d70000a
image = froth_image(96; seed = 3, bubble_px = 42.0, brightness = 0.7, contrast = 0.4)

# ╔═╡ 0d70000b
fig_image(image; title = "Froth of the rougher cells")

# ╔═╡ 0d70000c
image_features(image)

# ╔═╡ 0d70000d
vision = vision_report(campaign; samples = 120, size = 64)

# ╔═╡ 0d70000e
table_html(vision[:rows];
	columns = [:sensor, :target, :unit, :r2, :rmse, :bias, :rows, :status],
	headers = Dict{Symbol,String}(:sensor => "Sensor", :target => "Infers", :unit => "Unit",
		:r2 => "R2", :rmse => "RMSE", :bias => "Bias", :rows => "Images", :status => "Status"),
	formats = Dict{Symbol,Function}(:sensor => v -> code_string(v), :target => v -> code_string(v),
		:unit => v -> code_string(v), :status => v -> badge(v)))

# ╔═╡ 0d70000f
fig_parity(vision[:parity]; sensor = vision[:sensors][1].id, unit = vision[:sensors][1].unit)

# ╔═╡ 0d700010
fig_image(vision[:images][:rock][1]; title = "Rock on the belt")

# ╔═╡ 0d700011
md"""
## 3. The acoustic sensors: what the plant sounds like

A ball mill and a slurry pump tell their condition with sound. The generator renders the
two signals with the tonal components of a real machine -- the shell resonance of the
mill, the vane-pass tone of the pump -- and the broadband noise that carries the
information; the feature extractor computes the band powers, the crest factor, the
kurtosis and the cavitation index with nothing but an FFT.
"""

# ╔═╡ 0d700012
acoustic = acoustic_report(campaign; samples = 90, n = 2048)

# ╔═╡ 0d700013
fig_spectrum(acoustic[:spectra])

# ╔═╡ 0d700014
table_html(acoustic[:rows];
	columns = [:sensor, :target, :unit, :r2, :rmse, :bias, :rows, :status],
	headers = Dict{Symbol,String}(:sensor => "Sensor", :target => "Infers", :unit => "Unit",
		:r2 => "R2", :rmse => "RMSE", :bias => "Bias", :rows => "Windows", :status => "Status"),
	formats = Dict{Symbol,Function}(:sensor => v -> code_string(v), :target => v -> code_string(v),
		:unit => v -> code_string(v), :status => v -> badge(v)))

# ╔═╡ 0d700015
begin
	all_sensors = vcat(process_sensors, vision[:sensors], acoustic[:sensors])
	soft = soft_sensor_report(campaign; sensors = all_sensors)
	(soft[:summary][:sensors], round(soft[:summary][:median_r2], digits = 3),
		soft[:summary][:status])
end

# ╔═╡ 0d700016
begin
	bundle = report_bundle(PipelineConfig(root = ROOT, days = 60, seed = 20260101,
		vision_samples = 60, vision_size = 64, acoustic_samples = 40, acoustic_n = 2048,
		run_mpc = false, groups = [:sensors]))
	preview_sensors(bundle)
end

# ╔═╡ 0d700017
print_report_pdf(bundle; id = :sensors, group = :sensors, root = ROOT)

# ╔═╡ Cell order:
# ╠═0d700001
# ╠═0d700002
# ╠═0d700003
# ╠═0d700004
# ╠═0d700005
# ╠═0d700006
# ╠═0d700007
# ╠═0d700008
# ╠═0d700009
# ╠═0d70000a
# ╠═0d70000b
# ╠═0d70000c
# ╠═0d70000d
# ╠═0d70000e
# ╠═0d70000f
# ╠═0d700010
# ╠═0d700011
# ╠═0d700012
# ╠═0d700013
# ╠═0d700014
# ╠═0d700015
# ╠═0d700016
# ╠═0d700017


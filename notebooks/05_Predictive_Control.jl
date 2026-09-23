### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 0d600001
begin
	import Pkg
	const ROOT = isfile(joinpath(@__DIR__, "..", "Project.toml")) ?
		normpath(joinpath(@__DIR__, "..")) : pwd()
	Pkg.develop(path = ROOT)
	using PHOSPHATE
	using Dates, Statistics, Plots
end

# ╔═╡ 0d600002
md"""
# Predictive control of the reaction train

A linear MPC over the discrete model of the twin, with a Kalman filter estimating the
states from the measurements, and the **nonlinear ODE twin as the plant**. The
controller never sees the equations it is controlling: it sees a linear model, noisy
measurements, and the limits of the equipment.

The baseline is a PI controller tuned on the same steady-state gains of the same model,
so the comparison is like for like: same plant, same disturbances, same noise.
"""

# ╔═╡ 0d600003
begin
	design = default_design()
	config = MPCConfig(horizon = 12, control_horizon = 4)
	(config.horizon, config.control_horizon, config.sample_time)
end

# ╔═╡ 0d600004
md"""
## 1. The controller

The model comes from `linearize_twin`, the weights and the bands from `MPCConfig`. The
band is how a setpoint is written in this controller: the objective tracks the midpoint
of the output bounds, so a narrow band around the target *is* the setpoint, and its
width is the tolerance the specification accepts.
"""

# ╔═╡ 0d600005
begin
	setup = mpc_controller(design; config = config)
	(inputs = setup.inputs, outputs = setup.outputs, Ts = setup.linear[:Ts],
		poles = round.(maximum(abs.(setup.linear[:poles])), digits = 4))
end

# ╔═╡ 0d600006
setup.controller

# ╔═╡ 0d600007
md"""
## 2. The closed loop against a setpoint change

The acid strength is moved from 52.4 to 52.0 % at hour 12 and the temperature band is
raised at hour 24. The figures show the controlled variables against their band and the
moves the controller asked of the plant.
"""

# ╔═╡ 0d600008
loop = simulate_closed_loop(design; config = config, steps = 36, scenario = :setpoint,
	kind = :mpc)

# ╔═╡ 0d600009
fig_loop(loop; output = :acid_strength)

# ╔═╡ 0d60000a
fig_loop(loop; output = :temperature)

# ╔═╡ 0d60000b
fig_loop_inputs(loop; inputs = [:acid_flow, :steam_flow])

# ╔═╡ 0d60000c
begin
	baseline = simulate_closed_loop(design; config = config, steps = 36,
		scenario = :setpoint, kind = :pi)
	(MPC_error = loop[:metrics][:iae_bands], PI_error = baseline[:metrics][:iae_bands],
		MPC_violations = loop[:metrics][:violations],
		PI_violations = baseline[:metrics][:violations])
end

# ╔═╡ 0d60000d
md"""
## 3. The same comparison on an unmeasured disturbance

The grade of the ore drops by 8 % at hour 16. The controller's model knows nothing
about it, so what is tested here is the estimator: a Kalman filter that works absorbs
the disturbance without an operator touching the plant.
"""

# ╔═╡ 0d60000e
disturbed = simulate_closed_loop(design; config = config, steps = 30,
	scenario = :grade_change, kind = :mpc)

# ╔═╡ 0d60000f
fig_loop(disturbed; output = :product_rate)

# ╔═╡ 0d600010
begin
	report = mpc_report(design; config = config, steps = 24, scenario = :setpoint)
	table_html(report[:comparison];
		columns = [:output, :band, :mpc_iae, :pi_iae, :iae_improvement_pct, :mpc_hours_out,
			:pi_hours_out],
		headers = Dict{Symbol,String}(:output => "Controlled variable", :band => "Band",
			:mpc_iae => "MPC error", :pi_iae => "PI error",
			:iae_improvement_pct => "Improvement %", :mpc_hours_out => "MPC hours out",
			:pi_hours_out => "PI hours out"),
		formats = Dict{Symbol,Function}(:output => v -> code_string(v)))
end

# ╔═╡ 0d600011
fig_mpc_comparison(report[:comparison])

# ╔═╡ 0d600012
begin
	bundle = report_bundle(PipelineConfig(root = ROOT, days = 60, seed = 20260101,
		mpc_steps = 24, run_vision = false, run_acoustic = false, groups = [:control]))
	preview_control(bundle)
end

# ╔═╡ 0d600013
print_report_pdf(bundle; id = :control, group = :control, root = ROOT)

# ╔═╡ Cell order:
# ╠═0d600001
# ╠═0d600002
# ╠═0d600003
# ╠═0d600004
# ╠═0d600005
# ╠═0d600006
# ╠═0d600007
# ╠═0d600008
# ╠═0d600009
# ╠═0d60000a
# ╠═0d60000b
# ╠═0d60000c
# ╠═0d60000d
# ╠═0d60000e
# ╠═0d60000f
# ╠═0d600010
# ╠═0d600011
# ╠═0d600012
# ╠═0d600013

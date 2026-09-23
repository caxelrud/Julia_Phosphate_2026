# =============================================================================
# figures.jl -- the charts of the report and of the notebooks.
#
# Every function returns a `Plots.Plot`; `png_base64` turns it into the data URI the
# HTML printout embeds, so one definition serves the interactive notebook and the
# printed PDF. The captions are written here as well, because a figure without a
# caption is a picture, not evidence.
# =============================================================================

"""Colour of each area of the route, used consistently in every figure and table."""
const AREA_COLOURS = Dict{Symbol,String}(
    :beneficiation => "#8d6e63", :flotation => "#2b7bba", :attack => "#c8442c",
    :filtration => "#e07b39", :evaporation => "#7d5ba6", :acid_plant => "#fbc02d",
    :granulation => "#6fbf73", :utilities => "#546e7a", :tailings => "#78909c")

"""Colour of each assessment status."""
const STATUS_COLOURS = Dict{Symbol,String}(
    :compliant => "#2e7d32", :at_risk => "#ef8b1b", :noncompliant => "#c62828",
    :not_assessed => "#78909c", :healthy => "#2e7d32", :attention => "#ef8b1b",
    :action_required => "#c62828", :degraded => "#ef8b1b", :faulty => "#c62828")

"""Colour of each severity level."""
const SEVERITY_COLOURS = Dict{Symbol,String}(
    :info => "#2b7bba", :warning => "#ef8b1b", :critical => "#c62828")

"""Default figure geometry in pixels and the output resolution."""
const FIGURE_SIZE = (; width = 1000, height = 320, dpi = 110)

"""Standard look of every figure of the report."""
function figure_theme(p::Plots.Plot)
    return Plots.plot(p; size = (FIGURE_SIZE.width, FIGURE_SIZE.height), dpi = FIGURE_SIZE.dpi,
        background_color = :white, background_color_inside = :white,
        foreground_color = "#333333", grid = true, gridalpha = 0.25, gridcolor = "#cccccc",
        legendfontsize = 9, tickfontsize = 9, guidefontsize = 10, titlefontsize = 11,
        left_margin = 6Plots.mm, right_margin = 3Plots.mm, top_margin = 3Plots.mm,
        bottom_margin = 4Plots.mm)
end

"""The plot as a base64 PNG, the form the printout embeds."""
function png_base64(p::Plots.Plot)
    io = IOBuffer()
    Plots.png(p, io)
    return base64encode(take!(io))
end

"""A data URI of a figure, ready for the `src` of an `img` tag."""
data_uri(p::Plots.Plot) = string("data:image/png;base64,", png_base64(p))

"""`(; plot, caption, uri)` for a figure of the report."""
figure_entry(p::Plots.Plot, caption::AbstractString) =
    (plot = p, caption = String(caption), uri = data_uri(p))

"""Daily ore feed and product rate of the campaign."""
function fig_production(c::Campaign)
    rom = daily_series(c.book[:ROM_FEED]; reducer = total)
    prod = daily_series(c.book[:PRODUCT_FLOW]; reducer = total)
    p2o5 = daily_series(c.book[:P2O5_FEED_RATE]; reducer = total)
    p = Plots.plot(rom.stamps, rom.values;
        label = "Ore (t/day)", color = AREA_COLOURS[:beneficiation], linewidth = 1.4,
        ylabel = "t / day", title = "Ore processed and product made, day by day",
        legend = :topleft)
    p = Plots.plot(p, Plots.plot(prod.stamps, prod.values;
        label = "DAP (t/day)", color = AREA_COLOURS[:granulation], linewidth = 1.4))
    p = Plots.plot(p, Plots.plot(p2o5.stamps, p2o5.values;
        label = "P2O5 to attack (t/day)", color = AREA_COLOURS[:attack], linewidth = 1.2,
        linestyle = :dash))
    return figure_theme(p)
end

"""The P2O5 cascade: ore, concentrate, product and merchant acid."""
function fig_recovery_cascade(kpi::Dict{Symbol,Any})
    labels = ["Ore", "Concentrate", "Attack feed", "Product", "Merchant acid"]
    values = [kpi[:ore][:p2o5_ore], kpi[:ore][:p2o5_feed], kpi[:attack][:p2o5_fed],
        kpi[:product][:p2o5_product], kpi[:product][:p2o5_merchant]]
    colours = [AREA_COLOURS[:beneficiation], AREA_COLOURS[:flotation], AREA_COLOURS[:attack],
        AREA_COLOURS[:granulation], AREA_COLOURS[:evaporation]]
    p = Plots.bar(labels, values ./ 1000.0; color = colours, legend = false,
        ylabel = "kt P2O5", title = string("P2O5 cascade of the campaign (recovery ",
            round(kpi[:product][:p2o5_recovery_pct], digits = 1), " %)"), bar_width = 0.7)
    return figure_theme(p)
end

"""Where the energy of the plant goes, in gigajoules."""
function fig_energy_split(kpi::Dict{Symbol,Any})
    labels = ["Steam", "Dryer fuel", "Power"]
    values = [kpi[:energy][:steam_gj], kpi[:energy][:fuel_gj],
        kpi[:energy][:electricity_kwh] * 0.0036]
    colours = [AREA_COLOURS[:evaporation], AREA_COLOURS[:granulation], AREA_COLOURS[:utilities]]
    p = Plots.bar(labels, values ./ 1000.0; color = colours, legend = false,
        ylabel = "TJ", title = string("Energy of the campaign: ",
            round(kpi[:energy][:specific_gj_per_p2o5], digits = 2), " GJ per t P2O5"),
        bar_width = 0.6)
    return figure_theme(p)
end

"""The variable cost of the tonne of product, item by item."""
function fig_cost_split(kpi::Dict{Symbol,Any})
    items = sort(collect(kpi[:cost][:items]); by = x -> -x[2])
    labels = [to_string(k) for (k, _) in items]
    values = [v * 1000.0 / max(kpi[:product][:tonnes], 1.0) for (_, v) in items]
    p = Plots.bar(labels, values; legend = false, ylabel = string(code_string(
            kpi[:cost][:currency]), " per t"), title = string("Variable cost of the product: ",
            round(kpi[:cost][:per_t_product], digits = 1), " ", code_string(kpi[:cost][:currency]),
            "/t"), color = AREA_COLOURS[:attack], bar_width = 0.7, xrotation = 45)
    return figure_theme(p)
end

"""
    fig_trend(campaign, tag; reducer, band, title)

Trend of one instrument over the campaign, with its operating band and the hours the
detector flagged. This is the figure the control room looks at.
"""
function fig_trend(c::Campaign, tag::Symbol; band::Union{Nothing,Tuple{Float64,Float64}} = nothing,
    title::AbstractString = to_string(tag), kind::Symbol = :level)
    s = c.book[tag]
    d = daily_series(s; reducer = kind === :flow ? total : mean_value)
    p = Plots.plot(d.stamps, d.values; label = to_string(tag), color = AREA_COLOURS[:flotation],
        linewidth = 1.4, ylabel = string(code_string(s.unit)), title = title, legend = :topright)
    if band !== nothing
        p = Plots.hline!(p, [band[1], band[2]]; label = "operating band", color = "#666666",
            linestyle = :dot, linewidth = 1.2)
    end
    return figure_theme(p)
end

"""The operating envelope of the twin: one tracked variable against a parameter sweep."""
function fig_envelope(rows::Vector{Dict{Symbol,Any}}; tracked::Vector{Symbol} = [:product, :steam],
    title::AbstractString = "Operating envelope of the reaction train")
    isempty(rows) && return nothing
    x = [r[:value] for r in rows]
    p = Plots.plot(x, [r[tracked[1]] for r in rows];
        label = to_string(tracked[1]), color = AREA_COLOURS[:granulation], linewidth = 2,
        xlabel = to_string(rows[1][:parameter]), ylabel = to_string(tracked[1]),
        title = title, legend = :topleft)
    for (i, t) in enumerate(tracked[2:end])
        p = Plots.plot(p, Plots.plot(x, [r[t] for r in rows]; label = to_string(t),
            color = AREA_COLOURS[:attack], linewidth = 1.6, linestyle = :dash))
    end
    return figure_theme(p)
end

"""The step response of the twin: the answer of the plant to one input moved."""
function fig_step_response(sr::Dict{Symbol,Any}; outputs::Vector{Symbol} = [:temperature, :acid_strength])
    rows = sr[:rows]
    isempty(rows) && return nothing
    hours = [r[:hour] for r in rows]
    p = Plots.plot(hours, [r[outputs[1]] for r in rows];
        label = to_string(outputs[1]), color = AREA_COLOURS[:attack], linewidth = 2,
        xlabel = "hours after the step", title = string("Step response to ", code_string(sr[:input]),
            " (", round(sr[:delta_pct], digits = 1), " %)"), legend = :right)
    for t in outputs[2:end]
        p = Plots.plot(p, Plots.plot(hours, [r[t] for r in rows]; label = to_string(t),
            color = AREA_COLOURS[:evaporation], linewidth = 1.6, linestyle = :dash))
    end
    return figure_theme(p)
end

"""The closed loop of a controller: the controlled variable against its band."""
function fig_loop(loop::Dict{Symbol,Any}; output::Symbol = :temperature)
    rows = loop[:rows]
    isempty(rows) && return nothing
    hours = [r[:hour] for r in rows]
    value = [r[Symbol(output, :_value)] for r in rows]
    target = [r[Symbol(output, :_target)] for r in rows]
    band = [r[Symbol(output, :_band)] for r in rows]
    p = Plots.plot(hours, value; label = to_string(output), color = AREA_COLOURS[:attack],
        linewidth = 1.8, xlabel = "hour", title = string(to_string(output), " under ",
            loop[:kind] === :mpc ? "MPC" : "PI", " control (", code_string(loop[:scenario]), ")"),
        legend = :right)
    p = Plots.plot(p, Plots.plot(hours, target; label = "target", color = "#333333",
        linewidth = 1.2, linestyle = :dash))
    p = Plots.plot(p, Plots.plot(hours, target .+ band; label = "band", color = "#999999",
        linewidth = 1.0, linestyle = :dot))
    p = Plots.plot(p, Plots.plot(hours, target .- band; label = "", color = "#999999",
        linewidth = 1.0, linestyle = :dot))
    return figure_theme(p)
end

"""The manipulated variables of a closed loop, in per cent of their operating point."""
function fig_loop_inputs(loop::Dict{Symbol,Any}; inputs::Vector{Symbol} = [:acid_flow, :steam_flow])
    rows = loop[:rows]
    isempty(rows) && return nothing
    hours = [r[:hour] for r in rows]
    p = Plots.plot(hours, [r[Symbol(inputs[1], :_percent)] for r in rows];
        label = to_string(inputs[1]), color = AREA_COLOURS[:attack], linewidth = 1.6,
        xlabel = "hour", ylabel = "% of the operating point",
        title = string("Manipulated variables under ", loop[:kind] === :mpc ? "MPC" : "PI",
            " control"), legend = :right)
    for (i, name) in enumerate(inputs[2:end])
        p = Plots.plot(p, Plots.plot(hours, [r[Symbol(name, :_percent)] for r in rows];
            label = to_string(name), color = AREA_COLOURS[:utilities], linewidth = 1.4,
            linestyle = i == 1 ? :dash : :dot))
    end
    return figure_theme(p)
end

"""The MPC against the PI baseline, output by output."""
function fig_mpc_comparison(rows::Vector{Dict{Symbol,Any}})
    isempty(rows) && return nothing
    labels = [to_string(r[:output]) for r in rows]
    mpc = [r[:mpc_iae] for r in rows]
    pi = [r[:pi_iae] for r in rows]
    p = Plots.bar(labels, [mpc pi]; label = ["MPC" "PI"], color = [AREA_COLOURS[:flotation]
        AREA_COLOURS[:utilities]], ylabel = "integral of the error (bands)",
        title = "Integral of the absolute error of every controlled variable",
        legend = :topright, bar_width = 0.75)
    return figure_theme(p)
end

"""Parity plot of a soft sensor: what it predicted against what the plant measured."""
function fig_parity(rows::Vector{Dict{Symbol,Any}}; sensor::Symbol, unit::Symbol = :count)
    pts = [r for r in rows if r[:sensor] === sensor]
    isempty(pts) && return nothing
    x = [r[:measured] for r in pts]
    y = [r[:predicted] for r in pts]
    lo, hi = min(minimum(x), minimum(y)), max(maximum(x), maximum(y))
    p = Plots.scatter(x, y; label = string(sensor), color = AREA_COLOURS[:flotation],
        markersize = 2.6, markerstrokewidth = 0, xlabel = string("measured (", code_string(unit),
            ")"), ylabel = "predicted", title = string("Parity of ", to_string(sensor)),
        legend = :topleft)
    p = Plots.plot(p, Plots.plot([lo, hi], [lo, hi]; label = "identity", color = "#333333",
        linestyle = :dash, linewidth = 1.2))
    return figure_theme(p)
end

"""An image of the plant as a figure: what the visual sensor looked at."""
function fig_image(img::AbstractMatrix; title::AbstractString = "image")
    p = Plots.heatmap(img; color = :grays, legend = false, title = title,
        aspect_ratio = :equal)
    return figure_theme(p)
end

"""One-sided spectrum of a signal, as the curve an acoustic figure plots."""
function spectrum_curve(x::AbstractVector{<:Real}; fs::Real = ACOUSTIC_SAMPLE_RATE)
    v = collect(Float64, x) .- sum(x) / length(x)
    F = FFTW.rfft(v)
    f = FFTW.fftfreq(length(v), fs)[1:length(F)]
    return f, abs.(F) ./ length(v)
end

"""The spectrum of the mill and of the pump, in decibels, one curve each."""
function fig_spectrum(spectra::Dict{Symbol,Any}; modalities::Vector{Symbol} = [:mill, :pump])
    entries = [(m, spectra[m]) for m in modalities if haskey(spectra, m)]
    isempty(entries) && return nothing
    p = nothing
    for (i, (m, entry)) in enumerate(entries)
        f, a = spectrum_curve(entry[:signal])
        keep = f .> 0
        db = 20 .* log10.(max.(a[keep], 1.0e-12))
        curve = Plots.plot(f[keep], db; label = to_string(m),
            color = i == 1 ? AREA_COLOURS[:beneficiation] : AREA_COLOURS[:flotation],
            linewidth = 1.4, xlabel = "Hz", ylabel = "dB",
            title = string("Acoustic spectrum at ", ACOUSTIC_SAMPLE_RATE, " Hz: what the sensors listen to"),
            legend = :topright)
        p = p === nothing ? curve : Plots.plot(p, curve)
    end
    return figure_theme(p)
end

"""The twin against the plant: the residual of every variable of the alignment."""
function fig_alignment(rows::Vector{Dict{Symbol,Any}})
    isempty(rows) && return nothing
    labels = [to_string(r[:variable]) for r in rows]
    residuals = [r[:residual_pct] for r in rows]
    colours = [get(STATUS_COLOURS, r[:status], "#999999") for r in rows]
    p = Plots.bar(labels, residuals; color = colours, legend = false,
        ylabel = "twin against plant (%)", title = "Residual of the steady-state twin",
        xrotation = 45)
    return figure_theme(p)
end

"""Completeness of the historian, signal by signal."""
function fig_quality(rows::Vector{Dict{Symbol,Any}}; worst::Integer = 24)
    isempty(rows) && return nothing
    sel = first(rows, min(worst, length(rows)))
    labels = [to_string(r[:tag]) for r in sel]
    values = [r[:completeness_pct] for r in sel]
    p = Plots.bar(labels, values; color = AREA_COLOURS[:utilities], legend = false,
        ylabel = "usable intervals (%)", ylims = (min(minimum(values) - 1.0, 97.0), 100.5),
        title = "Data quality of the worst signals of the register", xrotation = 60)
    return figure_theme(p)
end

"""Margin of every target of the register, coloured by its status."""
function fig_targets(rows::Vector{Dict{Symbol,Any}})
    isempty(rows) && return nothing
    labels = [to_string(r[:metric]) for r in rows]
    margins = [r[:margin_pct] for r in rows]
    colours = [get(STATUS_COLOURS, r[:status], "#999999") for r in rows]
    p = Plots.bar(labels, margins; color = colours, legend = false,
        ylabel = "margin to the target (%)",
        title = "Performance register: margin of every metric", xrotation = 60)
    return figure_theme(p)
end

"""
    figure_set(campaign, kpi, fdd, compliance; twin, mpc, vision, acoustic, alignment)
        -> Dict{Symbol,Any}

Build every figure of the report in one call: `Symbol => (; plot, caption, uri)`. The
figures of the subsystems are only built when the caller passes the corresponding
bundle, so a report never claims a figure it does not have.
"""
function figure_set(c::Campaign, kpi::Dict{Symbol,Any}, fdd::Dict{Symbol,Any},
    compliance::Dict{Symbol,Any}; twin = nothing, mpc = nothing, vision = nothing,
    acoustic = nothing, soft = nothing, alignment = nothing, optimization = nothing)
    figs = Dict{Symbol,Any}()
    add(id::Symbol, p, caption::AbstractString) =
        p === nothing || (figs[id] = figure_entry(p, caption))
    add(:production, fig_production(c),
        "Ore processed and product made, day by day, over the campaign")
    add(:recovery_cascade, fig_recovery_cascade(kpi),
        "The P2O5 cascade of the campaign, from the ore to the bagged product")
    add(:energy_split, fig_energy_split(kpi),
        "Where the energy of the campaign goes and the specific energy of the product")
    add(:cost_split, fig_cost_split(kpi),
        "The variable cost of the tonne of product, item by item")
    add(:temperature, fig_trend(c, :ATTACK_TEMP;
            band = (STEADY_LIMITS[:temperature][1], STEADY_LIMITS[:temperature][2]),
            title = "Attack temperature against its operating window"),
        "Temperature of the attack tanks, with the crystallisation window of the dihydrate process")
    add(:grade, fig_trend(c, :CONC_P2O5;
            band = (29.5, 34.0), title = "Grade of the concentrate"),
        "P2O5 of the concentrate against the specification of the attack section")
    add(:acid, fig_trend(c, :STRONG_ACID_P2O5; band = (50.5, 55.0),
            title = "Strength of the merchant acid"),
        "P2O5 of the merchant acid against the 52 % specification")
    add(:free_so4, fig_trend(c, :FREE_SO4; band = (1.2, 5.0),
            title = "Free sulphate of the slurry"),
        "Free sulphuric acid of the slurry, the crystallisation window of the gypsum")
    add(:quality, fig_quality(kpi[:quality][:by_signal]),
        "Completeness of the historian, the worst signals of the instrument register")
    add(:targets, fig_targets(target_table(kpi)),
        "Margin of every performance metric of the register against its target")
    if alignment !== nothing
        add(:alignment, fig_alignment(alignment[:rows]),
            "Residual of the steady-state twin against the campaign it describes")
    end
    if twin !== nothing
        add(:envelope, fig_envelope(twin[:envelope]),
            "Operating envelope of the reaction train from the steady-state twin")
    end
    if mpc !== nothing
        add(:mpc_loop, fig_loop(mpc[:mpc]), "Closed loop of the predictive controller")
        add(:mpc_inputs, fig_loop_inputs(mpc[:mpc]),
            "Manipulated variables the predictive controller used")
        add(:pi_loop, fig_loop(mpc[:pi]), "The same loop under the PI baseline")
        add(:mpc_comparison, fig_mpc_comparison(mpc[:comparison]),
            "Integral of the absolute error of the two controllers, output by output")
    end
    if soft !== nothing
        rows = soft[:rows]
        for r in first(rows, 3)
            add(Symbol(:parity_, r[:sensor]), fig_parity(soft[:parity]; sensor = r[:sensor],
                    unit = r[:unit]),
                string("Parity of the soft sensor ", code_string(r[:sensor]),
                    " against the plant measurement"))
        end
    end
    if vision !== nothing
        imgs = vision[:images]
        if haskey(imgs, :froth) && !isempty(imgs[:froth])
            add(:froth_image, fig_image(imgs[:froth][1]; title = "Froth of the rougher cells"),
                "The froth image the visual sensor reads the grade from")
        end
        if haskey(imgs, :rock) && !isempty(imgs[:rock])
            add(:rock_image, fig_image(imgs[:rock][1]; title = "Rock on the belt"),
                "The image of the rock the visual sensor reads the grind from")
        end
        if !isempty(vision[:sensors])
            add(:vision_parity, fig_parity(vision[:parity]; sensor = first(vision[:sensors]).id,
                    unit = first(vision[:sensors]).unit),
                "Parity of the froth sensor against the analyser")
        end
    end
    if acoustic !== nothing
        add(:spectrum, fig_spectrum(acoustic[:spectra]),
            "Spectra of the mill and of the pump: the two acoustic channels of the plant")
        if !isempty(acoustic[:sensors])
            add(:acoustic_parity, fig_parity(acoustic[:parity];
                    sensor = first(acoustic[:sensors]).id, unit = first(acoustic[:sensors]).unit),
                "Parity of the acoustic sensor of the mill against the power it draws")
        end
    end
    if optimization !== nothing
        add(:blend, fig_blend(optimization[:blend]), "Ore blend the optimiser chose")
    end
    if haskey(kpi, :acid)
        a = kpi[:acid]
        add(:acid_balance, fig_acid_balance(a[:balance]),
            "Where the P2O5 of the attack goes: the acid route and the fertiliser route")
        add(:acid_quality, fig_acid_quality(a[:quality][:rows]),
            "The merchant acid against the specification of the traded grade")
        add(:acid_cost, fig_acid_cost(a[:cost][:rows]),
            "Cost of a tonne of P2O5 as merchant acid, item by item")
    end
    return figs
end

"""Where the P2O5 of the attack goes: the merchant acid, the fertiliser route, the cake."""
function fig_acid_balance(rows::Vector{Dict{Symbol,Any}})
    isempty(rows) && return nothing
    labels = [to_string(r[:destination]) for r in rows]
    values = [r[:p2o5_t] / 1000.0 for r in rows]
    p = Plots.bar(labels, values; legend = false, ylabel = "kt P2O5",
        title = string("Where the P2O5 of the attack goes: ",
            round(sum(values), digits = 1), " kt"),
        color = [AREA_COLOURS[:evaporation], AREA_COLOURS[:granulation],
            AREA_COLOURS[:filtration], AREA_COLOURS[:utilities]],
        bar_width = 0.6, xrotation = 20)
    return figure_theme(p)
end

"""The merchant acid against its specification: the margin each limit has left."""
function fig_acid_quality(rows::Vector{Dict{Symbol,Any}})
    isempty(rows) && return nothing
    labels = [string(to_string(r[:spec]), " (", code_string(r[:unit]), ")") for r in rows]
    margins = [r[:margin_pct] for r in rows]
    colours = [get(STATUS_COLOURS, r[:status], "#7f8c8d") for r in rows]
    p = Plots.bar(labels, margins; legend = false, ylabel = "margin to the specification (%)",
        title = "Merchant acid against its specification", color = colours,
        bar_width = 0.6, xrotation = 25)
    p = Plots.hline!(p, [0.0]; label = "", color = "#333333", linestyle = :dash, linewidth = 1.2)
    return figure_theme(p)
end

"""Cost of a tonne of P2O5 as merchant acid, item by item."""
function fig_acid_cost(rows::Vector{Dict{Symbol,Any}})
    isempty(rows) && return nothing
    labels = [to_string(r[:item]) for r in rows]
    values = [r[:per_t_p2o5] for r in rows]
    p = Plots.bar(labels, values; legend = false, ylabel = "USD per t P2O5",
        title = string("Cost of a tonne of P2O5 as merchant acid: ", round(sum(values), digits = 0),
            " USD/t"), color = AREA_COLOURS[:acid_plant], bar_width = 0.6, xrotation = 45)
    return figure_theme(p)
end

"""The blend the optimiser chose, body by body."""
function fig_blend(blend::Dict{Symbol,Any})
    rows = [r for r in blend[:rows] if r[:tonnes_ph] > 1.0e-6]
    isempty(rows) && return nothing
    labels = [string(code_string(r[:body])) for r in rows]
    values = [r[:tonnes_ph] for r in rows]
    p = Plots.bar(labels, values; legend = false, ylabel = "t/h in the blend",
        title = string("Blend chosen by the linear program: ",
            round(blend[:blend_grade], digits = 2), " % P2O5 at ",
            round(blend[:cost_per_t_rock], digits = 2), " per tonne"),
        color = AREA_COLOURS[:beneficiation], bar_width = 0.6)
    return figure_theme(p)
end





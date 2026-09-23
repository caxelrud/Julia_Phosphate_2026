# =============================================================================
# vision.jl -- the visual soft sensors: what a camera sees that an analyser
# measures slowly.
#
# Phosphate flotation is controlled by looking at the froth. A change of the
# reagent dose, of the grind or of the feed grade changes the texture of the froth
# before it changes the grade of the concentrate, and that texture is exactly what a
# camera on the flotation cell sees: the size of the bubbles, the brightness of the
# froth, the roughness of the film, the colour of the pulp.
#
# This file builds that camera, end to end:
#
# * `froth_image` renders a froth whose bubble size, brightness and contrast follow
#   the state of the plant, so the exercise can be reproduced without a real camera;
# * `image_features` extracts the same features an industrial froth camera computes
#   (statistics, spectral energy bands, texture statistics and the morphology of the
#   bubbles) with nothing but arrays and an FFT;
# * `train_vision_sensors` fits the inferential sensor of the concentrate grade on
#   those features and validates it on images it never saw.
# =============================================================================

"""
    froth_image(n; seed, bubble_px, brightness, contrast) -> Matrix{Float64}

Render a `n x n` froth image in `[0, 1]`: bubbles of a mean size in pixels laid on
a jittered grid, each with a bright film and a dark Plateau border, over a pulp
background whose brightness follows the grade. The image is a *model* of the froth,
not a photograph: it is the smallest generator whose texture statistics move the
way the real ones do when the bubble size and the grade move.
"""
function froth_image(n::Integer = 128; seed::Integer = 1, bubble_px::Real = 42.0,
    brightness::Real = 0.62, contrast::Real = 0.35)
    rng = MersenneTwister(seed)
    img = fill(0.22 + 0.30 * brightness, n, n)
    radius = clamp(bubble_px / 2.0, 2.0, n / 5.0)
    step = max(3, round(Int, 1.35 * radius))
    for i in (1 + step ÷ 2):step:n, j in (1 + step ÷ 2):step:n
        cx = clamp(i + radius * (rand(rng) - 0.5), 1.0, Float64(n))
        cy = clamp(j + radius * (rand(rng) - 0.5), 1.0, Float64(n))
        r = radius * (0.55 + 0.9 * rand(rng))
        bright = brightness * (0.65 + 0.7 * rand(rng))
        ri = max(2, round(Int, r))
        for di in -ri:ri, dj in -ri:ri
            x, y = round(Int, cx) + di, round(Int, cy) + dj
            (1 <= x <= n && 1 <= y <= n) || continue
            d = sqrt((x - cx)^2 + (y - cy)^2) / r
            d > 1.0 && continue
            ## a bright film in the middle of the bubble, a dark border at its edge
            film = d < 0.72 ? bright : bright * (1.0 - (d - 0.72) / 0.28) - 0.18
            img[x, y] = clamp(0.55 * img[x, y] + 0.45 * film, 0.0, 1.0)
        end
    end
    ## the pulp between the bubbles carries the grade and the noise of the camera
    for k in eachindex(img)
        img[k] = clamp(img[k] + contrast * 0.12 * randn(rng), 0.0, 1.0)
    end
    return img
end

"""
    rock_image(n; seed, p80_px, contrast) -> Matrix{Float64}

Render a `n x n` image of the rock on a belt: dark particles on a bright belt, with a
mean size in pixels that follows the P80 of the mill discharge. The second visual
modality of the plant, used by the grind soft sensor.
"""
function rock_image(n::Integer = 128; seed::Integer = 1, p80_px::Real = 14.0,
    contrast::Real = 0.5)
    rng = MersenneTwister(seed)
    img = fill(0.78, n, n)
    radius = clamp(p80_px / 2.0, 1.5, n / 6.0)
    step = max(2, round(Int, 1.2 * radius))
    for i in (1 + step ÷ 2):step:n, j in (1 + step ÷ 2):step:n
        cx = clamp(i + radius * (rand(rng) - 0.5), 1.0, Float64(n))
        cy = clamp(j + radius * (rand(rng) - 0.5), 1.0, Float64(n))
        r = radius * (0.5 + rand(rng))
        dark = 0.30 + 0.25 * rand(rng)
        ri = max(1, round(Int, r))
        for di in -ri:ri, dj in -ri:ri
            x, y = round(Int, cx) + di, round(Int, cy) + dj
            (1 <= x <= n && 1 <= y <= n) || continue
            sqrt((x - cx)^2 + (y - cy)^2) / r > 1.0 && continue
            img[x, y] = dark
        end
    end
    for k in eachindex(img)
        img[k] = clamp(img[k] + contrast * 0.08 * randn(rng), 0.0, 1.0)
    end
    return img
end

"""Radial power bands of a 2-D image spectrum, from the lowest to the highest frequency."""
const IMAGE_BANDS = (0.04, 0.10, 0.20, 0.35, 0.50)

"""
    image_features(img; bands) -> Dict{Symbol,Float64}

The features an industrial froth camera computes, in one pass over the image:

* **statistics** -- mean, standard deviation, skewness, kurtosis and the entropy of
  the grey-level histogram;
* **spectral** -- the energy of four radial bands of the 2-D spectrum and the
  dominant radial frequency, which is the reciprocal of the texture scale;
* **texture** -- the density of edges (the mean gradient magnitude) and the local
  contrast of neighbouring pixels, the cheap stand-in for a grey-level co-occurrence
  matrix;
* **morphology** -- the number of bubbles, their mean size in pixels and how round
  they are, from the connected bright regions of the image.
"""
function image_features(img::AbstractMatrix{<:Real}; bands = IMAGE_BANDS)
    n, m = Base.size(img)
    v = vec(img)
    N = length(v)
    μ = sum(v) / N
    σ = sqrt(sum(abs2, v .- μ) / N)
    z = σ == 0 ? 0.0 : sum((v .- μ) .^ 3) / (N * σ^3)
    k = σ == 0 ? 0.0 : sum((v .- μ) .^ 4) / (N * σ^4) - 3.0
    hist = zeros(16)
    for x in v
        hist[clamp(floor(Int, x * 16) + 1, 1, 16)] += 1
    end
    p = hist ./ N
    entropy = -sum(q > 0 ? q * log2(q) : 0.0 for q in p)
    ## spectral bands of the normalised 2-D spectrum
    F = FFTW.fft(img .- μ)
    P = abs2.(F) ./ (n * m)^2
    energies = zeros(length(bands) - 1)
    radial = zeros(max(n, m) ÷ 2 + 1)
    counts = zeros(max(n, m) ÷ 2 + 1)
    for i in 1:n, j in 1:m
        fr = sqrt(((i - 1) / n)^2 + ((j - 1) / m)^2)
        fr = min(fr, 0.5) * 2.0
        b = findfirst(t -> fr < t, bands)
        (b !== nothing && b > 1) && (energies[b - 1] += P[i, j])
        bin = clamp(round(Int, fr * (length(radial) - 1)) + 1, 1, length(radial))
        radial[bin] += P[i, j]
        counts[bin] += 1
    end
    profile = radial ./ max.(counts, 1)
    dominant = argmax(profile) / (length(radial) - 1)
    ## texture: the mean gradient magnitude of the image
    gx = img[2:end, :] .- img[1:(end - 1), :]
    gy = img[:, 2:end] .- img[:, 1:(end - 1)]
    edge = (sum(abs.(gx)) / length(gx) + sum(abs.(gy)) / length(gy)) / 2.0
    local_contrast = sum(abs2, gx) / length(gx) + sum(abs2, gy) / length(gy)
    ## morphology: the bright phase, labelled
    mask = img .> (μ + 0.15 * σ)
    count_b, sizes = label_components(mask)
    mean_size = isempty(sizes) ? 0.0 : sum(sizes) / length(sizes)
    return Dict{Symbol,Float64}(:img_mean => μ, :img_std => σ, :img_skew => z,
        :img_kurtosis => k, :img_entropy => entropy, :img_band_low => energies[1],
        :img_band_mid => energies[2], :img_band_high => energies[3],
        :img_band_veryhigh => energies[4], :img_dominant_f => dominant,
        :img_edge_density => edge, :img_local_contrast => local_contrast,
        :img_bubble_count => Float64(count_b), :img_bubble_px => sqrt(mean_size),
        :img_bright_fraction => count(mask) / (n * m))
end


"""Names of the image features, in the order of the feature vector of a sensor."""
const IMAGE_FEATURE_NAMES = [:img_mean, :img_std, :img_entropy, :img_band_low,
    :img_band_mid, :img_band_high, :img_edge_density, :img_local_contrast,
    :img_bubble_count, :img_bubble_px, :img_dominant_f]

"""Feature vector of an image, in the order the sensors were fitted with."""
feature_vector(s::SoftSensor, features::Dict{Symbol,Float64}) =
    [get(features, name, NaN) for name in s.inputs]

"""
    label_components(mask) -> (count, sizes)

Number and size of the connected bright regions of a binary image, with a
four-neighbour flood fill on an explicit stack (no dependency on an image library).
This is what turns a froth image into a bubble size distribution.
"""
function label_components(mask::AbstractMatrix{Bool})
    n, m = Base.size(mask)
    seen = falses(n, m)
    sizes = Int[]
    for i in 1:n, j in 1:m
        (mask[i, j] && !seen[i, j]) || continue
        stack = Tuple{Int,Int}[(i, j)]
        seen[i, j] = true
        count = 0
        while !isempty(stack)
            (a, b) = pop!(stack)
            count += 1
            for (da, db) in ((1, 0), (-1, 0), (0, 1), (0, -1))
                x, y = a + da, b + db
                (1 <= x <= n && 1 <= y <= m) || continue
                (mask[x, y] && !seen[x, y]) || continue
                seen[x, y] = true
                push!(stack, (x, y))
            end
        end
        push!(sizes, count)
    end
    return length(sizes), sizes
end

"""
    sample_vision_data(campaign; modality, samples, size, seed) -> (X, y, index, images)

Sample the campaign the way a camera samples the plant: pick `samples` operating
hours, render one image per hour whose texture follows what the plant was doing
(bubble size from the froth, brightness from the grade, contrast from the reagent
dose), extract the features and keep the grade as the response. The index of the
hours and one image per modality are returned too, so the report can show the
picture the sensor looked at.
"""
function sample_vision_data(c::Campaign; modality::Symbol = :froth, samples::Integer = 160,
    size::Integer = 96, seed::Integer = 20260101)
    rng = MersenneTwister(seed)
    hours = findall(mode_mask(c))
    picked = sort(hours[randperm(rng, length(hours))[1:min(samples, length(hours))]])
    target = modality === :froth ? :CONC_P2O5 : :CYCLONE_P80
    features = Vector{Vector{Float64}}()
    y = Float64[]
    keep = Int[]
    images = Matrix{Float64}[]
    for k in picked
        (c.book[target].qualities[k] in OK_QUALITY && isfinite(c.book[target].values[k])) ||
            continue
        img = if modality === :froth
            grade = c.book[:CONC_P2O5].values[k]
            bubble = booked_value(c, :FROTH_BUBBLE_PX, k)
            reagent = booked_value(c, :REAGENT_FLOW, k)
            froth_image(size; seed = k, bubble_px = bubble,
                brightness = clamp((grade - 24.0) / 12.0, 0.05, 1.0),
                contrast = clamp(1.0 - reagent / 600.0, 0.05, 1.0))
        else
            rock_image(size; seed = k, p80_px = booked_value(c, :CYCLONE_P80, k) / 12.0,
                contrast = 0.5)
        end
        f = image_features(img)
        push!(features, [f[name] for name in IMAGE_FEATURE_NAMES])
        push!(y, c.book[target].values[k])
        push!(keep, k)
        length(images) < 2 && push!(images, img)
    end
    X = isempty(features) ? zeros(0, length(IMAGE_FEATURE_NAMES)) :
        permutedims(reduce(hcat, features))
    return X, y, keep, images
end

"""
    vision_report(campaign; samples, size, seed) -> Dict{Symbol,Any}

The visual soft-sensing bundle: the two sensors with their validation numbers, the
feature table of the sampled images, the parity of prediction against measurement and
the sample images themselves (so the printout can show what the sensor looked at).
"""
function vision_report(c::Campaign; samples::Integer = 160, size::Integer = 96,
    seed::Integer = 20260101)
    sensors = train_vision_sensors(c; samples = samples, size = size, seed = seed)
    Xf, yf, index_f, images_f = sample_vision_data(c; modality = :froth, samples = samples,
        size = size, seed = seed)
    Xr, yr, index_r, images_r = sample_vision_data(c; modality = :rock, samples = samples,
        size = size, seed = seed)
    feature_rows = [Dict{Symbol,Any}(:feature => name, :min => minimum(Xf[:, j]),
        :max => maximum(Xf[:, j]), :mean => sum(Xf[:, j]) / Base.size(Xf, 1),
        :std => Statistics.std(Xf[:, j])) for (j, name) in enumerate(IMAGE_FEATURE_NAMES)]
    parity = Vector{Dict{Symbol,Any}}()
    for s in sensors
        X, y = s.meta[:modality] === :froth ? (Xf, yf) : (Xr, yr)
        idx = s.meta[:modality] === :froth ? index_f : index_r
        for i in 1:Base.size(X, 1)
            push!(parity, Dict{Symbol,Any}(:sensor => s.id, :hour => idx[i],
                :measured => y[i], :predicted => predict(s, X[i, :]), :unit => s.unit))
        end
    end
    return Dict{Symbol,Any}(:sensors => sensors, :rows => sensor_table(sensors, c),
        :features => feature_rows, :parity => parity,
        :images => Dict{Symbol,Any}(:froth => images_f, :rock => images_r),
        :samples => Base.size(Xf, 1), :size => size,
        :summary => Dict{Symbol,Any}(:sensors => length(sensors),
            :froth_r2 => isempty(sensors) ? NaN : sensors[1].r2,
            :rock_r2 => length(sensors) > 1 ? sensors[2].r2 : NaN,
            :samples => Base.size(Xf, 1),
            :status => all(s -> s.r2 >= 0.75, sensors) ? :compliant : :at_risk),
        :basis => "features of a rendered froth and rock image, linear sensor on the features")
end



"""
    train_vision_sensors(campaign; samples, size, seed) -> Vector{SoftSensor}

Fit the two visual soft sensors of the plant -- the grade of the concentrate from
the froth image and the grind from the image of the rock on the belt -- and validate
them on images they never saw, with the same `R2`, `RMSE` and applicability-domain
machinery as every other sensor of the package.
"""
function train_vision_sensors(c::Campaign; samples::Integer = 160, size::Integer = 96,
    seed::Integer = 20260101)
    sensors = SoftSensor[]
    for (modality, target, unit, note) in ((:froth, :CONC_P2O5, :wt_pct,
            "the froth image carries the grade of the concentrate"),
        (:rock, :CYCLONE_P80, :um, "the image of the rock on the belt carries the grind"))
        X, y, rows, _ = sample_vision_data(c; modality = modality, samples = samples,
            size = size, seed = seed)
        Base.size(X, 1) >= 20 || continue
        rng = MersenneTwister(seed + 1)
        order = randperm(rng, Base.size(X, 1))
        ntest = max(5, round(Int, 0.4 * Base.size(X, 1)))
        test = order[1:ntest]
        train = order[(ntest + 1):end]
        fit = fit_linear(X[train, :], y[train])
        pred = fit.intercept .+ X[test, :] * fit.coefs
        resid = y[test] - pred
        sst = sum(abs2, y[test] .- sum(y[test]) / length(test))
        r2 = sst == 0 ? 0.0 : 1.0 - sum(abs2, resid) / sst
        range = Dict{Symbol,Tuple{Float64,Float64}}(IMAGE_FEATURE_NAMES[j] =>
            (minimum(X[:, j]), maximum(X[:, j])) for j in eachindex(IMAGE_FEATURE_NAMES))
        push!(sensors, SoftSensor(Symbol(modality, :_, target), target, unit, :visual,
            copy(IMAGE_FEATURE_NAMES), fit.coefs, fit.intercept, r2,
            sqrt(sum(abs2, resid) / length(resid)), sum(resid) / length(resid), range,
            Base.size(X, 1), Dict{Symbol,Any}(:note => note, :modality => modality,
                :seed => seed, :source => :features, :samples => Base.size(X, 1))))
    end
    return sensors
end




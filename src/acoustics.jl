# =============================================================================
# acoustics.jl -- the acoustic soft sensors: what the plant sounds like.
#
# A ball mill and a slurry pump are the two machines of a phosphate plant that tell
# their condition with sound and vibration. The mill sounds different when its
# charge changes, and a cavitating pump adds a broadband hiss above a few kilohertz
# that no analogue transmitter reports.
#
# This file builds the microphone, the analysis chain and the sensor on top of it:
#
# * `mill_sound` and `pump_sound` render the two signals from the state of the
#   machine, with the tonal components of a real machine (the shell resonance of the
#   mill, the vane-pass tone of the pump) and the broadband noise that carries the
#   information;
# * `spectrum_features` extracts RMS, crest factor, kurtosis, band powers, the
#   spectral centroid and the cavitation index with nothing but an FFT;
# * `train_acoustic_sensors` fits the two inferential sensors on those features;
# * `write_wav` writes a real 16-bit WAV file, because a sound nobody can listen to
#   is not an engineering deliverable.
# =============================================================================

import DSP
import FFTW

"""Sample rate of the acoustic channels of the plant, in hertz."""
const ACOUSTIC_SAMPLE_RATE = 8000

"""Frequency bands of the acoustic analysis, in hertz."""
const ACOUSTIC_BANDS = (0.0, 100.0, 500.0, 2000.0, 6000.0, 8000.0)

"""Names of the acoustic features, in the order of the feature vector of a sensor."""
const ACOUSTIC_FEATURE_NAMES = [:rms, :crest, :kurtosis, :band_low, :band_mid, :band_high,
    :band_veryhigh, :centroid, :dominant_hz, :cavitation_index, :tonal_ratio]

"""
    mill_sound(n; seed, load, charge) -> Vector{Float64}

The sound of a ball mill: a broadband shell noise whose level follows the `load`
(fraction of the design power), a tonal component at the shell resonance
(≈ 320 Hz) whose sharpness grows with the `charge` of the mill, and impulsive
impacts of the balls, whose rate falls as the mill fills up. This is the signal a
microphone on the mill shell sends, at [`ACOUSTIC_SAMPLE_RATE`](@ref).
"""
function mill_sound(n::Integer = 8192; seed::Integer = 1, load::Real = 1.0,
    charge::Real = 0.5)
    rng = MersenneTwister(seed)
    ## the historian hands over whatever the instruments recorded: a stalled transmitter
    ## reports NaN, and a signal that cannot be rendered is rendered at its design point
    load = isfinite(load) ? clamp(load, 0.0, 2.0) : 1.0
    charge = isfinite(charge) ? clamp(charge, 0.0, 1.0) : 0.5
    t = (0:(n - 1)) ./ ACOUSTIC_SAMPLE_RATE
    ## broadband shell noise (the "roar" of the mill)
    noise = randn(rng, n) * (0.22 + 0.35 * load)
    ## the shell resonance, whose quality factor falls as the mill empties
    resonance = 0.30 * load * sin.(2π * 320.0 .* t) .* exp.(-0.4 * (0.35 + charge) .* t)
    ## the gear mesh tone at 42 Hz and its second harmonic
    mesh = 0.12 * load * (sin.(2π * 42.0 .* t) + 0.4 * sin.(2π * 84.0 .* t))
    ## impacts of the balls: fewer and louder when the charge is low
    impacts = zeros(n)
    rate = 45.0 * (1.0 - 0.6 * charge)
    for k in 1:round(Int, rate * n / ACOUSTIC_SAMPLE_RATE)
        i = rand(rng, 1:n)
        amp = (0.5 + 0.9 * rand(rng)) * (1.2 - 0.5 * charge)
        width = max(1, round(Int, ACOUSTIC_SAMPLE_RATE * (0.0015 + 0.001 * rand(rng))))
        for j in 0:width
            idx = i + j
            idx <= n || break
            impacts[idx] += amp * exp(-3.0 * j / width) * (rand(rng) - 0.5) * 2.0
        end
    end
    return noise .+ resonance .+ mesh .+ impacts
end

"""
    pump_sound(n; seed, cavitation) -> Vector{Float64}

The sound of a slurry pump: the vane-pass tone (six vanes at 24 rev/s, so 144 Hz with
its harmonics), the broadband flow noise, and -- when `cavitation` is above zero --
the high-frequency hiss and the crackle of the collapsing bubbles, which is the
signature the acoustic sensor is built to catch.
"""
function pump_sound(n::Integer = 8192; seed::Integer = 1, cavitation::Real = 0.0,
    speed_rpm::Real = 1450.0)
    rng = MersenneTwister(seed)
    cavitation = isfinite(cavitation) ? clamp(cavitation, 0.0, 1.0) : 0.0
    speed_rpm = isfinite(speed_rpm) ? speed_rpm : 1450.0
    t = (0:(n - 1)) ./ ACOUSTIC_SAMPLE_RATE
    f_vane = 6.0 * speed_rpm / 60.0
    tonal = 0.25 * (sin.(2π * f_vane .* t) + 0.5 * sin.(2π * 2 * f_vane .* t) +
                    0.3 * sin.(2π * 3 * f_vane .* t))
    flow = 0.18 * randn(rng, n)
    ## cavitation: a broadband hiss above 2 kHz plus a modulating crackle
    hiss = zeros(n)
    crackle = zeros(n)
    if cavitation > 0
        band = DSP.filt(DSP.digitalfilter(DSP.Bandpass(2000.0 / (ACOUSTIC_SAMPLE_RATE / 2),
                0.98), DSP.Butterworth(2)), randn(rng, n))

        hiss = 0.55 * cavitation * band
        for k in 1:round(Int, 30 * (1 + 3 * cavitation) * n / ACOUSTIC_SAMPLE_RATE)
            i = rand(rng, 1:n)
            amp = 0.6 * cavitation * (0.4 + rand(rng))
            width = max(1, round(Int, ACOUSTIC_SAMPLE_RATE * 0.0006))
            for j in 0:width
                idx = i + j
                idx <= n || break
                crackle[idx] += amp * exp(-4.0 * j / width) * (2 * rand(rng) - 1)
            end
        end
    end
    return tonal .+ flow .+ hiss .+ crackle
end

"""
    spectrum_features(x; fs, bands) -> Dict{Symbol,Float64}

The features of one acoustic channel, the same list an industrial condition monitor
computes:

* **time domain** -- RMS, crest factor (the peak over the RMS, the classic indicator
  of an impulsive defect) and kurtosis (how heavy the tails of the amplitude
  distribution are);
* **frequency domain** -- the energy of four bands, the spectral centroid (the
  "brightness" of the sound) and the dominant frequency;
* **diagnostics** -- the cavitation index (the share of the energy above 2 kHz,
  which is what a cavitating pump adds) and the tonal ratio (the share of the energy
  carried by the dominant peak over a broad band, which is what a damaged bearing
  raises).
"""
function spectrum_features(x::AbstractVector{<:Real}; fs::Real = ACOUSTIC_SAMPLE_RATE,
    bands = ACOUSTIC_BANDS)
    v = collect(Float64, x)
    v .-= sum(v) / length(v)
    rms = sqrt(sum(abs2, v) / length(v))
    peak = maximum(abs.(v))
    kurt = rms == 0 ? 0.0 : sum(v .^ 4) / (length(v) * rms^4) - 3.0
    F = FFTW.rfft(v)
    f = FFTW.fftfreq(length(v), fs)[1:length(F)]
    P = abs2.(F) ./ length(v)^2
    total = sum(P)
    energies = zeros(length(bands) - 1)
    for (i, fi) in enumerate(f)
        b = findfirst(t -> fi < t, bands)
        (b !== nothing && b > 1) && (energies[b - 1] += P[i])
    end
    centroid = total == 0 ? 0.0 : sum(f .* P) / total
    imax = argmax(P)
    dominant = f[imax]
    high = energies[3] + energies[4]
    ## the tonal ratio: the energy within 5 Hz of the peak over the total
    inband = sum(P[i] for i in eachindex(f) if abs(f[i] - dominant) <= 5.0; init = 0.0)
    return Dict{Symbol,Float64}(:rms => rms, :crest => rms == 0 ? 0.0 : peak / rms,
        :kurtosis => kurt, :band_low => energies[1], :band_mid => energies[2],
        :band_high => energies[3], :band_veryhigh => energies[4], :centroid => centroid,
        :dominant_hz => dominant, :cavitation_index => total == 0 ? 0.0 : high / total,
        :tonal_ratio => total == 0 ? 0.0 : inband / total)
end

"""Feature vector of an acoustic signal, in the order the sensors were fitted with."""
acoustic_feature_vector(s::SoftSensor, features::Dict{Symbol,Float64}) =
    [get(features, name, NaN) for name in s.inputs]

"""
    write_wav(path, x; fs) -> String

Write a mono 16-bit PCM WAV file. This is a deliverable, not a detail: the sound a
soft sensor listens to has to be playable for the engineer who has to believe the
sensor.
"""
function write_wav(path::AbstractString, x::AbstractVector{<:Real};
    fs::Real = ACOUSTIC_SAMPLE_RATE)
    v = collect(Float64, x)
    peak = maximum(abs.(v))
    scale = peak > 0 ? 32000.0 / peak : 1.0
    samples = round.(Int16, clamp.(v .* scale, -32768.0, 32767.0))
    mkpath(dirname(path))
    open(path, "w") do io
        n = length(samples)
        data_bytes = 2 * n
        write(io, "RIFF"); write(io, UInt32(36 + data_bytes)); write(io, "WAVE")
        write(io, "fmt "); write(io, UInt32(16)); write(io, UInt16(1)); write(io, UInt16(1))
        write(io, UInt32(round(Int, fs))); write(io, UInt32(round(Int, fs) * 2))
        write(io, UInt16(2)); write(io, UInt16(16))
        write(io, "data"); write(io, UInt32(data_bytes))
        for s in samples
            write(io, s)
        end
    end
    return path
end

"""
    spectrogram_rows(x; fs, window, hop) -> Vector{Dict{Symbol,Any}}

Short-time spectrum of a signal: the rows a spectrogram figure is drawn from, with
the time of every window and the energy of every frequency bin.
"""
function spectrogram_rows(x::AbstractVector{<:Real}; fs::Real = ACOUSTIC_SAMPLE_RATE,
    window::Integer = 512, hop::Integer = 256)
    rows = Vector{Dict{Symbol,Any}}()
    n = length(x)
    window = min(window, n)
    for start in 1:hop:(n - window + 1)
        seg = x[start:(start + window - 1)]
        f = spectrum_features(seg; fs = fs)
        push!(rows, Dict{Symbol,Any}(:time => (start - 1) / fs,
            :centroid => f[:centroid], :rms => f[:rms],
            :band_high => f[:band_high], :cavitation_index => f[:cavitation_index]))
    end
    return rows
end

"""
    sample_acoustic_data(campaign; modality, samples, n, seed) -> (X, y, index, signals)

Sample the two acoustic channels of the campaign: for every sampled operating hour,
render the sound the machine was making (the load of the mill, the cavitation of the
pump) and extract the features. The target of the mill channel is the power of the
mill, the target of the pump channel is the vibration of the pump: the two variables
the sound is supposed to replace.
"""
function sample_acoustic_data(c::Campaign; modality::Symbol = :mill, samples::Integer = 120,
    n::Integer = 4096, seed::Integer = 20260101)
    rng = MersenneTwister(seed)
    hours = findall(mode_mask(c))
    picked = sort(hours[randperm(rng, length(hours))[1:min(samples, length(hours))]])
    target = modality === :mill ? :MILL_POWER : :PUMP_VIBRATION
    features = Vector{Vector{Float64}}()
    y = Float64[]
    keep = Int[]
    signals = Vector{Vector{Float64}}()
    for k in picked
        (c.book[target].qualities[k] in OK_QUALITY && isfinite(c.book[target].values[k])) ||
            continue
        x = if modality === :mill
            mill_sound(n; seed = k, load = booked_value(c, :MILL_POWER, k) / 4200.0,
                charge = clamp(0.5 + (booked_value(c, :MILL_SOUND_DB, k) - 88.0) / 20.0,
                    0.05, 0.95))
        else
            pump_sound(n; seed = k,
                cavitation = clamp(booked_value(c, :PUMP_VIBRATION, k) / 6.0, 0.0, 1.0))
        end
        f = spectrum_features(x)
        push!(features, [f[name] for name in ACOUSTIC_FEATURE_NAMES])
        push!(y, c.book[target].values[k])
        push!(keep, k)
        length(signals) < 2 && push!(signals, x)
    end
    X = isempty(features) ? zeros(0, length(ACOUSTIC_FEATURE_NAMES)) :
        permutedims(reduce(hcat, features))
    return X, y, keep, signals
end

"""
    train_acoustic_sensors(campaign; samples, n, seed) -> Vector{SoftSensor}

Fit the two acoustic soft sensors: the load of the mill from the sound of its shell
and the cavitation of the pump from the hiss of its casing.
"""
function train_acoustic_sensors(c::Campaign; samples::Integer = 120, n::Integer = 4096,
    seed::Integer = 20260101)
    sensors = SoftSensor[]
    for (modality, target, unit, note) in ((:mill, :MILL_POWER, :kw,
            "the sound of the mill shell carries its load and its charge"),
        (:pump, :PUMP_VIBRATION, :count,
            "the high-frequency hiss carries the cavitation of the pump"))
        X, y, rows, _ = sample_acoustic_data(c; modality = modality, samples = samples,
            n = n, seed = seed)
        size(X, 1) >= 20 || continue
        rng = MersenneTwister(seed + 3)
        order = randperm(rng, size(X, 1))
        ntest = max(5, round(Int, 0.4 * size(X, 1)))
        test = order[1:ntest]
        train = order[(ntest + 1):end]
        fit = fit_linear(X[train, :], y[train])
        pred = fit.intercept .+ X[test, :] * fit.coefs
        resid = y[test] - pred
        sst = sum(abs2, y[test] .- sum(y[test]) / length(test))
        r2 = sst == 0 ? 0.0 : 1.0 - sum(abs2, resid) / sst
        range = Dict{Symbol,Tuple{Float64,Float64}}(ACOUSTIC_FEATURE_NAMES[j] =>
            (minimum(X[:, j]), maximum(X[:, j])) for j in eachindex(ACOUSTIC_FEATURE_NAMES))
        push!(sensors, SoftSensor(Symbol(modality, :_, target), target, unit, :acoustic,
            copy(ACOUSTIC_FEATURE_NAMES), fit.coefs, fit.intercept, r2,
            sqrt(sum(abs2, resid) / length(resid)), sum(resid) / length(resid), range,
            size(X, 1), Dict{Symbol,Any}(:note => note, :modality => modality,
                :seed => seed, :source => :features, :samples => size(X, 1),
                :sample_rate => ACOUSTIC_SAMPLE_RATE)))
    end
    return sensors
end

"""
    acoustic_report(campaign; samples, n, seed) -> Dict{Symbol,Any}

The acoustic soft-sensing bundle: the two sensors, the features of the sampled
signals, the parity of prediction against measurement, the sample signals and their
spectra (so the printout can show them and the pipeline can write them as WAV files).
"""
function acoustic_report(c::Campaign; samples::Integer = 120, n::Integer = 4096,
    seed::Integer = 20260101)
    sensors = train_acoustic_sensors(c; samples = samples, n = n, seed = seed)
    Xm, ym, index_m, signals_m = sample_acoustic_data(c; modality = :mill,
        samples = samples, n = n, seed = seed)
    Xp, yp, index_p, signals_p = sample_acoustic_data(c; modality = :pump,
        samples = samples, n = n, seed = seed)
    feature_rows = [Dict{Symbol,Any}(:feature => name, :min => minimum(Xm[:, j]),
        :max => maximum(Xm[:, j]), :mean => sum(Xm[:, j]) / size(Xm, 1),
        :std => Statistics.std(Xm[:, j])) for (j, name) in enumerate(ACOUSTIC_FEATURE_NAMES)]
    parity = Vector{Dict{Symbol,Any}}()
    for s in sensors
        X, y = s.meta[:modality] === :mill ? (Xm, ym) : (Xp, yp)
        idx = s.meta[:modality] === :mill ? index_m : index_p
        for i in 1:size(X, 1)
            push!(parity, Dict{Symbol,Any}(:sensor => s.id, :hour => idx[i],
                :measured => y[i], :predicted => predict(s, X[i, :]), :unit => s.unit))
        end
    end
    spectra = Dict{Symbol,Any}()
    for (modality, sig) in ((:mill, signals_m), (:pump, signals_p))
        isempty(sig) && continue
        spectra[modality] = Dict{Symbol,Any}(:features => spectrum_features(sig[1]),
            :rows => spectrogram_rows(sig[1]), :signal => sig[1])
    end
    return Dict{Symbol,Any}(:sensors => sensors, :rows => sensor_table(sensors, c),
        :features => feature_rows, :parity => parity, :spectra => spectra,
        :signals => Dict{Symbol,Any}(:mill => signals_m, :pump => signals_p),
        :samples => size(Xm, 1), :sample_rate => ACOUSTIC_SAMPLE_RATE,
        :summary => Dict{Symbol,Any}(:sensors => length(sensors),
            :mill_r2 => isempty(sensors) ? NaN : sensors[1].r2,
            :pump_r2 => length(sensors) > 1 ? sensors[2].r2 : NaN,
            :sample_rate => ACOUSTIC_SAMPLE_RATE, :samples => size(Xm, 1),
            :status => all(s -> s.r2 >= 0.75, sensors) ? :compliant : :at_risk),
        :basis => "spectral features of a rendered mill and pump signal, linear sensors")
end

"""Write the sample sounds of an acoustic bundle as WAV files, for the engineer's ears."""
function export_acoustic_samples(report::Dict{Symbol,Any}, dir::AbstractString)
    files = String[]
    for (modality, signals) in report[:signals]
        isempty(signals) && continue
        push!(files, write_wav(joinpath(dir, string(modality, "_sample.wav")), signals[1]))
    end
    return files
end




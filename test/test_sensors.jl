## The inferential sensors: process, vision and acoustics.
@testset "soft sensor machinery" begin
    ## the least squares fit recovers a known line
    x = reshape(collect(1.0:20.0), 20, 1)
    y = 3.0 .+ 2.0 .* vec(x)
    fit = fit_linear(x, y)
    @test fit.intercept ≈ 3.0 atol = 1.0e-8
    @test fit.coefs[1] ≈ 2.0 atol = 1.0e-8
    @test fit.r2 ≈ 1.0 atol = 1.0e-10
    ## the concentrate grade is read from the flotation feed, the grind and the reagent
    ## dose, the three variables the recovery and the mass pull of the circuit obey
    sensor = train_soft_sensor(CAMPAIGN, :CONC_P2O5,
        [:FLOT_FEED_P2O5, :CYCLONE_P80, :REAGENT_FLOW])
    @test sensor isa SoftSensor
    @test sensor.kind === :process
    @test sensor.target === :CONC_P2O5
    @test length(sensor.coefs) == 3
    @test sensor.trained_on > 20
    @test sensor.r2 > 0.5
    @test sensor.rmse > 0.0
    @test all(k -> haskey(sensor.range, k), sensor.inputs)
    @test in_domain(sensor, [mean(sensor.range[k]) for k in sensor.inputs])
    @test !in_domain(sensor, fill(-1000.0, length(sensor.inputs)))
    @test sensor_status(sensor, fill(-1000.0, length(sensor.inputs))) === :degraded
    @test isfinite(predict(sensor, [24.0, 150.0, 300.0]))
    series = predict_series(sensor, CAMPAIGN)
    @test length(series) > 100
    health = sensor_health(sensor, CAMPAIGN)
    @test health[:hours] > 100
    @test health[:status] in SENSOR_STATUSES
    @test length(sensor_elasticity(sensor, CAMPAIGN)) == 3
    @test_throws ArgumentError train_soft_sensor(CAMPAIGN, :CONC_P2O5, [:ROM_FEED],
        hours = collect(1:3))
end

@testset "process sensors" begin
    sensors = train_process_sensors(CAMPAIGN)
    @test length(sensors) == length(PROCESS_SENSOR_SPECS)
    @test all(s -> s.kind === :process, sensors)
    ## the historian is seeded with the transmitter faults the detectors have to find, so a
    ## sensor validated on it cannot reach the R2 of a laboratory fit; the requirement is
    ## that the best of them is a good sensor and that none is unusable
    @test maximum(s.r2 for s in sensors) > 0.75
    @test count(s -> s.r2 > 0.3, sensors) >= 3
    @test median(s.r2 for s in sensors) > 0.20
    @test all(s -> isfinite(s.rmse) && s.rmse >= 0.0, sensors)
    table = sensor_table(sensors, CAMPAIGN)
    @test length(table) == length(sensors)
    @test all(r -> r[:status] in SENSOR_STATUSES, table)
    estimates = sensor_estimate_table(sensors, CAMPAIGN)
    @test length(estimates) == length(sensors)
    @test all(r -> r[:status] in STATUSES, estimates)
    report = soft_sensor_report(CAMPAIGN)
    @test report[:summary][:sensors] == length(sensors)
    @test report[:summary][:status] in STATUSES
    @test length(report[:health]) == length(sensors)
    @test length(report[:elasticity]) == length(sensors)
end

@testset "visual sensors" begin
    ## the image generator and its features behave
    img = froth_image(64; seed = 1, bubble_px = 20.0)
    @test size(img) == (64, 64)
    @test minimum(img) >= 0.0
    @test maximum(img) <= 1.0
    small = froth_image(64; seed = 1, bubble_px = 8.0)
    f1 = image_features(img)
    f2 = image_features(small)
    @test Set(keys(f1)) == Set(IMAGE_FEATURE_NAMES) ∪ Set([:img_skew, :img_kurtosis,
        :img_band_veryhigh, :img_bright_fraction])
    @test f1[:img_bubble_px] > f2[:img_bubble_px]
    @test f2[:img_bubble_count] > f1[:img_bubble_count]
    @test f1[:img_entropy] > 0.0
    @test f1[:img_edge_density] > 0.0
    count, sizes = label_components(Bool[1 1 0; 0 0 0; 1 0 1])
    @test count == 3
    @test sum(sizes) == 4
    rock = rock_image(64; seed = 2)
    @test size(rock) == (64, 64)
    X, y, rows, images = sample_vision_data(CAMPAIGN; modality = :froth, samples = 30,
        size = 48)
    @test size(X, 1) == length(y) == length(rows)
    @test size(X, 2) == length(IMAGE_FEATURE_NAMES)
    @test !isempty(images)
    sensors = train_vision_sensors(CAMPAIGN; samples = 60, size = 48)
    @test length(sensors) == 2
    @test all(s -> s.kind === :visual, sensors)
    @test maximum(s.r2 for s in sensors) > 0.70
    @test feature_vector(sensors[1], image_features(img)) isa Vector{Float64}
    report = vision_report(CAMPAIGN; samples = 60, size = 48)
    @test length(report[:sensors]) == 2
    @test length(report[:parity]) > 50
    @test report[:summary][:status] in (:compliant, :at_risk)
    @test haskey(report[:images], :froth)
end

@testset "acoustic sensors" begin
    x = mill_sound(2048; seed = 1, load = 1.0, charge = 0.5)
    @test length(x) == 2048
    @test all(isfinite, x)
    loud = mill_sound(2048; seed = 1, load = 1.4, charge = 0.5)
    @test sqrt(mean(abs2, loud)) > sqrt(mean(abs2, x))
    quiet = pump_sound(2048; seed = 1, cavitation = 0.0)
    cavitating = pump_sound(2048; seed = 1, cavitation = 1.0)
    f_quiet = spectrum_features(quiet)
    f_cav = spectrum_features(cavitating)
    @test Set(keys(f_quiet)) == Set(ACOUSTIC_FEATURE_NAMES)
    @test f_cav[:cavitation_index] > f_quiet[:cavitation_index]
    @test f_cav[:rms] > f_quiet[:rms]
    @test f_quiet[:crest] > 0.0
    @test f_quiet[:dominant_hz] > 0.0
    rows = spectrogram_rows(x; window = 256, hop = 128)
    @test !isempty(rows)
    @test all(r -> haskey(r, :centroid), rows)
    path = write_wav(joinpath(mktempdir(), "mill.wav"), x)
    @test isfile(path)
    @test filesize(path) > 2048
    @test read(path, 4) == b"RIFF"
    X, y, keep, signals = sample_acoustic_data(CAMPAIGN; modality = :mill, samples = 30,
        n = 1024)
    @test size(X, 2) == length(ACOUSTIC_FEATURE_NAMES)
    @test length(y) == size(X, 1)
    sensors = train_acoustic_sensors(CAMPAIGN; samples = 60, n = 2048)
    @test length(sensors) == 2
    @test all(s -> s.kind === :acoustic, sensors)
    @test all(s -> s.r2 > 0.5, sensors)
    report = acoustic_report(CAMPAIGN; samples = 60, n = 2048)
    @test length(report[:sensors]) == 2
    @test haskey(report[:spectra], :mill)
    @test report[:summary][:sample_rate] == ACOUSTIC_SAMPLE_RATE
    files = export_acoustic_samples(report, mktempdir())
    @test !isempty(files)
    @test all(isfile, files)
    @test spectrum_curve(x) isa Tuple

end

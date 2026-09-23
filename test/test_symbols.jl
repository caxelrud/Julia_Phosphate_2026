## The vocabulary, the units, the stoichiometry and the composition arithmetic.
@testset "vocabulary" begin
    @test validate_vocabulary(io = devnull)
    @test length(unique(AREAS)) == length(AREAS)
    @test Set(keys(AREA_NAMES)) == Set(AREAS)
    @test length(STREAMS) == length(STREAM_AREA) == length(STREAM_PHASES)
    @test length(EQUIPMENT) == length(EQUIPMENT_AREA)
    @test all(s -> is_area(stream_area(s)), STREAMS)

    @test all(a -> is_area(a), values(STREAM_AREA))
    @test all(a -> is_area(a), values(EQUIPMENT_AREA))
    @test Sym("P2O5 Feed") === :p2o5_feed
    @test to_string(:acid_strength) == "Acid strength"
    @test code_string(:attack) == ":attack"
    @test symbol_equal(:water, "Water")
    @test area_name(:attack) === :Attack
    @test species_formula(:p2o5) === :P2O5
    @test species_role(:p2o5) === :value
    @test :sio2 in species_of(:gangue)
    @test is_manipulated(:acid_flow) || is_manipulated(:sulphuric_acid_flow)
    @test is_controlled(:reactor_temperature)
    @test is_sensor_kind(:acoustic)
    @test is_framework(:ifa_bat)
    @test unit_quantity(:deg_c) === :temperature
    @test_throws ArgumentError unit_quantity(:nonsense)
    @test !is_convertible(:bar, :t_ph)
    @test is_convertible(:bar, :kpa)
end

@testset "unit conversion" begin
    @test convert_value(1.0, :bar, :kpa) ≈ 100.0
    @test convert_value(1.0, :t, :kg) ≈ 1000.0
    @test convert_value(1.0, :kwh, :gj) ≈ 0.0036
    @test convert_value(28.0, :wt_pct, :pct) ≈ 28.0
    @test convert_temperature(25.0, :deg_c, :k) ≈ 298.15
    @test convert_temperature(298.15, :k, :deg_c) ≈ 25.0
    @test to_gj(1.0, :kwh) ≈ 0.0036
    @test unit_energy_kwh(:gj) ≈ 277.777777 atol = 1.0e-4
    @test_throws ArgumentError convert_value(1.0, :bar, :t)
end

@testset "stoichiometry" begin
    @test STOICH.acid ≈ 2.3032 atol = 1.0e-3
    @test STOICH.gypsum ≈ 4.0459 atol = 1.0e-2
    @test STOICH.water ≈ 0.8461 atol = 1.0e-3
    @test STOICH.hf ≈ 0.0939 atol = 1.0e-3
    @test APATITE_CAO_PER_P2O5 ≈ 1.3169 atol = 1.0e-3
    @test AMMONIA_PER_P2O5_DAP ≈ 0.480 atol = 1.0e-3
    @test AMMONIA_PER_P2O5_MAP ≈ 0.240 atol = 1.0e-3
    @test H3PO4_PER_P2O5 ≈ 1.3807 atol = 1.0e-3
    @test BPL_PER_P2O5 ≈ 2.1853 atol = 1.0e-3
    @test bpl_of_p2o5(p2o5_of_bpl(65.0)) ≈ 65.0 atol = 1.0e-6
    rock = ore_body(:khouribga)
    req = acid_requirement(1000.0, rock; excess = 0.025)
    @test req.total > req.stoich > 0
    @test req.carbonate > 0
    @test gypsum_production(1000.0, rock) > 4.0 * 1000.0 * rock[:p2o5]
    @test carbonate_co2(1000.0, rock) > 0
    @test hf_release(1000.0, rock) > 0
end

@testset "composition arithmetic" begin
    a = composition(p2o5 = 0.30, cao = 0.45, sio2 = 0.10, h2o = 0.15)
    b = composition(p2o5 = 0.34, cao = 0.50, sio2 = 0.02, h2o = 0.14)
    @test p2o5_grade(a) ≈ 30.0
    @test bpl_grade(a) ≈ 65.56 atol = 1.0e-2
    @test total(a) ≈ 1.0
    @test ratio(a, :cao, :p2o5) ≈ 1.5
    @test gangue(a) ≈ 0.10
    @test role_fraction(a, :volatile) ≈ 0.15
    m = blend([a, b], [1.0, 1.0])
    @test p2o5_grade(m) ≈ 32.0
    single = blend([a], [1.0])
    @test single isa Composition
    @test p2o5_grade(single) ≈ 30.0

    @test normalize_composition(composition(p2o5 = 1.0, cao = 1.0))[:p2o5] ≈ 0.5
    @test a[:missing_species] == 0.0
    @test_throws ArgumentError blend([a, b], [1.0])
    @test free_cao(a, 1000.0) > 0
    @test rock_for_p2o5(100.0, a).rock ≈ 333.33 atol = 1.0e-2
    @test acid_density(52.0) > 1.4
    @test acid_density(28.0) < 1.25
end

@testset "engineering correlations" begin
    @test bond_mill_power(12.8, 12000.0, 150.0, 100.0) > 0
    duty = evaporation_duty(1000.0, 0.28, 0.52)
    @test duty.water > 0
    @test duty.product ≈ 1000.0 - duty.water
    @test steam_for_evaporation(duty.water, 3.6) ≈ duty.water / 3.6
    ## the productivity is the P2O5 rate over the filter area, less the cake factor of the
    ## cycle the third argument selects (the default is a 4 % allowance)
    @test filtration_rate(320.0, 46.0) > 3.0
    @test filtration_rate(320.0, 46.0) < 46.0 * 24.0 / 320.0
    @test filtration_rate(320.0, 46.0, 1.0) ≈ 46.0 * 24.0 / 320.0 atol = 1.0e-6
    @test cooling_tower_evaporation(9800.0, 9.0) > 0
    @test cooling_tower_blowdown(cooling_tower_evaporation(9800.0, 9.0), 4.5) > 0
    @test granulator_recycle_ratio(0.18, 0.055) > 0.5
    @test_throws ArgumentError evaporation_duty(1000.0, 0.52, 0.28)
end

## The registered design, the flowsheet and the seeded campaign.
@testset "design and flowsheet" begin
    @test DESIGN.site.currency === :USD
    @test design_p2o5_tph(DESIGN) ≈ 150.0 atol = 1.0e-6
    @test design_ore_tph(DESIGN) > 500.0
    @test length(FLOWSHEET) >= 30
    @test length(unit_ids(FLOWSHEET)) == length(FLOWSHEET)
    @test Set([u.area for u in FLOWSHEET]) == Set(AREAS)
    @test is_product(FLOWSHEET, :FILTRATION, :gypsum_cake)
    @test is_stream(:gypsum_cake)
    @test producer_of(FLOWSHEET, :dry_rock) in unit_ids(FLOWSHEET)
    @test :FILTRATION in consumers_of(FLOWSHEET, :filter_feed)
    @test !isempty(downstream(FLOWSHEET, :ATTACK_TANKS))
    @test !isempty(upstream(FLOWSHEET, :FILTRATION))
    summary = flowsheet_summary(FLOWSHEET)
    @test summary[:units] == length(FLOWSHEET)
    @test summary[:streams] > 20
    @test length(flowsheet_table(FLOWSHEET)) == length(FLOWSHEET)
    @test length(stream_balance(FLOWSHEET)) > 20
    @test length(ore_bodies()) == 6
    @test length(ore_grade_table()) == 6
    @test all(b -> 20.0 < p2o5_grade(ore_body(b)) < 40.0, ore_bodies())
end

@testset "campaign model" begin
    @test length(CAMPAIGN.book) == length(signal_tags())
    n = length(CAMPAIGN.schedule[:mode])
    @test n == 24 * 120
    @test all(t -> length(CAMPAIGN.book[t]) == n, signal_tags())
    @test isempty(missing_state_keys(initial_plant_state(DESIGN, ore_body(:khouribga))))
    @test CAMPAIGN.meta[:seed] == 20260101
    @test length(CAMPAIGN.deviations) > 10
    @test all(d -> d.from_hour < d.to_hour, CAMPAIGN.deviations)
    ## the campaign is deterministic: the same seed gives the same readings
    again = generate_campaign(DESIGN; days = 5, seed = 20260101)
    also = generate_campaign(DESIGN; days = 5, seed = 20260101)
    @test again.book[:ROM_FEED].values == also.book[:ROM_FEED].values
    other = generate_campaign(DESIGN; days = 5, seed = 20260102)
    @test again.book[:ROM_FEED].values != other.book[:ROM_FEED].values
    ## the plant is massively consistent: the two-product balance of flotation closes
    m = mode_mask(CAMPAIGN)
    feed = masked_mean(CAMPAIGN, :FLOT_FEED_P2O5, m)
    conc = masked_mean(CAMPAIGN, :CONC_P2O5, m)
    tail = masked_mean(CAMPAIGN, :TAIL_P2O5, m)
    rom = masked_sum(CAMPAIGN, :ROM_FEED, m)
    rock = masked_sum(CAMPAIGN, :ROCK_FEED, m) / 0.985
    implied = (feed - tail) / (conc - tail)
    @test isapprox(rock / rom, implied; rtol = 0.02)
    ## the shutdowns are there and the plant is quiet during them
    @test count(==(0.0), CAMPAIGN.schedule[:frac]) > 0
    @test :production in keys(mode_split(CAMPAIGN))
    @test length(mode_split(CAMPAIGN)) >= 2
    @test CAMPAIGN.book[:ROM_FEED].values[1] >= 0.0
    @test all(v -> v >= 0.0, filter(isfinite, CAMPAIGN.book[:PRODUCT_FLOW].values))
    @test length(campaign_table(CAMPAIGN)) == length(signal_tags())
    @test values_of(CAMPAIGN, :ATTACK_TEMP) === CAMPAIGN.book[:ATTACK_TEMP].values
    @test signal(CAMPAIGN, :ATTACK_TEMP) isa Series
    @test isfinite(mean_of_role(CAMPAIGN, :reactor_temperature))
    @test length(campaign_summary(CAMPAIGN)) > 0
    ## the campaign exports what a historian would export
    dir = mktempdir()
    files = export_campaign(CAMPAIGN, dir)
    @test !isempty(files)
    @test all(isfile, files)
    @test length(readlines(joinpath(dir, "deviations.csv"))) == length(CAMPAIGN.deviations) + 1
end

@testset "plant steps" begin
    state = initial_plant_state(DESIGN, ore_body(:khouribga))
    ctx = PHOSPHATE.CampaignContext(DESIGN, ore_body(:khouribga), CAMPAIGN.deviations,
        MersenneTwister(1), fill(1.0, 24), fill(:production, 24))
    conc = step_ore!(state, ctx, 1)
    @test conc.rate > 0.0
    @test conc.recovery > 50.0
    @test conc.tailings < conc.grade
    reaction = step_attack!(state, ctx, 1, conc)
    @test reaction.p2o5 > 0.0
    @test reaction.gypsum > 0.0
    @test reaction.unreacted >= 0.0
    filtrate = step_filtration!(state, ctx, 1, reaction)
    @test filtrate.p2o5 > 0.0
    @test filtrate.free_loss > 0.0
    step_acid_plant!(state, ctx, 1)
    @test state[:sulphur_feed] > 0.0
    evaporation = step_evaporation!(state, ctx, 1, filtrate)
    @test evaporation.acid > 0.0
    granulation = step_granulation!(state, ctx, 1, evaporation)
    @test granulation.product > 0.0
    @test 13.0 < granulation.n < 21.0
    step_utilities!(state, ctx, 1)
    @test state[:turbine_power] > 0.0
    ## a planned outage zeroes the flows
    zero_plant!(state, ctx, 1, 1.0)
    @test state[:rom_feed] == 0.0
    @test state[:product_flow] == 0.0
    ## the deviation schedule moves a role when it is active
    d = Deviation(:x, :reactor_temperature, 10, 20, :drift, 5.0, :deg_c, "test")
    @test role_bias([d], :reactor_temperature, 15) > 0.0
    @test role_bias([d], :reactor_temperature, 5) == 0.0
    @test PHOSPHATE.activation(d, 20) ≈ 1.0
    @test PHOSPHATE.activation(d, 5) == 0.0
end

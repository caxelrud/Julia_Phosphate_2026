using Test
using PHOSPHATE
using Dates
using Statistics
using Random
using LinearAlgebra
using Plots
using ModelingToolkit

## -----------------------------------------------------------------------------
## shared fixtures: one design, one campaign, built once and reused everywhere
## -----------------------------------------------------------------------------
const DESIGN = default_design()
const FLOWSHEET = default_flowsheet(DESIGN)
const CAMPAIGN = generate_campaign(DESIGN; days = 120, seed = 20260101)
const KPI = site_kpis(CAMPAIGN)
const FDD = fault_detection_report(CAMPAIGN, KPI)
const COMPLIANCE = compliance_report(KPI, FDD)

@testset "PHOSPHATE" begin
    include("test_symbols.jl")
    include("test_series.jl")
    include("test_plant.jl")
    include("test_kpis.jl")
    include("test_acid.jl")
    include("test_diagnostics.jl")
    include("test_twin.jl")
    include("test_control.jl")
    include("test_sensors.jl")
    include("test_report.jl")
end

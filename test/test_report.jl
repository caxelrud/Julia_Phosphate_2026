## Figures, printouts, the PDF printer and the notebooks.
@testset "figures" begin
    figs = figure_set(CAMPAIGN, KPI, FDD, COMPLIANCE)
    @test !isempty(figs)
    @test haskey(figs, :production)
    @test haskey(figs, :recovery_cascade)
    @test haskey(figs, :targets)
    entry = figs[:production]
    @test is_figure(entry)
    @test startswith(entry.uri, "data:image/png;base64,")
    @test length(entry.uri) > 1000
    @test entry.plot isa Plots.Plot
    @test !isempty(entry.caption)
    @test figure_or_nothing(figs, :production) isa String
    @test figure_or_nothing(figs, :nothing_here) == ""
    @test fig_trend(CAMPAIGN, :CONC_P2O5; band = (29.5, 34.0)) isa Plots.Plot
    @test fig_quality(KPI[:quality][:by_signal]) isa Plots.Plot
    @test fig_targets(target_table(KPI)) isa Plots.Plot
    @test fig_image(froth_image(32; seed = 3)) isa Plots.Plot
end

@testset "html helpers" begin
    @test html_escape("<a & b>") == "&lt;a &amp; b&gt;"
    @test fmt_number(1234.5678) == "1,234.57"
    @test fmt_number(12.0) == "12"
    @test fmt_number(NaN) == "n/a"
    @test occursin("t_ph", fmt_unit(5.0, :t_ph))
    @test fmt_symbol(:acid_strength) == "Acid strength"
    @test occursin("badge", badge(:compliant))
    rows = [Dict{Symbol,Any}(:a => 1.0, :b => :x), Dict{Symbol,Any}(:a => 2.0, :b => :y)]
    @test occursin("<table", table_html(rows; columns = [:a, :b]))
    @test occursin("Two", table_html(rows; columns = [:a, :b],
        headers = Dict{Symbol,String}(:b => "Two")))
    @test occursin("No rows", table_html([]; columns = [:a]))
    @test occursin("cards", cards_html([(; label = "x", value = "1", unit = "t",
        status = :compliant)]))
    @test occursin("callout", callout_html(:warning, "text"))
    @test occursin("<li>", list_html(["a", "b"]))
    @test occursin("<p>", paragraph_html("text"))
    @test occursin("@media print", PRINTOUT_CSS)
    @test occursin("T", kv_table(["a" => 1.0, "b" => "two"]; title = "T"))
end

@testset "printout" begin
    bundle = Dict{Symbol,Any}(:design => DESIGN, :flowsheet => FLOWSHEET,
        :campaign => CAMPAIGN, :kpi => KPI, :fdd => FDD, :compliance => COMPLIANCE,
        :twin => nothing, :dynamic => nothing, :estimation => nothing, :alignment => nothing,
        :reconciliation => reconcile_measurements(CAMPAIGN), :optimization => nothing,
        :mpc => nothing, :soft => soft_sensor_report(CAMPAIGN), :vision => nothing,
        :acoustic => nothing, :figures => figure_set(CAMPAIGN, KPI, FDD, COMPLIANCE),
        :config => PipelineConfig(), :generated_at => string(now()), :elapsed_s => 0.0)
    meta = report_meta(bundle)
    @test meta[:title] isa String
    @test occursin("seed", meta[:provenance])
    sections = report_sections(bundle)
    @test length(sections) >= 10
    @test all(s -> s isa Section, sections)
    @test all(s -> !isempty(s.body), sections)
    @test any(s -> s.id === :executive_summary, sections)
    @test any(s -> s.id === :compliance, sections)
    @test !any(s -> s.id === :digital_twin, sections)   # this bundle has no twin
    html = report_html(bundle)
    @test startswith(html, "<!DOCTYPE html>")
    @test occursin("</html>", html)
    @test occursin("Executive summary", html)
    @test occursin("data:image/png;base64,", html)
    path = write_printout(joinpath(mktempdir(), "reports", "html", "test.html"), html)
    @test isfile(path)
    @test filesize(path) == sizeof(html)
    one = preview(bundle, :executive_summary)
    @test one isa PrintableHTML
    @test occursin("Executive summary", one.html)
    @test preview_executive(bundle).html == one.html
    @test occursin("No section", preview(bundle, :digital_twin).html)
    squeezed = section_html(bundle, :compliance)
@testset "PDF printer" begin
    @test pdf_capability()[:available] in (true, false)
    @test haskey(pdf_capability(), :browser)
    if pdf_available()
        html = "<html><body><h1>test</h1><p>one page</p></body></html>"
        dir = mktempdir()
        pdf = print_html_to_pdf(html, joinpath(dir, "test.pdf"))
        @test isfile(pdf)
        @test filesize(pdf) > 1000
        @test read(pdf, 4) == b"%PDF"
    else
        @test_throws ArgumentError html_to_pdf("missing.html", "out.pdf")
    end
end

@testset "notebook checker" begin
    dir = mktempdir()
    good = joinpath(dir, "00_Good.jl")
    write(good, "### A Pluto.jl notebook ###\n# v1.0.3\n\nusing Markdown\n\n" *
                "# \u2554\u2550\u2561 aaaa0001\n" *
                "begin\n    x = 2\n    y = x + 1\nend\n\n" *
                "# \u2554\u2550\u2561 aaaa0002\n" *
                "print_report_pdf(Dict{Symbol,Any}())\n\n" *
                "# \u2554\u2550\u2561 Cell order:\n# \u2560\u2550aaaa0001\n# \u2560\u2550aaaa0002\n")
    result = validate_notebook(good)
    @test result.ok
    @test result.cells == 2
    @test result.printout_cells == 1
    bad = joinpath(dir, "01_Bad.jl")
    write(bad, "### A Pluto.jl notebook ###\n\n" *
               "# \u2554\u2550\u2561 bbbb0001\nundefined_global + 1\n\n" *
               "# \u2554\u2550\u2561 Cell order:\n# \u2560\u2550bbbb0001\n")
    broken = validate_notebook(bad)
    @test !broken.ok
    @test any(p -> occursin("undefined", p), broken.problems)
    @test any(p -> occursin("printout", p), broken.problems)
    @test notebook_files(dir) == [good, bad]
    lines, cells = notebook_cells(good)
    @test length(cells) == 2
    @test cell_order_section(lines) == ["aaaa0001", "aaaa0002"]
    @test is_markdown_cell("md\"\"\"text\"\"\"")
    @test !is_markdown_cell("x = 1")
    @test known_notebook_names() isa Set{Symbol}
    @test :site_kpis in known_notebook_names()
    @test validate_notebooks(dir) isa Vector
end

@testset "pipeline configuration" begin
    cfg = PipelineConfig(seed = 20260101, days = 30, render_pdf = false, groups = [:all])
    @test cfg.seed == 20260101
    @test cfg.groups == [:all]
    @test path_of(cfg, :root) == cfg.root
    @test path_of(cfg, :data) == joinpath(cfg.root, "data")
    @test_throws ArgumentError path_of(cfg, :nonsense)
    from_dict = PipelineConfig(Dict(:seed => 7, :days => 3, :render_pdf => false))
    @test from_dict.seed == 7
    @test from_dict.days == 3
    @test jsonable(Dict(:a => :b, :c => [1.0, NaN]))["c"][2] === nothing
    @test jsonable(:x) == "x"
    @test jsonable(Date(2026, 1, 1)) == "2026-01-01"
    path = write_json_payload(joinpath(mktempdir(), "x.json"), Dict(:a => 1))
    @test isfile(path)
    @test occursin("\"a\"", read(path, String))
end

@testset "end to end bundle" begin
    cfg = PipelineConfig(seed = 20260101, days = 40, render_pdf = false, groups = [:all],
        vision_samples = 40, acoustic_samples = 30, acoustic_n = 1024, mpc_steps = 6,
        dynamic_hours = 12.0, export_data = false)
    bundle = report_bundle(cfg)
    @test bundle[:twin] !== nothing
    @test bundle[:dynamic] !== nothing
    @test bundle[:mpc] !== nothing
    @test bundle[:vision] !== nothing
    @test bundle[:acoustic] !== nothing
    @test bundle[:optimization] !== nothing
    @test bundle[:alignment] !== nothing
    @test !isempty(bundle[:figures])
    summary = bundle_summary(bundle)
    @test summary[:seed] == 20260101
    @test summary[:sensors][:sensors] > 10
    html = report_html(bundle)
    @test occursin("digital twin", html)
    @test occursin("Predictive control", html)
    dir = mktempdir()
    manifest = export_bundle(bundle; cfg = cfg, root = dir)
    @test manifest[:status] === :ok
    @test !isempty(manifest[:artifacts][:html])
    @test all(isfile, manifest[:artifacts][:html])
    @test isempty(manifest[:artifacts][:pdf])
    io = IOBuffer()
    report_manifest(manifest; io = io)
    @test occursin("status", String(take!(io)))
    @test isfile(joinpath(dir, "reports", "html", "phosphate.html"))
end

    @test occursin("Compliance", squeezed)
    @test !occursin("Executive summary", squeezed)
    @test length(report_sections(bundle; ids = [:compliance])) == 1
    @test length(SECTION_GROUPS) >= 15
end

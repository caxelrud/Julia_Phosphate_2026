# =============================================================================
# printout.jl -- the HTML printout of the plant.
#
# One builder produces the document the Pluto notebooks display, the file `pdf.jl`
# prints to PDF and the HTML a user can open in a browser. Every section is driven
# by symbol-keyed data, so a new section is a new entry in a list and the tables,
# the figures and the PDF can never disagree with the numbers they came from.
# =============================================================================

"""Escape text for HTML output."""
html_escape(s::AbstractString) = replace(String(s), '&' => "&amp;", '<' => "&lt;",
    '>' => "&gt;", '"' => "&quot;")

"""Pretty-print a number with thousands separators and a magnitude-aware precision."""
function fmt_number(x::Real; digits::Int = 2)
    isfinite(x) || return "n/a"
    ax = abs(x)
    d = ax >= 10_000 ? 0 : ax >= 1.0 ? digits : digits + 2
    s = string(round(x; digits = d))
    endswith(s, ".0") && (s = s[1:(end - 2)])
    parts = split(s, '.')
    int_part = reverse(replace(reverse(parts[1]), r"(\d{3})(?=\d)" => s"\1,"))
    return length(parts) > 1 ? string(int_part, '.', parts[2]) : int_part
end

"""Render a value with its unit as a `Symbol` (`1,234.50 kWh`)."""
fmt_unit(x::Real, unit::Symbol; digits::Int = 2) =
    string(fmt_number(x; digits = digits), " ", code_string(unit))

"""Render a symbol value as a human label, used by every table cell."""
fmt_symbol(s::Symbol) = to_string(s)

"""Upper-cased status badge with the status colour class."""
badge(status::Symbol) =
    string("<span class=\"badge badge-", status, "\">", html_escape(to_string(status)),
        "</span>")

"""A section of the document: id, title and finished HTML body."""
struct Section
    id::Symbol
    title::String
    body::String
end

"""Collect sections in the order they are added."""
section(id::Symbol, title::AbstractString, body::AbstractString) =
    Section(id, String(title), String(body))

"""
    PrintableHTML

An HTML fragment that a Pluto notebook displays the way a browser would, and that the
PDF printer receives as the document of a section.
"""
struct PrintableHTML
    html::String
end

Base.show(io::IO, ::MIME"text/html", p::PrintableHTML) = write(io, p.html)
Base.show(io::IO, p::PrintableHTML) = write(io, p.html)
Base.string(p::PrintableHTML) = p.html

"""
    table_html(rows; columns, headers, formats, align, title)

Build an HTML table from a vector of symbol-keyed dictionaries.

* `columns` -- which keys to show, in order
* `headers` -- `Symbol => String` overrides of the header row
* `formats` -- `Symbol => function` cell renderers (default: `fmt_number` for numbers,
  `to_string` for symbols, verbatim for strings)
* `align` -- `Symbol => :left | :right | :center` overrides of the column alignment
"""
function table_html(rows::AbstractVector; columns::Vector{Symbol},
    headers = Dict{Symbol,String}(), formats = Dict{Symbol,Function}(),
    title::Union{Nothing,AbstractString} = nothing, align = Dict{Symbol,Symbol}(),
    classes::AbstractString = "data-table")
    isempty(rows) && return string("<p class=\"empty\">No rows.</p>")
    io = IOBuffer()
    title === nothing || print(io, "<h4>", html_escape(title), "</h4>\n")
    print(io, "<table class=\"", classes, "\">\n<thead><tr>")
    for c in columns
        a = get(align, c, :left)
        print(io, "<th class=\"a-", a, "\">", html_escape(get(headers, c, String(to_string(c)))),
            "</th>")
    end
    print(io, "</tr></thead>\n<tbody>\n")
    for r in rows
        print(io, "<tr>")
        for c in columns
            v = get(r, c, nothing)
            a = get(align, c, v isa Real ? :right : :left)
            print(io, "<td class=\"a-", a, "\">", cell_html(v, get(formats, c, nothing)), "</td>")
        end
        print(io, "</tr>\n")
    end
    print(io, "</tbody></table>\n")
    return String(take!(io))
end

"""HTML of one table cell: the format function when there is one, the value otherwise."""
function cell_html(v, fmt::Union{Nothing,Function})
    fmt === nothing || return fmt(v)
    v === nothing && return ""
    v isa Symbol && return html_escape(to_string(v))
    v isa Real && return fmt_number(v)
    v isa Bool && return v ? "yes" : "no"
    v isa Union{DateTime,Date} && return string(v)
    return html_escape(string(v))
end

"""A row of KPI cards: `[(; label, value, unit, status, note)]`."""
function cards_html(cards::AbstractVector; columns::Int = 4)
    io = IOBuffer()
    print(io, "<div class=\"cards cards-", columns, "\">\n")
    for c in cards
        status = get(c, :status, nothing)
        dot = status === nothing ? "" : string("<span class=\"dot dot-", status, "\"></span>")
        note = get(c, :note, nothing)
        print(io, "<div class=\"card\"><div class=\"card-label\">", dot,
            html_escape(string(get(c, :label, ""))), "</div><div class=\"card-value\">",
            html_escape(string(get(c, :value, ""))), " <span class=\"card-unit\">",
            html_escape(string(get(c, :unit, ""))), "</span></div>",
            note === nothing ? "" :
            string("<div class=\"card-note\">", html_escape(string(note)), "</div>"), "</div>\n")
    end
    print(io, "</div>\n")
    return String(take!(io))
end

"""A figure block with its caption; `fig` is a `(; uri, caption)` named tuple."""
figure_html(fig::NamedTuple; width::AbstractString = "100%") =
    string("<figure class=\"fig\"><img src=\"", fig.uri, "\" style=\"width:", width,
        "\" alt=\"", html_escape(fig.caption), "\"/><figcaption>", html_escape(fig.caption),
        "</figcaption></figure>\n")

"""`true` when a value is a figure entry of [`figure_set`](@ref) and may be rendered."""
is_figure(f) = f isa NamedTuple && haskey(f, :uri) && haskey(f, :caption)

"""Render a figure when the bundle has one under the key, and nothing otherwise."""
function figure_or_nothing(figures, id::Symbol)
    haskey(figures, id) || return ""
    fig = figures[id]
    return is_figure(fig) ? figure_html(fig) : ""
end

"""A callout box; `kind` is a severity-like symbol (`:info`, `:warning`, `:critical`)."""
callout_html(kind::Symbol, body::AbstractString, title::Union{Nothing,AbstractString} = nothing) =
    string("<div class=\"callout callout-", kind, "\">",
        title === nothing ? "" : string("<strong>", html_escape(title), "</strong> "), body,
        "</div>\n")

"""Bullet list from an iterable of strings (already-HTML is allowed)."""
function list_html(items::AbstractVector)
    isempty(items) && return ""
    io = IOBuffer()
    print(io, "<ul>")
    for i in items
        print(io, "<li>", i, "</li>")
    end
    print(io, "</ul>")
    return String(take!(io))
end

"""Paragraph."""
paragraph_html(text::AbstractString) = string("<p>", text, "</p>\n")

"""
    PRINTOUT_CSS

Stylesheet of the printout. The `@media print` block is what drives the PDF the
headless browser produces: A4 portrait, 14 mm margins, one section per page where it
makes sense and a body text small enough that the wide tables of an instrument
register still fit.
"""
const PRINTOUT_CSS = """
:root { --ore:#8d6e63; --flot:#2b7bba; --atk:#c8442c; --fil:#e07b39; --eva:#7d5ba6;
        --gra:#6fbf73; --uti:#546e7a; --ok:#2e7d32; --risk:#ef8b1b; --bad:#c62828;
        --ink:#1f2933; --mut:#5b6b7b; }
* { box-sizing: border-box; }
body { font-family: "Segoe UI", "Helvetica Neue", Arial, sans-serif; color: var(--ink);
       margin: 0; padding: 0 26px 40px; font-size: 13px; line-height: 1.45; }
h1 { font-size: 26px; margin: 0 0 4px; }
h2 { font-size: 19px; margin: 26px 0 10px; padding-bottom: 6px; border-bottom: 2px solid var(--atk); }
h3 { font-size: 15px; margin: 18px 0 8px; }
h4 { font-size: 12px; margin: 14px 0 6px; color: var(--mut); text-transform: uppercase;
     letter-spacing: .04em; }
p { margin: 6px 0; }
code { background: #f4f6f8; padding: 0 3px; border-radius: 3px; font-size: 12px; }
.cover { border: 1px solid #d8dee4; border-left: 6px solid var(--atk); border-radius: 4px;
         padding: 16px 18px; margin: 10px 0 18px; background: #fbfcfd; }
.cover .subtitle { color: var(--mut); margin-bottom: 12px; }
.meta { display: grid; grid-template-columns: 180px 1fr; gap: 3px 10px; font-size: 12px; }
.meta dt { color: var(--mut); }
.meta dd { margin: 0; }
.cards { display: grid; gap: 9px; margin: 12px 0 16px; }
.cards-4 { grid-template-columns: repeat(4, 1fr); }
.cards-6 { grid-template-columns: repeat(6, 1fr); }
.card { border: 1px solid #dde3e8; border-radius: 4px; padding: 8px 10px; background: #fff; }
.card-label { font-size: 11px; color: var(--mut); text-transform: uppercase; }
.card-value { font-size: 19px; font-weight: 600; margin-top: 2px; }
.card-unit { font-size: 11px; color: var(--mut); font-weight: 400; }
.card-note { font-size: 11px; color: #455a64; margin-top: 4px; }
.dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 5px; }
.dot-compliant, .dot-healthy { background: var(--ok); }
.dot-at_risk, .dot-attention { background: var(--risk); }
.dot-noncompliant, .dot-action_required { background: var(--bad); }
.dot-not_assessed { background: #90a4ae; }
table.data-table { border-collapse: collapse; width: 100%; margin: 8px 0 14px; font-size: 11.5px; }
table.data-table th { background: #f0f3f6; border-bottom: 2px solid #c8d2da; padding: 5px 6px;
     text-align: left; font-weight: 600; }
table.data-table td { border-bottom: 1px solid #e6eaee; padding: 4px 6px; vertical-align: top; }
table.data-table tr:nth-child(even) td { background: #fafbfc; }
.a-right { text-align: right; }
.a-center { text-align: center; }
.badge { display: inline-block; padding: 1px 7px; border-radius: 9px; font-size: 10.5px;
         color: #fff; background: #78909c; }
.badge-compliant, .badge-healthy { background: var(--ok); }
.badge-at_risk, .badge-attention, .badge-degraded { background: var(--risk); }
.badge-noncompliant, .badge-action_required, .badge-faulty { background: var(--bad); }
.badge-not_assessed, .badge-offline { background: #90a4ae; }
.callout { border-left: 5px solid var(--flot); background: #f5f9fd; padding: 9px 12px;
           border-radius: 3px; margin: 12px 0; }
.callout-warning { border-left-color: var(--risk); background: #fdf7ee; }
.callout-critical { border-left-color: var(--bad); background: #fdf2f1; }
.fig { margin: 12px 0 16px; }
.fig img { border: 1px solid #e2e8ec; border-radius: 4px; }
figcaption { font-size: 11.5px; color: var(--mut); margin-top: 5px; }
.empty { color: var(--mut); font-style: italic; }
.footer { margin-top: 26px; padding-top: 10px; border-top: 1px solid #dde3e8; font-size: 11px;
          color: var(--mut); }
@media print {
  @page { size: A4 portrait; margin: 14mm 12mm; }
  body { font-size: 8.6px; padding: 0; }
  h1 { font-size: 18px; } h2 { font-size: 14px; page-break-after: avoid; }
  h3 { font-size: 11.5px; } h4 { font-size: 9.5px; }
  table.data-table { font-size: 7.8px; }
  table.data-table th, table.data-table td { padding: 2px 3px; }
  table.data-table thead { display: table-header-group; }
  table.data-table tr { page-break-inside: avoid; }
  .section { page-break-before: always; }
  .section:first-of-type { page-break-before: avoid; }
  .cover { page-break-after: always; }
  .card-value { font-size: 13px; }
  .fig { page-break-inside: avoid; }
}
"""

"""
    document_html(meta, sections; css, footer) -> String

Assemble the complete HTML document: the stylesheet, the cover block built from
`meta` and one `<section>` per entry of `sections`.
"""
function document_html(meta::Dict{Symbol,Any}, sections::Vector{Section};
    css::AbstractString = PRINTOUT_CSS, footer::AbstractString = "")
    io = IOBuffer()
    print(io, "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"/>",
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>",
        "<title>", html_escape(get(meta, :title, "Phosphate plant report")), "</title>",
        "<style>", css, "</style></head>\n<body>\n")
    print(io, "<div class=\"cover\"><h1>", html_escape(meta[:title]), "</h1>",
        "<div class=\"subtitle\">", html_escape(get(meta, :subtitle, "")), "</div>",
        "<dl class=\"meta\">")
    for key in (:site, :reporting_period, :product, :framework_scope, :provenance)
        haskey(meta, key) || continue
        print(io, "<dt>", html_escape(to_string(key)), "</dt><dd>",
            html_escape(string(meta[key])), "</dd>")
    end
    print(io, "</dl></div>\n")
    for s in sections
        print(io, "<section class=\"section\" id=\"", s.id, "\"><h2>", html_escape(s.title),
            "</h2>\n", s.body, "</section>\n")
    end
    print(io, "<div class=\"footer\">", isempty(footer) ?
        "Generated by PHOSPHATE from the baseline and the seed recorded on the cover page." :
        footer, "</div>\n</body></html>\n")
    return String(take!(io))
end

"""Write an HTML printout to disk, creating the directory when needed."""
function write_printout(path::AbstractString, html::AbstractString)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, html)
    end
    return path
end

"""
    report_meta(bundle; title, subtitle, frameworks) -> Dict{Symbol,Any}

Cover metadata of a report, including the provenance record that makes every number
reproducible: the site, the period, the product, the clause register and the seed.
"""
function report_meta(b::Dict{Symbol,Any}; title::AbstractString = "",
    subtitle::AbstractString = "The ore, the acid, the product, the twin, the controller " *
                               "and the evidence",
    frameworks::Vector{Symbol} = get(get(b, :compliance, Dict{Symbol,Any}()), :frameworks,
        collect(FRAMEWORKS)))
    c = b[:campaign]
    kpi = b[:kpi]
    d = b[:design]
    return Dict{Symbol,Any}(:title => isempty(title) ? string(d.site.name,
            " -- phosphate complex report") : title,
        :subtitle => subtitle,
        :site => string(d.site.name, " (", code_string(d.site.id), ")"),
        :reporting_period => string(kpi[:period][:from], " to ", kpi[:period][:to], "  (",
            kpi[:period][:days], " days, ", kpi[:period][:operating_hours], " operating hours)"),
        :product => string(to_string(d.product), " from ",
            round(100 * d.rock_p2o5, digits = 1), " % P2O5 ore, ",
            round(kpi[:product][:tonnes] / 1000, digits = 0), " kt of product"),
        :framework_scope => join([string(framework_title(f)) for f in frameworks], "; "),
        :provenance => string("Design revision ", get(d.meta, :revision, :A), " | seed ",
            c.meta[:seed], " | ", c.meta[:intervals], " hourly intervals of ",
            length(c.book), " signals | generated ", c.meta[:generated_at],
            " | basis ", code_string(c.meta[:basis])))
end

"""The headline paragraph of the report: what the campaign did, in words."""
function report_headline(kpi::Dict{Symbol,Any}, fdd::Dict{Symbol,Any},
    compliance::Dict{Symbol,Any})
    return string("The complex processed <strong>",
        fmt_number(kpi[:ore][:rom_t] / 1000.0, digits = 1), " kt</strong> of ore at ",
        fmt_number(kpi[:ore][:feed_grade], digits = 1), " % P2O5 and delivered <strong>",
        fmt_number(kpi[:product][:tonnes] / 1000.0, digits = 1), " kt</strong> of ",
        to_string(kpi[:product][:product]), " at ", fmt_number(kpi[:granulation][:n], digits = 1),
        " % N, recovering <strong>",
        fmt_number(kpi[:product][:p2o5_recovery_pct], digits = 1),
        " %</strong> of the P2O5 of the ore. The acid train digested ",
        fmt_number(kpi[:attack][:p2o5_fed] / 1000.0, digits = 1), " kt of P2O5 with ",
        fmt_number(kpi[:attack][:acid_per_p2o5]), " t of sulphuric acid per tonne, the ",
        "filters lost ", fmt_number(kpi[:filtration][:water_soluble_pct]), " % of it in the ",
        "gypsum and the evaporators spent ", fmt_number(kpi[:evaporation][:steam_per_p2o5]),
        " t of steam per tonne. The tonne of product cost <strong>",
        fmt_number(kpi[:cost][:per_t_product]), " ", code_string(kpi[:cost][:currency]),
        "</strong> in variable cost and carried ", fmt_number(kpi[:carbon][:intensity_kg_per_p2o5]),
        " kgCO2e per tonne of P2O5. The detector raised ", fdd[:summary][:count],
        " findings worth ", fmt_number(fdd[:summary][:cost_at_stake], digits = 0), " ",
        code_string(kpi[:cost][:currency]), " a year, and the plant is ",
        badge(compliance[:scorecard][:overall_status]), " against ",
        compliance[:scorecard][:clause_count], " clauses of ",
        length(compliance[:frameworks]), " frameworks.")
end

"""
    kv_table(pairs; title, columns) -> String

Small two-column table from an ordered list of `label => value` pairs, which is what
most of the report's blocks are: a list of named quantities with their units.
"""
function kv_table(pairs::Vector{<:Pair}; title::Union{Nothing,AbstractString} = nothing,
    keys_header::AbstractString = "Quantity", values_header::AbstractString = "Value")
    rows = [Dict{Symbol,Any}(:label => to_string(first(p)), :value => last(p))
            for p in pairs]
    return table_html(rows; columns = [:label, :value], title = title,
        headers = Dict{Symbol,String}(:label => keys_header, :value => values_header))
end

"""The executive summary: the cards of the plant, the cascade and the headline."""
function executive_section(b::Dict{Symbol,Any})
    kpi, fdd, comp = b[:kpi], b[:fdd], b[:compliance]
    figs = b[:figures]
    body = cards_html(area_cards(kpi); columns = 5)
    body *= figure_or_nothing(figs, :recovery_cascade)
    body *= callout_html(fdd[:summary][:status] === :healthy ? :info : :warning,
        report_headline(kpi, fdd, comp), "Headline")
    body *= figure_or_nothing(figs, :production)
    return section(:executive_summary, "Executive summary", body)
end

"""Flowsheet, design and instrument register of the plant."""
function plant_layout_section(b::Dict{Symbol,Any})
    d = b[:design]
    f = b[:flowsheet]
    summary = flowsheet_summary(f)
    body = kv_table([
        "Site" => string(d.site.name, " (", d.site.country, ")"),
        "Product" => to_string(d.product),
        "Design capacity" => string(fmt_number(d.site.capacity_t_p2o5_year / 1000.0, digits = 0),
            " kt P2O5 per year over ", fmt_number(d.site.design_hours_year, digits = 0), " h"),
        "Design rate" => string(fmt_number(design_p2o5_tph(d)), " t P2O5/h, ",
            fmt_number(design_ore_tph(d)), " t/h of ore"),
        "Registered units" => string(summary[:units], " unit operations in ",
            summary[:areas], " areas, ", summary[:streams], " streams"),
        "Instrument register" => string(length(signal_tags()), " tags, ",
            length(signals_in(:attack)), " of them around the attack tanks"),
        "Ore bodies" => join(string.(ore_bodies()), ", "),
        "Revision" => string(get(d.meta, :revision, :A), " -- ", get(d.meta, :note, "")),
    ]; title = "Registered design")
    body *= table_html(flowsheet_table(f);
        columns = [:unit, :area, :equipment, :kind, :feeds, :products, :capacity],
        headers = Dict{Symbol,String}(:unit => "Unit", :area => "Area", :equipment => "Equipment",
            :kind => "Kind", :feeds => "Feeds", :products => "Products", :capacity => "Capacity"),
        formats = Dict{Symbol,Function}(:unit => v -> code_string(v), :area => v -> code_string(v),
            :equipment => v -> code_string(v), :kind => v -> code_string(v)))
    return section(:flowsheet, "The plant: flowsheet, design and instrumentation", body)
end

"""Ore preparation, flotation and the metallurgical balance of the campaign."""
function ore_section(b::Dict{Symbol,Any})
    kpi, figs = b[:kpi], b[:figures]
    body = table_html(ore_grade_table();
        columns = [:body, :p2o5, :bpl, :cao, :sio2, :fe2o3, :al2o3, :mgo, :f, :co2, :h2o,
            :cao_p2o5, :gangue],
        headers = Dict{Symbol,String}(:body => "Ore body", :p2o5 => "P2O5 %", :bpl => "BPL %",
            :cao => "CaO %", :sio2 => "SiO2 %", :fe2o3 => "Fe2O3 %", :al2o3 => "Al2O3 %",
            :mgo => "MgO %", :f => "F %", :co2 => "CO2 %", :h2o => "H2O %",
            :cao_p2o5 => "CaO:P2O5", :gangue => "Gangue %"),
        formats = Dict{Symbol,Function}(:body => v -> code_string(v)),
        title = "Assays of the blended ore bodies")
    body *= kv_table([
        "Ore processed" => string(fmt_number(kpi[:ore][:rom_t] / 1000.0, digits = 1), " kt"),
        "Flotation feed grade" => string(fmt_number(kpi[:ore][:feed_grade], digits = 2), " % P2O5"),
        "Concentrate" => string(fmt_number(kpi[:ore][:concentrate_t] / 1000.0, digits = 1),
            " kt at ", fmt_number(kpi[:ore][:concentrate_grade], digits = 2), " % P2O5"),
        "Flotation recovery" => string(fmt_number(kpi[:beneficiation][:recovery_pct], digits = 2),
            " %"),
        "Tailings grade" => string(fmt_number(kpi[:ore][:tailings_grade], digits = 2), " % P2O5"),
        "Grind P80" => string(fmt_number(kpi[:beneficiation][:grind_p80], digits = 1), " um"),
        "Specific grinding energy" => string(fmt_number(kpi[:beneficiation][:mill_kwh_per_t],
            digits = 2), " kWh per t of ore"),
        "Reagent" => string(fmt_number(kpi[:beneficiation][:reagent_kg_per_t], digits = 3),
            " kg per t of ore"),
        "Two-product balance residual" => string(fmt_number(
            kpi[:beneficiation][:mass_balance_residual_pct], digits = 3), " %"),
    ]; title = "Metallurgical balance of the campaign")
    body *= figure_or_nothing(figs, :grade)
    body *= figure_or_nothing(figs, :temperature)
    return section(:ore_and_flotation, "Ore preparation, flotation and the metallurgical balance",
        body)
end

"""The reaction train: attack, filtration and evaporation of the campaign."""
function reaction_section(b::Dict{Symbol,Any})
    kpi, figs = b[:kpi], b[:figures]
    body = kv_table([
        "P2O5 to the attack tanks" => string(fmt_number(kpi[:attack][:p2o5_fed] / 1000.0,
            digits = 1), " kt"),
        "Dry rock fed" => string(fmt_number(kpi[:attack][:rock_t] / 1000.0, digits = 1), " kt"),
        "Sulphuric acid" => string(fmt_number(kpi[:attack][:acid_t] / 1000.0, digits = 1), " kt (",
            fmt_number(kpi[:attack][:acid_per_p2o5]), " t per t P2O5)"),
        "Sulphur burnt" => string(fmt_number(kpi[:attack][:sulphur_t] / 1000.0, digits = 1), " kt (",
            fmt_number(kpi[:attack][:sulphur_per_p2o5]), " t per t P2O5)"),
        "Attack temperature" => string(fmt_number(kpi[:attack][:temperature], digits = 1), " C"),
        "Free sulphate" => string(fmt_number(kpi[:attack][:free_so4], digits = 2), " wt% of slurry"),
        "Gypsum produced" => string(fmt_number(kpi[:attack][:gypsum_t] / 1000.0, digits = 1),
            " kt (", fmt_number(kpi[:attack][:gypsum_per_p2o5], digits = 2), " t per t P2O5)"),
        "Filter productivity" => string(fmt_number(kpi[:filtration][:rate], digits = 2),
            " t P2O5 per m2 per day over ", fmt_number(kpi[:filtration][:filter_area_m2],
                digits = 0), " m2"),
        "Water-soluble loss" => string(fmt_number(kpi[:filtration][:water_soluble_t] / 1000.0,
            digits = 2), " kt of P2O5 (", fmt_number(kpi[:filtration][:water_soluble_pct], digits = 2),
            " % of the feed) at ", fmt_number(kpi[:filtration][:free_p2o5], digits = 3),
            " % free P2O5 in the cake"),
        "Filtrate strength" => string(fmt_number(kpi[:filtration][:weak_strength], digits = 2),
            " % P2O5"),
        "Evaporator steam" => string(fmt_number(kpi[:evaporation][:steam_t] / 1000.0, digits = 1),
            " kt (", fmt_number(kpi[:evaporation][:steam_per_p2o5]), " t per t P2O5, economy ",
            fmt_number(kpi[:evaporation][:economy], digits = 2), ")"),
        "Merchant acid" => string(fmt_number(kpi[:evaporation][:merchant_t] / 1000.0, digits = 1),
            " kt at ", fmt_number(kpi[:evaporation][:strength], digits = 2), " % P2O5"),
    ]; title = "Reaction, filtration and evaporation")
    body *= figure_or_nothing(figs, :acid)
    body *= figure_or_nothing(figs, :free_so4)
    body *= callout_html(:info, string("The acidulation demand of the blend is ",
        fmt_number(kpi[:attack][:acid_per_p2o5]), " t of H2SO4 per t of P2O5 against a ",
        "stoichiometric ", fmt_number(STOICH.acid), " plus the registered excess of ",
        fmt_number(100 * b[:design].acid_excess, digits = 1), " %; the gap is the free ",
        "carbonate of the ore, which is why the assay of the blend is an operating variable ",
        "and not a laboratory curiosity."))
    return section(:reaction_train, "The reaction train: attack, filtration and evaporation", body)
end

"""Granulation, product quality, energy, cost and carbon of the campaign."""
function product_section(b::Dict{Symbol,Any})
    kpi, figs = b[:kpi], b[:figures]
    body = kv_table([
        "Product" => string(fmt_number(kpi[:product][:tonnes] / 1000.0, digits = 1), " kt of ",
            to_string(kpi[:product][:product]), " at ", fmt_number(kpi[:product][:grade_p2o5],
                digits = 2), " % P2O5"),
        "Nitrogen" => string(fmt_number(kpi[:product][:n_pct], digits = 2),
            " % (specification 17.4 to 19.2)"),
        "Moisture and solubility" => string(fmt_number(kpi[:product][:moisture_pct], digits = 2),
            " % H2O and ", fmt_number(kpi[:product][:wsp_pct], digits = 1), " % water-soluble P2O5"),
        "Ammonia" => string(fmt_number(kpi[:granulation][:ammonia_t] / 1000.0, digits = 1),
            " kt (", fmt_number(kpi[:granulation][:ammonia_per_p2o5]), " t per t P2O5, molar ratio ",
            fmt_number(kpi[:granulation][:ammoniation_ratio], digits = 2), ")"),
        "Recycle ratio" => string(fmt_number(kpi[:granulation][:recycle_ratio], digits = 2), " : 1"),
        "Oversize and fines" => string(fmt_number(kpi[:granulation][:oversize_pct], digits = 1),
            " % and ", fmt_number(kpi[:granulation][:fines_pct], digits = 1), " %"),
        "Specific energy" => string(fmt_number(kpi[:energy][:specific_gj_per_p2o5], digits = 2),
            " GJ per t P2O5 (", fmt_number(kpi[:energy][:electricity_per_p2o5], digits = 1),
            " kWh of power)"),
        "Dryer fuel" => string(fmt_number(kpi[:energy][:fuel_gj] / 1000.0, digits = 1), " TJ of ",
            code_string(b[:design].dryer_fuel)),
        "Variable cost" => string(fmt_number(kpi[:cost][:total] / 1.0e6, digits = 2), " M",
            code_string(kpi[:cost][:currency]), " (", fmt_number(kpi[:cost][:per_t_product]),
            " per t of product)"),
        "Revenue and margin" => string(fmt_number(kpi[:cost][:revenue] / 1.0e6, digits = 1), " M",
            code_string(kpi[:cost][:currency]), " of revenue, margin ",
            fmt_number(kpi[:cost][:margin_per_t]), " per t"),
        "Carbon" => string(fmt_number(kpi[:carbon][:intensity_kg_per_p2o5], digits = 1),
            " kgCO2e per t P2O5 (scope 1 ", fmt_number(kpi[:carbon][:scope_1_t], digits = 1),
            " kt, scope 2 ", fmt_number(kpi[:carbon][:scope_2_t], digits = 1), " kt)"),
        "Stack" => string(fmt_number(kpi[:emissions][:stack_fluoride], digits = 2),
            " mg F per Nm3 (limit ", fmt_number(kpi[:emissions][:fluoride_limit], digits = 1),
            ") and ", fmt_number(kpi[:emissions][:stack_dust], digits = 1),
            " mg dust per Nm3 (limit ", fmt_number(kpi[:emissions][:dust_limit], digits = 0), ")"),
        "Water" => string(fmt_number(kpi[:water][:process_water_m3] / 1000.0, digits = 1),
            " thousand m3 (", fmt_number(kpi[:water][:water_per_p2o5], digits = 2),
            " t per t P2O5)"),
    ]; title = "Granulation, product and the economic and environmental view")
    body *= figure_or_nothing(figs, :energy_split)
    body *= figure_or_nothing(figs, :cost_split)
    body *= figure_or_nothing(figs, :targets)
    return section(:product_and_cost, "Granulation, product quality, energy, cost and carbon", body)
end

"""
    acid_section(bundle) -> Section

The acid route of the report: what the phosphoric acid plant produced, the balance of
the P2O5 from the attack to the storage tank, the specification of the merchant grade,
what the plant had to spend to make it and what a tonne of P2O5 costs as acid.
"""
function acid_section(b::Dict{Symbol,Any})
    kpi = b[:kpi]
    haskey(kpi, :acid) || return nothing
    a = kpi[:acid]
    s, figs = a[:summary], b[:figures]
    body = paragraph_html(string(
        "The acid plant produced ", fmt_number(s[:merchant_kt], digits = 1),
        " kt of merchant acid -- ", fmt_number(s[:merchant_p2o5_kt], digits = 1),
        " kt P2O5, ", fmt_number(s[:merchant_h3po4_kt], digits = 1),
        " kt H3PO4 on the 100 % basis -- at ", fmt_number(s[:grade_p2o5], digits = 2),
        " % P2O5, which is the ", code_string(s[:grade]), " grade. The evaporators removed ",
        fmt_number(s[:water_evaporated_t] / 1000.0, digits = 1), " thousand t of water with ",
        fmt_number(s[:steam_per_p2o5], digits = 3), " t of steam per t of P2O5 concentrated, an ",
        "economy of ", fmt_number(s[:economy], digits = 2), " t of water per t of steam. ",
        "The acid leaves the plant ", badge(s[:quality_status]),
        " against the specification of the traded grade."))
    body *= kv_table([
        "Merchant acid" => string(fmt_number(s[:merchant_kt], digits = 1), " kt (",
            fmt_number(s[:merchant_p2o5_kt], digits = 1), " kt P2O5, ",
            fmt_number(s[:merchant_h3po4_kt], digits = 1), " kt as H3PO4)"),
        "Grade" => string(fmt_number(s[:grade_p2o5], digits = 2), " % P2O5 (",
            fmt_number(s[:grade_h3po4], digits = 2), " % H3PO4) -- ", code_string(s[:grade])),
        "P2O5 of the attack" => string("the filters receive ",
            fmt_number(s[:share_of_filters_pct], digits = 1),
            " % of it as merchant acid, the rest goes to the granulation line"),
        "Yield" => string("the filtration and the attack keep ",
            fmt_number(s[:filtration_yield_pct], digits = 2),
            " % of the P2O5 fed; the evaporation closes at ",
            fmt_number(s[:concentration_yield_pct], digits = 2), " %"),
        "Concentration" => string(fmt_number(s[:water_per_p2o5], digits = 2),
            " m3 of feed and ", fmt_number(s[:thermal_gj_per_p2o5], digits = 2),
            " GJ of steam per t P2O5, ", fmt_number(s[:electricity_per_p2o5], digits = 0),
            " kWh of blower and pumps"),
        "Cost" => string(fmt_number(s[:cost_per_t_p2o5], digits = 0), " ",
            code_string(a[:cost][:currency]), " per t P2O5 as acid (",
            fmt_number(s[:cost_per_t_acid], digits = 1), " per t of acid) against a price of ",
            fmt_number(s[:revenue_per_t_p2o5], digits = 0), " and a margin of ",
            fmt_number(s[:margin_per_t_p2o5], digits = 0), " per t P2O5"),
    ]; title = "The merchant acid of the campaign")
    body *= table_html(a[:quality][:rows];
        columns = [:spec, :tag, :value, :limit, :unit, :comparator, :margin_pct, :status],
        headers = Dict{Symbol,String}(:spec => "Specification", :tag => "Instrument",
            :value => "Campaign", :limit => "Limit", :unit => "Unit", :comparator => "Direction",
            :margin_pct => "Margin %", :status => "Status"),
        formats = Dict{Symbol,Function}(:spec => v -> to_string(v), :tag => v -> code_string(v),
            :unit => v -> code_string(v), :comparator => v -> code_string(v),
            :status => v -> badge(v)),
        title = "The merchant acid against the specification of the traded grade")
    body *= table_html(a[:balance];
        columns = [:destination, :p2o5_t, :share_pct, :note],
        headers = Dict{Symbol,String}(:destination => "Destination", :p2o5_t => "t P2O5",
            :share_pct => "Share %", :note => "Note"),
        formats = Dict{Symbol,Function}(:destination => v -> to_string(v)),
        title = "Where the P2O5 of the attack goes")
    body *= table_html(a[:steps];
        columns = [:step, :in_t, :out_t, :loss_t, :yield_pct, :note],
        headers = Dict{Symbol,String}(:step => "Step", :in_t => "In (t P2O5)",
            :out_t => "Out (t P2O5)", :loss_t => "Loss (t P2O5)", :yield_pct => "Yield %",
            :note => "Note"),
        formats = Dict{Symbol,Function}(:step => v -> to_string(v)),
        title = "The steps of the acid route")
    body *= table_html(a[:consumption];
        columns = [:metric, :value, :unit, :basis, :note],
        headers = Dict{Symbol,String}(:metric => "Consumption", :value => "Value", :unit => "Unit",
            :basis => "Basis", :note => "Note"),
        formats = Dict{Symbol,Function}(:metric => v -> to_string(v), :unit => v -> code_string(v),
            :basis => v -> code_string(v)),
        title = "What a tonne of P2O5 costs in rock, acid, steam and water")
    body *= table_html(a[:targets] |> values |> collect;
        columns = [:metric, :actual, :target, :unit, :comparator, :margin_pct, :status],
        headers = Dict{Symbol,String}(:metric => "Metric", :actual => "Campaign",
            :target => "Target", :unit => "Unit", :comparator => "Direction",
            :margin_pct => "Margin %", :status => "Status"),
        formats = Dict{Symbol,Function}(:metric => v -> code_string(v),
            :unit => v -> code_string(v), :comparator => v -> code_string(v),
            :status => v -> badge(v)),
        title = "The targets of the acid route")
    body *= figure_or_nothing(figs, :acid_balance)
    body *= figure_or_nothing(figs, :acid_quality)
    body *= figure_or_nothing(figs, :acid_cost)
    body *= callout_html(s[:status] === :compliant ? :info : :warning, string(
        "Acid route: the plant kept ", fmt_number(s[:filtration_yield_pct], digits = 2),
        " % of the P2O5 at the filters, sold ", fmt_number(s[:merchant_kt], digits = 1),
        " kt of acid at ", fmt_number(s[:grade_p2o5], digits = 2), " % P2O5 for ",
        fmt_number(s[:revenue_per_t_p2o5], digits = 0), " per t P2O5, and spent ",
        fmt_number(s[:cost_per_t_p2o5], digits = 0), "."))
    return section(:phosphoric_acid, "Phosphoric acid: balance, specification and cost", body)
end

"""The performance register: every metric against its target."""
function target_section(b::Dict{Symbol,Any})
    kpi = b[:kpi]
    rows = target_table(kpi)
    counts = target_counts(kpi)
    body = cards_html([(; label = to_string(s), value = string(counts[s]), unit = "metrics",
            status = s, note = "") for s in STATUSES if counts[s] > 0]; columns = 4)
    body *= table_html(rows;
        columns = [:metric, :actual, :target, :unit, :comparator, :margin_pct, :status, :basis],
        headers = Dict{Symbol,String}(:metric => "Metric", :actual => "Campaign",
            :target => "Target", :unit => "Unit", :comparator => "Direction",
            :margin_pct => "Margin %", :status => "Status", :basis => "Basis"),
        formats = Dict{Symbol,Function}(:metric => v -> code_string(v),
            :unit => v -> code_string(v), :comparator => v -> code_string(v),
            :status => v -> badge(v), :basis => v -> string(v)))
    body *= figure_or_nothing(b[:figures], :targets)
    return section(:performance_register, "The performance register of the campaign", body)
end

"""The digital twin: the steady state, its residuals, its limits and its dynamic answer."""
function twin_section(b::Dict{Symbol,Any})
    haskey(b, :twin) && b[:twin] !== nothing || return nothing
    t = b[:twin]
    figs = b[:figures]
    ss = t[:solution]
    body = paragraph_html(string("The steady-state twin of the reaction train is a ",
        "square system of ", length(STEADY_UNKNOWNS), " nonlinear balances solved with ",
        "ModelingToolkit (", ss[:basis], "). It converged in ",
        fmt_number(ss[:seconds], digits = 2), " s with a largest residual of ",
        fmt_value(ss[:max_residual]), " -- the residual is reported because a solution ",
        "nobody checked is a guess."))
    body *= table_html(t[:table];
        columns = [:variable, :value, :unit, :description],
        headers = Dict{Symbol,String}(:variable => "Unknown", :value => "Value", :unit => "Unit",
            :description => "Description"),
        formats = Dict{Symbol,Function}(:variable => v -> code_string(v),
            :unit => v -> code_string(v), :value => v -> fmt_number(v, digits = 4)))
    body *= table_html(battery_limits_check(b[:design], ss);
        columns = [:variable, :value, :low, :high, :unit, :margin_low, :margin_high, :status],
        headers = Dict{Symbol,String}(:variable => "Variable", :value => "At the solution",
            :low => "Low", :high => "High", :unit => "Unit", :margin_low => "Margin low",
            :margin_high => "Margin high", :status => "Status"),
        formats = Dict{Symbol,Function}(:variable => v -> code_string(v),
            :unit => v -> code_string(v), :status => v -> badge(v)),
        title = "Operating window at the solution")
    body *= figure_or_nothing(figs, :envelope)
    if haskey(b, :alignment) && b[:alignment] !== nothing
        a = b[:alignment]
        body *= paragraph_html(string("Against the campaign it is supposed to describe, the ",
            "twin scores ", fmt_number(a[:validity_score], digits = 1), " % of validity: ",
            "the residuals below are what a commissioning would absorb as a bias, and the ",
            "reason they are printed is that a twin is only as good as this table."))
        body *= table_html(a[:rows];
            columns = [:variable, :twin, :measured, :unit, :residual_pct, :tolerance_pct, :status],
            headers = Dict{Symbol,String}(:variable => "Variable", :twin => "Twin",
                :measured => "Plant", :unit => "Unit", :residual_pct => "Residual %",
                :tolerance_pct => "Tolerance %", :status => "Status"),
            formats = Dict{Symbol,Function}(:variable => v -> code_string(v),
                :unit => v -> code_string(v), :status => v -> badge(v)))
        body *= figure_or_nothing(figs, :alignment)
    end
    return section(:digital_twin, "The digital twin: steady state, limits and alignment", body)
end

"""The dynamic twin and the state estimation it feeds."""
function dynamic_section(b::Dict{Symbol,Any})
    haskey(b, :dynamic) && b[:dynamic] !== nothing || return nothing
    sim = b[:dynamic]
    figs = b[:figures]
    body = paragraph_html(string("The dynamic twin integrates ", length(DYNAMIC_STATES),
        " states with ", sim[:solver], " on the hourly clock of the plant, from the same ",
        "correlations the historian uses: the holdup of the attack tanks, the strength of ",
        "the acid, the moisture of the granulator bed, the holdup of the mills and the ",
        "fouling of the evaporator tubes."))
    body *= kv_table([
        "Horizon" => string(sim[:tspan][1], " to ", sim[:tspan][2], " h"),
        "Status" => string(sim[:status], " (", sim[:retcode], ")"),
        "P2O5 fed over the horizon" => string(fmt_number(sim[:balance][:fed_t], digits = 1), " t"),
        "Liquor of the attack tanks" => string(fmt_number(sim[:balance][:liquor_start], digits = 1),
            " t to ", fmt_number(sim[:balance][:liquor_end], digits = 1), " t (",
            fmt_number(sim[:balance][:liquor_change_pct], digits = 2), " %)"),
        "Highest temperature" => string(fmt_number(sim[:balance][:max_temperature], digits = 2),
            " C"),
        "Weakest acid" => string(fmt_number(sim[:balance][:min_acid_strength], digits = 2), " % P2O5"),
        "Fouling at the end" => string(fmt_value(sim[:balance][:final_fouling])),
        "Integration time" => string(fmt_number(sim[:seconds], digits = 2), " s"),
    ]; title = "Dynamic trajectory of the twin")
    if haskey(b, :estimation) && b[:estimation] !== nothing
        est = b[:estimation]
        rows = [Dict{Symbol,Any}(:output => o, :rmse => v[:rmse], :bias => v[:bias],
                :n => v[:n]) for (o, v) in sort(collect(est[:rmse]); by = x -> String(x[1]))]
        body *= paragraph_html(string("The Kalman filter of the twin walked the historian for ",
            est[:window][2] - est[:window][1] + 1, " intervals and estimated the states nobody ",
            "measures. The innovation of every measurement is the table below: it is the ",
            "residual the controller sees, and a sensor that drifts shows up here first."))
        body *= table_html(rows; columns = [:output, :rmse, :bias, :n],
            headers = Dict{Symbol,String}(:output => "Measurement", :rmse => "RMSE of the innovation",
                :bias => "Bias", :n => "Intervals"),
            formats = Dict{Symbol,Function}(:output => v -> code_string(v)))
    end
    return section(:dynamic_twin, "The dynamic twin and the state estimation", body)
end

"""The predictive controller and the PI baseline it is compared with."""
function control_section(b::Dict{Symbol,Any})
    haskey(b, :mpc) && b[:mpc] !== nothing || return nothing
    m = b[:mpc]
    figs = b[:figures]
    lin = m[:mpc][:setup].linear
    config = m[:mpc][:config]
    body = paragraph_html(string("The controller is the one the plant would run: a linear ",
        "predictive controller over the discrete model ", size(lin[:Ad], 1), " x ",
        size(lin[:Ad], 1), " obtained by linearising the ODE twin at its operating point (",
        fmt_number(config.horizon, digits = 0), " prediction steps, ",
        fmt_number(config.control_horizon, digits = 0), " control steps, sample time ",
        fmt_number(lin[:Ts], digits = 2), " h), with a Kalman filter estimating the states ",
        "from the measurements. The plant of the test is the <em>nonlinear</em> twin, so the ",
        "controller never sees the equations it is controlling."))
    body *= kv_table([
        "Scenario" => string(code_string(m[:scenario]), " over ",
            fmt_number(m[:steps], digits = 0), " hours"),
        "Model" => string(size(lin[:Ad], 1), " states, ", length(lin[:inputs]), " inputs, ",
            length(lin[:outputs]), " outputs, Ts = ", fmt_number(lin[:Ts], digits = 2), " h"),
        "Controllability" => string("conditioning ", fmt_number(lin[:controllability], digits = 1)),
        "Poles" => string("largest magnitude ", fmt_number(maximum(abs.(lin[:poles])), digits = 4)),
        "MPC error" => string(fmt_number(m[:summary][:mpc_iae], digits = 2), " bands and ",
            fmt_number(m[:summary][:mpc_violations], digits = 0), " violations"),
        "PI error" => string(fmt_number(m[:summary][:pi_iae], digits = 2), " bands and ",
            fmt_number(m[:summary][:pi_violations], digits = 0), " violations"),
    ]; title = "Closed loop of the two controllers")
    body *= table_html(m[:comparison];
        columns = [:output, :band, :mpc_iae, :pi_iae, :iae_improvement_pct, :mpc_max_deviation,
            :pi_max_deviation, :mpc_hours_out, :pi_hours_out],
        headers = Dict{Symbol,String}(:output => "Controlled variable", :band => "Band",
            :mpc_iae => "MPC error", :pi_iae => "PI error", :iae_improvement_pct => "Improvement %",
            :mpc_max_deviation => "MPC worst", :pi_max_deviation => "PI worst",
            :mpc_hours_out => "MPC hours out", :pi_hours_out => "PI hours out"),
        formats = Dict{Symbol,Function}(:output => v -> code_string(v)))
    body *= figure_or_nothing(figs, :mpc_loop)
    body *= figure_or_nothing(figs, :mpc_inputs)
    body *= figure_or_nothing(figs, :mpc_comparison)
    body *= table_html(m[:moves];
        columns = [:input, :mpc_movement_pct, :pi_movement_pct, :mpc_reversals, :pi_reversals,
            :mpc_range_pct, :pi_range_pct],
        headers = Dict{Symbol,String}(:input => "Manipulated variable",
            :mpc_movement_pct => "MPC movement %", :pi_movement_pct => "PI movement %",
            :mpc_reversals => "MPC reversals", :pi_reversals => "PI reversals",
            :mpc_range_pct => "MPC range %", :pi_range_pct => "PI range %"),
        formats = Dict{Symbol,Function}(:input => v -> code_string(v)),
        title = "Work the two controllers asked of the plant")
    return section(:predictive_control, "Predictive control of the reaction train", body)
end

"""The three optimisation models of the plant."""
function optimization_section(b::Dict{Symbol,Any})
    haskey(b, :optimization) && b[:optimization] !== nothing || return nothing
    o = b[:optimization]
    body = paragraph_html(string("Three models of the same plant are solved every day: the ",
        "blend of the ore the digester is fed -- a linear program over the registered assays ",
        "with the specifications of the reaction section --, the operating point of the ",
        "reaction train -- a nonlinear program over the correlations of the twin -- and the ",
        "annual sourcing plan, a mixed-integer program because a body is bought by the ",
        "shipload."))
    body *= figure_or_nothing(b[:figures], :blend)
    body *= table_html(o[:blend][:rows];
        columns = [:body, :tonnes_ph, :share_pct, :price, :p2o5, :cao_p2o5, :fe_al, :mgo],
        headers = Dict{Symbol,String}(:body => "Ore body", :tonnes_ph => "t/h",
            :share_pct => "Share %", :price => "Price", :p2o5 => "P2O5 %",
            :cao_p2o5 => "CaO:P2O5", :fe_al => "Fe+Al %", :mgo => "MgO %"),
        formats = Dict{Symbol,Function}(:body => v -> code_string(v)),
        title = string("Optimal blend (", o[:blend][:solver], ", status ",
            code_string(o[:blend][:status]), ", ", fmt_number(o[:blend][:blend_grade], digits = 2),
            " % P2O5 at ", fmt_number(o[:blend][:cost_per_t_rock], digits = 2), " per t)"))
    duals = [Dict{Symbol,Any}(:constraint => k, :dual => v) for (k, v) in
             sort(collect(o[:blend][:duals]); by = x -> -abs(x[2]))]
    body *= table_html(duals; columns = [:constraint, :dual],
        headers = Dict{Symbol,String}(:constraint => "Specification", :dual => "Shadow price"),
        formats = Dict{Symbol,Function}(:constraint => v -> code_string(v)),
        title = "What one more unit of each specification is worth")
    body *= table_html(o[:operating_rows]; columns = [:kind, :variable, :value],
        headers = Dict{Symbol,String}(:kind => "Nature", :variable => "Variable",
            :value => "Optimum"),
        formats = Dict{Symbol,Function}(:kind => v -> code_string(v),
            :variable => v -> code_string(v)),
        title = string("Operating point (", o[:operating_point][:solver], ", status ",
            code_string(o[:operating_point][:status]), ", margin ",
            fmt_number(o[:operating_point][:margin_per_t_product], digits = 1), " per t)"))
    body *= table_html(o[:sourcing_rows];
        columns = [:body, :tonnes, :share_pct, :price, :cost, :months_active, :p2o5],
        headers = Dict{Symbol,String}(:body => "Ore body", :tonnes => "t per year",
            :share_pct => "Share %", :price => "Price", :cost => "Cost",
            :months_active => "Months", :p2o5 => "P2O5 %"),
        formats = Dict{Symbol,Function}(:body => v -> code_string(v)),
        title = string("Annual sourcing plan (", o[:sourcing][:solver], ", ",
            o[:sourcing][:binaries], " binary decisions, ",
            fmt_number(o[:sourcing][:cost_per_t_p2o5]), " per t P2O5)"))
    return section(:optimization, "Optimisation of the blend, the operating point and the sourcing",
        body)
end

"""The inferential sensors: process, visual and acoustic."""
function sensor_section(b::Dict{Symbol,Any})
    haskey(b, :soft) && b[:soft] !== nothing || return nothing
    s = b[:soft]
    body = kv_table([
        "Sensors" => string(s[:summary][:sensors], " inferential models, of which ",
            s[:summary][:features], " read an image or a sound"),
        "Median R2" => fmt_number(s[:summary][:median_r2], digits = 3),
        "Best sensor" => string(code_string(s[:summary][:best])),
        "Status" => string(code_string(s[:summary][:status])),
    ]; title = "The register of the inferential sensors")
    body *= table_html(s[:rows];
        columns = [:sensor, :target, :kind, :unit, :r2, :rmse, :bias, :in_domain_pct, :drift,
            :status, :inputs],
        headers = Dict{Symbol,String}(:sensor => "Sensor", :target => "Infers", :kind => "Modality",
            :unit => "Unit", :r2 => "R2", :rmse => "RMSE", :bias => "Bias",
            :in_domain_pct => "In domain %", :drift => "Drift", :status => "Status",
            :inputs => "Inputs"),
        formats = Dict{Symbol,Function}(:sensor => v -> code_string(v),
            :target => v -> code_string(v), :kind => v -> code_string(v),
            :unit => v -> code_string(v), :status => v -> badge(v),
            :r2 => v -> fmt_number(v, digits = 3), :rmse => v -> fmt_number(v, digits = 4)))
    body *= table_html(s[:estimates];
        columns = [:sensor, :target, :unit, :estimate, :measured, :difference_pct, :rmse, :status],
        headers = Dict{Symbol,String}(:sensor => "Sensor", :target => "Infers", :unit => "Unit",
            :estimate => "Estimate", :measured => "Measured", :difference_pct => "Difference %",
            :rmse => "RMSE", :status => "Status"),
        formats = Dict{Symbol,Function}(:sensor => v -> code_string(v),
            :target => v -> code_string(v), :unit => v -> code_string(v),
            :status => v -> badge(v)),
        title = "What the sensors say against what the plant measured")
    for id in (:sensor_parity,)
        body *= figure_or_nothing(b[:figures], id)
    end
    body *= figure_or_nothing(b[:figures], :vision_parity)
    body *= figure_or_nothing(b[:figures], :froth_image)
    body *= figure_or_nothing(b[:figures], :rock_image)
    body *= figure_or_nothing(b[:figures], :spectrum)
    body *= figure_or_nothing(b[:figures], :acoustic_parity)
    return section(:soft_sensors, "The inferential sensors: process, vision and acoustics", body)
end

"""The diagnostics: the findings, what they are worth and how well they were caught."""
function diagnostics_section(b::Dict{Symbol,Any})
    fdd = b[:fdd]
    body = kv_table([
        "Findings" => string(fdd[:summary][:count], " (", fdd[:summary][:by_severity][:critical],
            " critical, ", fdd[:summary][:by_severity][:warning], " warning, ",
            fdd[:summary][:by_severity][:info], " info)"),
        "Value at stake" => string(fmt_number(fdd[:summary][:cost_at_stake], digits = 0), " ",
            code_string(b[:kpi][:cost][:currency]), " a year"),
        "Hours in alarm" => string(fmt_number(fdd[:summary][:hours_in_alarm], digits = 0), " h"),
        "Rules applied" => string(fdd[:rules_checked], " rules of the catalogue"),
        "Deviations caught" => string(fdd[:verification][:detected], " of ",
            fdd[:verification][:injected], " (",
            fmt_number(fdd[:verification][:detection_rate_pct], digits = 1), " %)"),
        "Status" => string(code_string(fdd[:summary][:status])),
    ]; title = "Diagnostic summary")
    body *= table_html(fdd[:rows];
        columns = [:severity, :area, :rule, :tag, :metric, :reference, :unit, :deviation_pct,
            :from, :to, :intervals, :cost_at_stake],
        headers = Dict{Symbol,String}(:severity => "Severity", :area => "Area", :rule => "Rule",
            :tag => "Signal", :metric => "Measured", :reference => "Reference", :unit => "Unit",
            :deviation_pct => "Deviation %", :from => "From", :to => "To",
            :intervals => "Hours", :cost_at_stake => "Value at stake"),
        formats = Dict{Symbol,Function}(:severity => v -> badge(v), :area => v -> code_string(v),
            :rule => v -> code_string(v), :tag => v -> code_string(v),
            :unit => v -> code_string(v), :from => v -> string(v), :to => v -> string(v)))
    body *= table_html(fdd[:verification][:rows];
        columns = [:fault, :role, :kind, :magnitude, :unit, :hours, :detected, :rule, :findings],
        headers = Dict{Symbol,String}(:fault => "Injected deviation", :role => "Role",
            :kind => "Kind", :magnitude => "Magnitude", :unit => "Unit", :hours => "Hours",
            :detected => "Detected", :rule => "Rule that caught it", :findings => "Findings"),
        formats = Dict{Symbol,Function}(:fault => v -> code_string(v), :role => v -> code_string(v),
            :kind => v -> code_string(v), :unit => v -> code_string(v),
            :rule => v -> code_string(v)),
        title = "Did the detector catch what the campaign injected?")
    body *= paragraph_html(string("The catalogue of the detector holds ", fdd[:rules_checked],
        " rules, each with the signal it watches, the reference it compares against and the ",
        "window it averages over; `PHOSPHATE.RULE_CATALOGUE` prints them and the notebook ",
        "shows them rule by rule."))
    return section(:diagnostics, "Fault detection and diagnostics", body)
end

"""The compliance register: the scorecard, the clauses and the corrective actions."""
function compliance_section(b::Dict{Symbol,Any})
    comp = b[:compliance]
    sc = comp[:scorecard]
    body = cards_html([
        (; label = "Compliance", value = fmt_number(sc[:compliance_pct], digits = 1),
            unit = "% of clauses", status = sc[:overall_status],
            note = string(sc[:clause_count], " clauses in ", sc[:frameworks], " frameworks")),
        (; label = "Compliant", value = string(sc[:compliant]), unit = "clauses",
            status = :compliant, note = ""),
        (; label = "At risk", value = string(sc[:at_risk]), unit = "clauses",
            status = :at_risk, note = "within 10 % of the limit"),
        (; label = "Non-compliant", value = string(sc[:noncompliant]), unit = "clauses",
            status = :noncompliant, note = "outside the limit"),
    ]; columns = 4)
    body *= table_html([Dict{Symbol,Any}(:framework => f, :title => v[:title],
            :clauses => v[:clauses], :compliant => v[:compliant], :at_risk => v[:at_risk],
            :noncompliant => v[:noncompliant], :compliance_pct => v[:compliance_pct])
            for (f, v) in sort(collect(sc[:by_framework]); by = x -> string(x[1]))];
        columns = [:framework, :title, :clauses, :compliant, :at_risk, :noncompliant,
            :compliance_pct],
        headers = Dict{Symbol,String}(:framework => "Framework", :title => "Title",
            :clauses => "Clauses", :compliant => "Compliant", :at_risk => "At risk",
            :noncompliant => "Non-compliant", :compliance_pct => "Compliant %"),
        formats = Dict{Symbol,Function}(:framework => v -> code_string(v)),
        title = "The scorecard, framework by framework")
    body *= table_html(comp[:register];
        columns = [:framework, :clause, :title, :metric, :value, :target, :unit, :margin_pct,
            :status],
        headers = Dict{Symbol,String}(:framework => "Framework", :clause => "Clause",
            :title => "Title", :metric => "Metric", :value => "Value", :target => "Target",
            :unit => "Unit", :margin_pct => "Margin %", :status => "Status"),
        formats = Dict{Symbol,Function}(:framework => v -> code_string(v),
            :clause => v -> code_string(v), :metric => v -> code_string(v),
            :unit => v -> code_string(v), :status => v -> badge(v)))
    body *= table_html(comp[:actions];
        columns = [:framework, :clause, :metric, :value, :target, :gap_pct, :status, :action],
        headers = Dict{Symbol,String}(:framework => "Framework", :clause => "Clause",
            :metric => "Metric", :value => "Value", :target => "Target", :gap_pct => "Gap %",
            :status => "Status", :action => "Corrective action"),
        formats = Dict{Symbol,Function}(:framework => v -> code_string(v),
            :clause => v -> code_string(v), :metric => v -> code_string(v),
            :status => v -> badge(v)),
        title = "What has to be done about it")
    return section(:compliance, "Compliance register and corrective actions", body)
end

"""The quality of the historian and of the instrument register."""
function quality_section(b::Dict{Symbol,Any})
    kpi = b[:kpi]
    q = kpi[:quality]
    body = kv_table([
        "Intervals" => string(fmt_number(q[:intervals], digits = 0), " hourly intervals of ",
            length(b[:campaign].book), " signals"),
        "Operating intervals" => string(fmt_number(q[:operating_intervals], digits = 0)),
        "Completeness" => string(fmt_number(q[:completeness_pct], digits = 2), " % of the register"),
        "Defect runs" => string(q[:defect_runs], " runs over ", q[:defect_intervals], " intervals"),
        "Causes" => join([string(code_string(k), " ", v) for (k, v) in
                          sort(collect(q[:by_kind]); by = x -> string(x[1]))], ", "),
        "Status" => string(code_string(q[:status])),
    ]; title = "Quality of the historian")
    body *= figure_or_nothing(b[:figures], :quality)
    body *= table_html(q[:defects];
        columns = [:tag, :from, :to, :intervals, :quality],
        headers = Dict{Symbol,String}(:tag => "Signal", :from => "From", :to => "To",
            :intervals => "Intervals", :quality => "Cause"),
        formats = Dict{Symbol,Function}(:tag => v -> code_string(v), :quality => v -> badge(v),
            :from => v -> string(v), :to => v -> string(v)),
        title = "Every run of unusable data of the campaign")
    if haskey(b, :reconciliation) && b[:reconciliation] !== nothing
        rec = get(b[:reconciliation], :reconciliation, b[:reconciliation])
        body *= paragraph_html(string("The flows of the campaign were reconciled against the ",
            "stoichiometry of the reaction section: the weighted least squares adjustment ",
            "leaves a global test statistic of ", fmt_number(rec[:statistic], digits = 3),
            " against a critical value of ", fmt_number(rec[:critical], digits = 3), " for ",
            rec[:dof], " balances, so the measurements are ",
            rec[:balance_pass] ? "consistent" : "inconsistent", " with the balances."))
        body *= table_html(rec[:rows];
            columns = [:tag, :measured, :reconciled, :adjustment, :adjustment_sigma, :unit,
                :gross_error],
            headers = Dict{Symbol,String}(:tag => "Signal", :measured => "Measured",
                :reconciled => "Reconciled", :adjustment => "Adjustment",
                :adjustment_sigma => "In sigma", :unit => "Unit", :gross_error => "Gross error"),
            formats = Dict{Symbol,Function}(:tag => v -> code_string(v),
                :unit => v -> code_string(v)))
    end
    return section(:data_quality, "Data quality, reconciliation and the instrument register", body)
end

"""Method, units and the assumptions a reader has to know to use the numbers."""
function method_section(b::Dict{Symbol,Any})
    d = b[:design]
    rows = [Dict{Symbol,Any}(:area => a, :streams => length(streams_of(a)),
            :equipment => length(equipment_of(a)), :units => length(units_of(b[:flowsheet], a)),
            :tags => length(signals_in(a))) for a in AREAS]
    body = table_html(rows;
        columns = [:area, :streams, :equipment, :units, :tags],
        headers = Dict{Symbol,String}(:area => "Area", :streams => "Streams",
            :equipment => "Equipment", :units => "Unit operations", :tags => "Instrument tags"),
        formats = Dict{Symbol,Function}(:area => v -> string(area_name(v))))
    body *= list_html([
        "The **design** of the plant is registered in `process.jl`: capacities, targets, the " *
        "flowsheet and the instrument register. Every model of the package reads it, so a " *
        "capacity change propagates to the twin, the optimiser, the controller and the report.",
        string("The **campaign** is a seeded grey-box model of that design (`plantdata.jl`): ",
            "the production schedule, the ore blend, the weather and the injected deviations ",
            "are all functions of the seed, so every figure and every PDF can be reproduced ",
            "from the seed printed on the cover page."),
        string("The **stoichiometry** is computed from the molar masses in `measures.jl`: ",
            fmt_number(STOICH.acid), " t of H2SO4 and ", fmt_number(STOICH.gypsum),
            " t of gypsum per tonne of P2O5 in fluorapatite, plus the demand of the free ",
            "carbonate of the ore. The assays of the ore bodies are representative published ",
            "figures, not the assay of a particular mine."),
        string("The **twin** is written in ModelingToolkit: a square nonlinear balance of ",
            length(STEADY_UNKNOWNS), " unknowns for the steady state, and ", length(DYNAMIC_STATES),
            " differential equations on an hourly clock for the dynamics. Both report the ",
            "residual of every equation they solve."),
        string("The **controller** is a linear MPC over the linearised twin with a Kalman ",
            "filter, closed on the nonlinear twin as the plant; the baseline is a PI controller ",
            "tuned on the same steady-state gains, so the comparison is like for like."),
        string("The **soft sensors** are linear models of the variables that are measured ",
            "slowly or not at all, validated on a holdout and equipped with an applicability ",
            "domain: outside the conditions they were fitted on, they report that they cannot ",
            "answer."),
        string("The **cost and carbon** of the site use the register of `process.jl` ",
            "(", code_string(d.site.currency), ") and the factors of the GHG Protocol: ",
            fmt_number(EMISSION_FACTORS.grid_electricity_kg_per_kwh, digits = 3),
            " kgCO2e/kWh for the grid and ",
            fmt_number(EMISSION_FACTORS.natural_gas_kg_per_gj), " kgCO2e/GJ for the fuel."),
    ])
    return section(:method, "Method, units and assumptions", body)
end

"""Groups of sections a notebook (or a PDF) can ask for by name."""
const SECTION_GROUPS = Dict{Symbol,Vector{Symbol}}(
    :executive => [:executive_summary],
    :flowsheet => [:flowsheet],
    :ore => [:ore_and_flotation],
    :reaction => [:reaction_train],
    :acid => [:phosphoric_acid],
    :product => [:product_and_cost],
    :targets => [:performance_register],
    :twin => [:digital_twin, :dynamic_twin],
    :control => [:predictive_control],
    :optimization => [:optimization],
    :sensors => [:soft_sensors],
    :diagnostics => [:diagnostics],
    :compliance => [:compliance],
    :quality => [:data_quality],
    :method => [:method],
    :all => Symbol[],
)

"""
    report_sections(bundle; ids) -> Vector{Section}

The ordered sections of the report of a bundle. `ids` selects a subset; a section
whose subsystem is missing from the bundle is skipped rather than printed empty, so
a report never claims more than it has.
"""
function report_sections(b::Dict{Symbol,Any}; ids::Union{Nothing,Vector{Symbol}} = nothing)
    built = [
        executive_section(b), plant_layout_section(b), ore_section(b), reaction_section(b),
        acid_section(b), product_section(b), target_section(b), twin_section(b), dynamic_section(b),
        control_section(b), optimization_section(b), sensor_section(b), diagnostics_section(b),
        compliance_section(b), quality_section(b), method_section(b),
    ]
    sections = [s for s in built if s !== nothing]
    ids === nothing && return sections
    return [s for s in sections if s.id in ids]
end

"""
    report_html(bundle; title, subtitle, ids, css) -> String

The complete report as HTML text, ready to be written to disk and printed to PDF.
"""
function report_html(b::Dict{Symbol,Any}; title::AbstractString = "",
    subtitle::AbstractString = "The ore, the acid, the product, the twin, the controller " *
                               "and the evidence",
    ids::Union{Nothing,Vector{Symbol}} = nothing, css::AbstractString = PRINTOUT_CSS)
    meta = report_meta(b; title = title, subtitle = subtitle)
    return document_html(meta, report_sections(b; ids = ids); css = css)
end

"""The report restricted to one group of sections, as HTML."""
function section_html(b::Dict{Symbol,Any}, group::Symbol; title::AbstractString = "")
    ids = get(SECTION_GROUPS, group, Symbol[])
    sections = report_sections(b; ids = isempty(ids) ? nothing : ids)
    meta = report_meta(b; title = isempty(title) ? string("Phosphate plant -- ",
        to_string(group)) : title, subtitle = string("Section report: ", to_string(group)))
    return document_html(meta, sections)
end

"""One section of a report as displayable HTML (what a notebook cell shows)."""
function preview(b::Dict{Symbol,Any}, id::Symbol)
    sections = report_sections(b; ids = [id])
    isempty(sections) && return PrintableHTML(string("<p class=\"empty\">No section ",
        code_string(id), " in this bundle.</p>"))
    return PrintableHTML(join([string("<h2>", html_escape(s.title), "</h2>\n", s.body)
                               for s in sections]))
end

"""Preview of the executive summary."""
preview_executive(b::Dict{Symbol,Any}) = preview(b, :executive_summary)
"""Preview of the flowsheet and the design."""
preview_flowsheet(b::Dict{Symbol,Any}) = preview(b, :flowsheet)
"""Preview of the ore and flotation balance."""
preview_ore(b::Dict{Symbol,Any}) = preview(b, :ore_and_flotation)
"""Preview of the reaction train."""
preview_reaction(b::Dict{Symbol,Any}) = preview(b, :reaction_train)
"""Preview of the phosphoric acid route: the balance, the specification and the cost."""
preview_acid(b::Dict{Symbol,Any}) = preview(b, :phosphoric_acid)
"""Preview of the product, energy, cost and carbon."""
preview_product(b::Dict{Symbol,Any}) = preview(b, :product_and_cost)
"""Preview of the performance register."""
preview_targets(b::Dict{Symbol,Any}) = preview(b, :performance_register)
"""Preview of the steady-state twin."""
preview_twin(b::Dict{Symbol,Any}) = preview(b, :digital_twin)
"""Preview of the dynamic twin and the state estimation."""
preview_dynamic(b::Dict{Symbol,Any}) = preview(b, :dynamic_twin)
"""Preview of the predictive control section."""
preview_control(b::Dict{Symbol,Any}) = preview(b, :predictive_control)
"""Preview of the optimisation section."""
preview_optimization(b::Dict{Symbol,Any}) = preview(b, :optimization)
"""Preview of the soft sensors."""
preview_sensors(b::Dict{Symbol,Any}) = preview(b, :soft_sensors)
"""Preview of the diagnostics."""
preview_diagnostics(b::Dict{Symbol,Any}) = preview(b, :diagnostics)
"""Preview of the compliance register."""
preview_compliance(b::Dict{Symbol,Any}) = preview(b, :compliance)
"""Preview of the data quality and the reconciliation."""
preview_quality(b::Dict{Symbol,Any}) = preview(b, :data_quality)
"""Preview of the method and the assumptions."""
preview_method(b::Dict{Symbol,Any}) = preview(b, :method)

"""
    print_report_pdf(bundle; id, group, root, chrome, title) -> Dict{Symbol,Any}

Write the printout of a report (the whole one or the group of sections named by
`group`) and print it to PDF with the headless browser. This is the call a notebook
makes in its last cell, and the same call the pipeline makes for every deliverable.
"""
function print_report_pdf(b::Dict{Symbol,Any}; id::Symbol = :phosphate,
    group::Symbol = :all, root::AbstractString = pwd(), chrome = nothing,
    title::AbstractString = "")
    html = group === :all ? report_html(b; title = title) :
           section_html(b, group; title = title)
    html_path = joinpath(root, "reports", "html", string("notebook_", id, ".html"))
    pdf_path = joinpath(root, "reports", "pdf", string("notebook_", id, ".pdf"))
    write_printout(html_path, html)
    pdf = html_to_pdf(html_path, pdf_path; chrome = chrome)
    return Dict{Symbol,Any}(:notebook => id, :group => group, :html => html_path, :pdf => pdf,
        :html_bytes => filesize(html_path), :pdf_bytes => filesize(pdf),
        :sections => length(report_sections(b; ids = group === :all ? nothing :
                                            get(SECTION_GROUPS, group, Symbol[]))))
end















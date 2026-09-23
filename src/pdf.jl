# =============================================================================
# pdf.jl -- turning a printout into a PDF.
#
# The pipeline prints the HTML printout with a headless Chromium (Chrome or Edge),
# which is the same engine a user gets with "Print to PDF" from the browser. Only
# the print stylesheet of the document matters, so the PDF of a notebook and the
# printout it displays stay identical by construction.
# =============================================================================

"""Chromium-based browsers searched for when `CHROME_PATH` is not set."""
const CHROME_CANDIDATES = String[
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
    "/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium",
    "/usr/bin/chromium-browser", "/snap/bin/chromium",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
]

"""
    find_chrome(; explicit = nothing) -> String

Locate the Chromium executable used to print PDFs, in this order: the `explicit`
argument, the `CHROME_PATH` environment variable, the platform `PATH`, then the
known installation directories. Throws when nothing is found.
"""
function find_chrome(; explicit::Union{Nothing,AbstractString} = nothing)
    explicit !== nothing && return String(explicit)
    from_env = get(ENV, "CHROME_PATH", "")
    !isempty(from_env) && isfile(from_env) && return from_env
    for name in ("chrome", "google-chrome", "chromium", "chromium-browser", "msedge")
        found = Sys.which(name)
        found === nothing || return found
    end
    for c in CHROME_CANDIDATES
        isfile(c) && return c
    end
    throw(ArgumentError("no Chromium-based browser found; set the CHROME_PATH environment " *
                        "variable to the browser executable to enable PDF printing"))
end

"""`true` when a browser capable of printing PDFs is available."""
pdf_available(; explicit = nothing) =
    try
        isfile(find_chrome(; explicit = explicit))
    catch
        false
    end

"""
    html_to_pdf(html_path, pdf_path; chrome, landscape, extra_args, timeout) -> String

Print an HTML file to PDF with a headless browser. Throws when the browser is
missing or when the print produced no file, so a broken PDF can never be mistaken
for a successful run.
"""
function html_to_pdf(html_path::AbstractString, pdf_path::AbstractString;
    chrome::Union{Nothing,AbstractString} = nothing, landscape::Bool = false,
    extra_args::Vector{String} = String[], timeout::Real = 180.0)
    isfile(html_path) || throw(ArgumentError("printout not found: $html_path"))
    exe = find_chrome(; explicit = chrome)
    mkpath(dirname(pdf_path))
    isfile(pdf_path) && rm(pdf_path)
    url = string("file:///", replace(abspath(html_path), '\\' => '/'))
    args = String["--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
        "--allow-file-access-from-files", "--no-pdf-header-footer",
        "--run-all-compositor-stages-before-draw", "--virtual-time-budget=20000",
        string("--print-to-pdf=", abspath(pdf_path))]
    landscape && push!(args, "--landscape")
    append!(args, extra_args)
    push!(args, url)
    log = ""
    try
        log = read(Cmd([exe, args...]), String)
    catch err
        log = err isa ProcessFailedException ? sprint(showerror, err) : string(err)
    end
    if !isfile(pdf_path) || filesize(pdf_path) == 0
        throw(ErrorException(string("the PDF printer produced no output for ", html_path,
            "\nprinter: ", exe, "\n", log)))
    end
    return pdf_path
end

"""Print an HTML string to PDF in one step (writes the HTML next to the PDF)."""
function print_html_to_pdf(html::AbstractString, pdf_path::AbstractString;
    html_path::Union{Nothing,AbstractString} = nothing, kwargs...)
    html_path = something(html_path, replace(pdf_path, r"\.pdf$"i => ".html"))
    write_printout(html_path, html)
    return html_to_pdf(html_path, pdf_path; kwargs...)
end

"""Human-readable summary of the PDF printing capability of this machine."""
function pdf_capability()
    return try
        Dict{Symbol,Any}(:available => true, :browser => find_chrome(), :source => :found)
    catch err
        Dict{Symbol,Any}(:available => false, :browser => nothing, :source => :missing,
            :hint => string(err))
    end
end

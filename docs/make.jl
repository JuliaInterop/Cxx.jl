using Documenter, Cxx

makedocs(
    modules = [Cxx],
    clean = false,
    format = :html,
    sitename = "Cxx.jl",
    authors = "Keno Fischer",
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
        "Examples" => "examples.md",
        "Implementation" => "implementation.md",
        "C++ REPL" => "repl.md",
    ],
)

deploydocs(
    repo = "github.com/Keno/Cxx.jl.git",
    target = "build",
    julia = "0.6",
    deps = nothing,
    make = nothing,
)

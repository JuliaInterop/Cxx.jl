using Documenter, Cxx

makedocs(
    modules = [Cxx],
    clean = false,
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
    repo = "github.com/JuliaInterop/Cxx.jl.git",
)

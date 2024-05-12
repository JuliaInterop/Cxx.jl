module JLLEnvs

using Pkg
using Pkg.Artifacts
using Pkg.Artifacts: load_artifacts_toml, artifact_path
using Base.BinaryPlatforms

function __triplet(p::Platform)
    for k in keys(p.tags)
        if k != "arch" && k != "os" && k != "libc"
            delete!(p.tags, k)
        end
    end
    t = triplet(p)
    if os(p) == "macos" && arch(p) == "x86_64"
        t *= "14"
    elseif os(p) == "macos" && arch(p) == "aarch64"
        t *= "20"
    end
    return t
end

include("env.jl")

function __init__()
    merge!(SHARDS, load_artifacts_toml(joinpath(@__DIR__, "..", "..", "Artifacts.toml")))
end

include("version.jl")
include("target.jl")
include("type.jl")
include("system.jl")

function get_default_args(is_cxx=false, version=GCC_MIN_VER)
    env = get_default_env(; is_cxx, version)
    args = ["-isystem" * dir for dir in get_system_includes(env)]
    push!(args, "--target=$(target(env.platform))")
    return args
end

end # module

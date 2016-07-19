if VERSION < v"0.5-dev"
    error("Cxx requires Julia 0.5")
end

#in case we have specified the path to the julia installation
#that contains the headers etc, use that
BASE_JULIA_HOME = get(ENV, "BASE_JULIA_HOME", JULIA_HOME)

#write a simple include file with that path
println("writing path.jl file")
s = """
const BASE_JULIA_HOME=\"$BASE_JULIA_HOME\"
export BASE_JULIA_HOME
"""
f = open(joinpath(dirname(@__FILE__),"path.jl"), "w")
write(f, s)
close(f)

println("Tuning for julia installation at: ",BASE_JULIA_HOME)

llvm_config_path = joinpath(BASE_JULIA_HOME,"..","tools","llvm-config")
if isfile(llvm_config_path)
    ENV["LLVM_CONFIG"] = llvm_config_path
    delete!(ENV,"LLVM_VER")
else
    ENV["LLVM_CONFIG"] = joinpath(dirname(@__FILE__),"fake-llvm-config.jl")
    ENV["LLVM_VER"] = Base.libllvm_version
    ENV["JULIA_BINARY_BUILD"] = "1"
    ENV["PATH"] = string(JULIA_HOME,":",ENV["PATH"])
end
run(`make -j$(Sys.CPU_CORES) -f BuildBootstrap.Makefile BASE_JULIA_HOME=$BASE_JULIA_HOME`)

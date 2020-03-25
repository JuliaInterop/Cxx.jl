using Libdl

# in case we have specified the path to the julia installation
# that contains the headers etc, use that
BASE_JULIA_BIN = get(ENV, "BASE_JULIA_BIN", Sys.BINDIR) |> normpath
BASE_JULIA_SRC = get(ENV, "BASE_JULIA_SRC", joinpath(BASE_JULIA_BIN, "..", "..")) |> normpath

# write a simple include file with that path
println("writing path.jl file")
s = """
const BASE_JULIA_BIN=$(sprint(show, BASE_JULIA_BIN))
export BASE_JULIA_BIN

const BASE_JULIA_SRC=$(sprint(show, BASE_JULIA_SRC))
export BASE_JULIA_SRC
"""

println("Tuning for julia installation at $BASE_JULIA_BIN with sources possibly at $BASE_JULIA_SRC")

# try to autodetect C++ ABI in use
llvm_path = Sys.iswindows() ? "LLVM" :
            Sys.isapple() ? "libLLVM" : "libLLVM-$(Base.libllvm_version)"
llvm_lib_path = Libdl.dlpath(llvm_path)
old_cxx_abi = findfirst("_ZN4llvm3sys16getProcessTripleEv", String(open(read, llvm_lib_path))) !== nothing
old_cxx_abi && (ENV["OLD_CXX_ABI"] = "1")

llvm_config_path = joinpath(BASE_JULIA_BIN, "..", "tools", "llvm-config")
if isfile(llvm_config_path)
    @info "Building julia source build"
    ENV["LLVM_CONFIG"] = llvm_config_path
    ENV["LLVM_VER"] = string(Base.libllvm_version)
    make = Sys.isbsd() && !Sys.isapple() ? `gmake` : `make`
    run(`$make all -j$(Sys.CPU_THREADS) -f BuildBootstrap.Makefile BASE_JULIA_BIN=$BASE_JULIA_BIN BASE_JULIA_SRC=$BASE_JULIA_SRC`)
    s = s * "\n const IS_BINARYBUILD = false"
else
    @info "Building julia binary build"
    Sys.iswindows() && @warn "Windows support is still experimental!"
    ENV["LLVM_VER"] = string(Base.libllvm_version)
    ENV["PATH"] = string(BASE_JULIA_BIN,":",ENV["PATH"])
    include("build_libcxxffi.jl")
    s = s * "\n const IS_BINARYBUILD = true"
end

f = open(joinpath(dirname(@__FILE__),"path.jl"), "w")
write(f, s)
close(f)

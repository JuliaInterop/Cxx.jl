# First verify that this Version of julia is compatible
# with this package.

if !isdefined(first(methods(sin)),:isstaged)
    error("This version of julia does not have staged functions.\n
           CXX.jl will not work!")
end

if !isdefined(Base,:llvmcall)
    error("This version of julia does not support llvmcall.\n
           CXX.jl will not work!")
end

println("Tuning for julia installation at: ",JULIA_HOME)

run(`make -f BuildBootstrap.Makefile JULIA_HOME=$JULIA_HOME`)
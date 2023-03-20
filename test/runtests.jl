using Test

# #316 test that import Cxx works without also using Cxx
# this test must run before `using Cxx` is executed
import Cxx
using Cxx.CxxCore
@testset "import without using Cxx (#316)" begin
    __current_compiler__ = Cxx.Cxx.__default_compiler__
    @test Cxx.@cxx_str("#include <iostream>")
    @test Cxx.@icxx_str("316;") == 316
    Cxx.@cxxm "int f316()" 316
end
include("cxxstr.jl")
include("icxxstr.jl")
include("ctest.jl")
include("misc.jl")
#include("show.jl")
#include("llvmtest.jl")
#include("llvmgraph.jl")
include("std.jl")
include("rtti.jl")

using Cxx
using Test
using Cxx.ClangCompiler
using Cxx: CxxCompiler, lookup

@testset "lookup" begin
    test_cpp = joinpath(@__DIR__, "test.cpp")
    cc = CxxCompiler(test_cpp)
    decl = lookup(Symbol("foo13::bar::A"), cc)
    @test ClangCompiler.name(decl) == "A"
end

using Cxx
using Test
using Cxx.ClangCompiler
using Cxx: CxxCompiler, CxxBaseType, CxxTemplate, CxxEnum, CxxPtr, CxxRef, CxxValue
using Cxx: lookup, cppdecl

@testset "lookup" begin
    test_cpp = joinpath(@__DIR__, "test.cpp")
    cc = CxxCompiler(test_cpp)
    decl = lookup(Symbol("foo13::bar::A"), cc)
    @test ClangCompiler.name(decl) == "A"

    decl = Cxx.lookup(Symbol("is_void<char>"), cc)
    @test ClangCompiler.name(decl) == "is_void"

    decl = Cxx.lookup(Symbol("is_void<char>::value"), cc)
    @test ClangCompiler.name(decl) == "value"
end

@testset "cppdecl" begin
    test_cpp = joinpath(@__DIR__, "test.cpp")
    cc = CxxCompiler(test_cpp)

    # CxxBaseType
    decl = cppdecl(CxxBaseType{Symbol("foo13::bar::A")}, cc)
    @test ClangCompiler.name(decl) == "A"

    # CxxEnum
    decl = cppdecl(CxxEnum{Symbol("foo13::bar::A"), Int}, cc)
    @test ClangCompiler.name(decl) == "A"

    # CxxTemplate
    decl = cppdecl(CxxTemplate{CxxBaseType{Symbol("std::vector<int>")}, Tuple{Cint}}, cc)
    @test ClangCompiler.name(decl) == "vector"

    # CxxPtr
    decl = cppdecl(CxxPtr{CxxBaseType{Symbol("foo13::bar::A")}, (true,true,true)}, cc)
    @test ClangCompiler.name(decl) == "A"

    # CxxRef
    decl = cppdecl(CxxRef{CxxBaseType{Symbol("foo13::bar::A")}, (true,true,true)}, cc)
    @test ClangCompiler.name(decl) == "A"
end





# @testset "template specialization" begin
#     test_cpp = joinpath(@__DIR__, "test.cpp")
#     cc = CxxCompiler(test_cpp)
#     decl = lookup(Symbol("foo13::bar::A"), cc)
#     @test ClangCompiler.name(decl) == "A"
# end

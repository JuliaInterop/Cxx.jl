using Cxx
using Test
using Cxx.ClangCompiler
using Cxx: CxxBaseType, CxxTemplate, CxxEnum, CxxPtr, CxxRef, CxxValue, CxxQualType
using Cxx: lookup, cppdecl, cpptype

@testset "lookup" begin
    test_cpp = joinpath(@__DIR__, "test.cpp")
    cc = CxxCompiler(test_cpp)
    decl = lookup(Symbol("foo13::bar::A"), cc)
    @test ClangCompiler.name(decl) == "A"

    decl = Cxx.lookup(Symbol("is_void<char>"), cc)
    @test ClangCompiler.name(decl) == "is_void"

    decl = Cxx.lookup(Symbol("is_void<char>::value"), cc)
    @test ClangCompiler.name(decl) == "value"

    dispose(cc)
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

    dispose(cc)
end

@testset "cpptype" begin
    test_cpp = joinpath(@__DIR__, "test.cpp")
    cc = CxxCompiler(test_cpp)

    # CxxBaseType
    t = cpptype(CxxBaseType{Symbol("foo13::bar::baz")}, cc)
    @test ClangCompiler.get_string(t) == "enum foo13::bar::baz"

    # CxxEnum
    t = cpptype(CxxEnum{Symbol("foo13::bar::baz"), Int}, cc)
    @test ClangCompiler.get_string(t) == "enum foo13::bar::baz"

    # CxxTemplate
    t = cpptype(CxxTemplate{CxxBaseType{Symbol("std::vector<int>")}, Tuple{Cint}}, cc)
    @test ClangCompiler.get_string(t) == "class std::vector<>"

    # CxxQualType
    t = cpptype(CxxQualType{CxxBaseType{Symbol("size_t")}, (true, false, false)}, cc)
    @test ClangCompiler.get_string(t) == "const size_t"

    # CxxPtr
    t = cpptype(CxxPtr{CxxBaseType{Symbol("size_t")}, (false, true, false)}, cc)
    @test ClangCompiler.get_string(t) == "size_t *volatile"

    # CxxRef
    t = cpptype(CxxRef{CxxBaseType{Symbol("size_t")}, (false, false, true)}, cc)
    @test ClangCompiler.get_string(t) == "__restrict size_t &"

    dispose(cc)
end

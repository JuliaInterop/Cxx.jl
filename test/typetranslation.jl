using Cxx
using Test
using Cxx: CxxBaseType, CxxTemplate, CxxEnum, CxxPtr, CxxRef, CxxValue, CxxQualType
using Cxx: lookup, name, cppdecl, cpptype, juliatype

@testset "lookup" begin
    test_cpp = joinpath(@__DIR__, "test.cpp")
    cc = CxxCompiler(test_cpp)
    decl = lookup(Symbol("foo13::bar::A"), cc)
    @test name(decl) == "A"

    decl = lookup(Symbol("is_void<char>"), cc)
    @test name(decl) == "is_void"

    decl = lookup(Symbol("is_void<char>::value"), cc)
    @test name(decl) == "value"

    dispose(cc)
end

@testset "cppdecl" begin
    test_cpp = joinpath(@__DIR__, "test.cpp")
    cc = CxxCompiler(test_cpp)

    # CxxBaseType
    decl = cppdecl(CxxBaseType{Symbol("PrintTest")}, cc)
    @test name(decl) == "PrintTest"

    # CxxEnum
    decl = cppdecl(CxxEnum{Symbol("foo13::bar::baz"), Int}, cc)
    @test name(decl) == "baz"

    # CxxTemplate
    decl = cppdecl(CxxTemplate{CxxBaseType{Symbol("std::vector<int>")}, Tuple{Cint}}, cc)
    @test name(decl) == "vector"

    # CxxPtr
    decl = cppdecl(CxxPtr{CxxBaseType{Symbol("foo13::bar::A")}, (true,true,true)}, cc)
    @test name(decl) == "A"

    # CxxRef
    decl = cppdecl(CxxRef{CxxBaseType{Symbol("foo13::bar::A")}, (true,true,true)}, cc)
    @test name(decl) == "A"

    dispose(cc)
end

@testset "cpptype" begin
    test_cpp = joinpath(@__DIR__, "test.cpp")
    cc = CxxCompiler(test_cpp)

    # CxxBaseType
    t = cpptype(CxxBaseType{Symbol("PrintTest")}, cc)
    @test name(t) == "class PrintTest"

    # CxxEnum
    t = cpptype(CxxEnum{Symbol("foo13::bar::baz"), Int}, cc)
    @test name(t) == "enum foo13::bar::baz"

    # CxxTemplate
    t = cpptype(CxxTemplate{CxxBaseType{Symbol("std::vector<int>")}, Tuple{Cint}}, cc)
    @test name(t) == "class std::vector<>"

    # CxxQualType
    t = cpptype(CxxQualType{CxxBaseType{Symbol("size_t")}, (true, false, false)}, cc)
    @test name(t) == "const size_t"

    # CxxPtr
    t = cpptype(CxxPtr{CxxBaseType{Symbol("size_t")}, (false, true, false)}, cc)
    @test name(t) == "size_t *volatile"

    # CxxRef
    t = cpptype(CxxRef{CxxBaseType{Symbol("size_t")}, (false, false, true)}, cc)
    @test name(t) == "size_t &__restrict"

    # macros
    t = cpptype(pcpp"size_t", cc)
    @test name(t) == "size_t *"

    t = cpptype(cpcpp"size_t", cc)
    @test name(t) == "const size_t *"

    t = cpptype(rcpp"size_t", cc)
    @test name(t) == "size_t &"

    dispose(cc)
end

@testset "juliatype" begin
    test_cpp = joinpath(@__DIR__, "test.cpp")
    cc = CxxCompiler(test_cpp)

    # CxxBaseType
    t = cpptype(CxxBaseType{Symbol("PrintTest")}, cc) # FIXME: add support for "class PrintTest" in ClangCompiler.jl
    @test juliatype(t) == CxxBaseType{Symbol("class PrintTest")}

    # CxxEnum
    t = CxxEnum{Symbol("enum foo13::bar::baz"), Int}
    @test juliatype(cpptype(t, cc)) == t

    # CxxTemplate
    t = cpptype(CxxTemplate{CxxBaseType{Symbol("std::vector<int>")}, Tuple{Cint}}, cc)
    @test juliatype(t) == CxxBaseType{Symbol("class std::vector<>")}

    # CxxQualType
    t = cpptype(CxxQualType{CxxBaseType{Symbol("size_t")}, (true, false, false)}, cc)
    @test juliatype(t) == CxxQualType{Csize_t, (true, false, false)}

    # CxxPtr
    t = cpptype(CxxPtr{CxxBaseType{Symbol("size_t")}, (false, true, false)}, cc)
    @test juliatype(t) == CxxPtr{Csize_t, (false, true, false)}

    # CxxRef
    t = cpptype(CxxRef{CxxBaseType{Symbol("size_t")}, (false, false, true)}, cc)
    @test juliatype(t) == CxxRef{Csize_t, (false, false, true)}

    dispose(cc)
end

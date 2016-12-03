using Cxx
using Base.Test

@testset "StdString" begin
    cxx_str = icxx"""std::string("Hello, World!");"""
    jl_str = "Hello, World!"

    @test convert(String, cxx_str) == jl_str
    @test icxx"""$(convert(cxxt"std::string", jl_str)) == $cxx_str;"""

    @test String(cxx_str) == jl_str
end

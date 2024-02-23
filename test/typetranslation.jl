using Cxx.CxxCore
using Test

@testset "cxxt" begin
    @test cxxt"int" == Int32

    cxx"""
    template <typename T>
    struct foo_cxxt {
    T x;
    };
    """
    @test cxxt"foo_cxxt<int>" <: CppValue{CxxQualType{CppTemplate{CppBaseType{:foo_cxxt},Tuple{Int32}},(false,false,false)}}
end

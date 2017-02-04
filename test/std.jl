using Cxx
using Base.Test

@testset "StdString" begin
    cxx_str = icxx"""std::string("Hello, World!");"""
    jl_str = "Hello, World!"

    @test convert(String, cxx_str) == jl_str
    @test icxx"""$(convert(cxxt"std::string", jl_str)) == $cxx_str;"""

    @test String(cxx_str) == jl_str
end

@testset "StdVector" begin
    cxx_int_v = icxx"std::vector<int32_t>{2, 4, 6, 8, 10, 12, 14};";
    jl_int_v = [2, 4, 6, 8, 10, 12, 14]

    cxx_str_v = icxx"""std::vector<std::string>{"foo", "bar", "Hello, World!"};""";
    jl_str_v = ["foo", "bar", "Hello, World!"]

    cxx_bool_v = icxx"std::vector<bool>{true, true, false, true};";
    jl_bool_v = [true, true, false, true]

    @testset "StdVector basic methods" begin
        @test length(cxx_int_v) == length(jl_int_v)
        @test size(cxx_int_v) == size(jl_int_v)
        @test eltype(cxx_int_v) == Int32
        @test indices(cxx_int_v) == (0:6,)
        @test linearindices(cxx_int_v) == 0:6
        @test try (checkbounds(cxx_int_v, -1); false) catch e typeof(e) == BoundsError end
        @test (checkbounds(cxx_int_v, 0); true)
        @test (checkbounds(cxx_int_v, 6); true)
        @test try (checkbounds(cxx_int_v, 7); false) catch e typeof(e) == BoundsError end
        @test pointer(cxx_int_v) == icxx"$cxx_int_v.data();"
        @test pointer(cxx_int_v, 2) == icxx"$cxx_int_v.data() + 2;"

        @test pointer(cxx_str_v) == icxx"$cxx_str_v.data();"
        @test pointer(cxx_str_v, 2) == icxx"$cxx_str_v.data() + 2;"
        # @test eltype(cxx_str_v) == cxxt"std::string"

        @test eltype(cxx_bool_v) == Bool
    end


    @testset "StdVector iteration" begin
        @test begin
            s = zero(cxx_int_v[0])
            for x in cxx_int_v s += x end
            s == sum(jl_int_v)
        end
    end

    @testset "StdVector getindex and setindex!" begin
        cxx_int_v2 = icxx"std::vector<int32_t> v($cxx_int_v); v;";
        @test cxx_int_v2[3] == 8
        @test typeof(cxx_int_v[3]) == Int32
        @test begin
            cxx_int_v2[3] = 42
            cxx_int_v2[3] == 42
        end
        @test begin
            cxx_int_v2[5] = cxx_int_v2[4]
            cxx_int_v2[5] == 10
        end

        cxx_str_v2 = icxx"std::vector<std::string> v($cxx_str_v); v;";
        @test String(cxx_str_v2[1]) == "bar"
        @test typeof(cxx_str_v2[1]) == cxxt"std::string&"
        @test begin
            cxx_str_v2[1] = "baz"
            String(cxx_str_v2[1]) == "baz"
        end
        @test begin
            cxx_str_v2[0] = cxx_str_v2[2]
            String(cxx_str_v2[0]) == "Hello, World!"
        end

        cxx_bool_v2 = icxx"std::vector<bool> v($cxx_bool_v); v;";
        @test cxx_bool_v2[1] == true
        @test typeof(cxx_bool_v2[1]) == Bool
        @test begin
            cxx_bool_v2[1] = false
            cxx_bool_v2[1] == false
        end
    end

    @testset "StdVector wrappers basic methods" begin
        w_cxx_int_v = unsafe_wrap(DenseArray, cxx_int_v)
        w_cxx_str_v = unsafe_wrap(DenseArray, cxx_str_v)
        w_cxx_bool_v = unsafe_wrap(DenseArray, cxx_bool_v)

        @test typeof(w_cxx_int_v) == CxxStd.WrappedCppPrimArray{Int32}
        @test typeof(w_cxx_str_v) <: CxxStd.WrappedCppObjArray
        @test typeof(w_cxx_bool_v) <: CxxStd.WrappedCppBoolVector

        @test length(w_cxx_int_v) == length(jl_int_v)
        @test size(w_cxx_int_v) == size(jl_int_v)
        @test Base.linearindexing(w_cxx_int_v) == Base.LinearFast()
        @test pointer(w_cxx_int_v) == icxx"$cxx_int_v.data();"
        @test pointer(w_cxx_int_v, 3) == icxx"$cxx_int_v.data() + 2;"
        @test w_cxx_int_v == jl_int_v

        @test length(w_cxx_str_v) == length(jl_str_v)
        @test size(w_cxx_str_v) == size(jl_str_v)
        @test Base.linearindexing(w_cxx_str_v) == Base.LinearFast()
        @test pointer(w_cxx_str_v) == icxx"$cxx_str_v.data();"
        @test pointer(w_cxx_str_v, 3) == icxx"$cxx_str_v.data() + 2;"
        @test String.(w_cxx_str_v) == jl_str_v

        @test length(w_cxx_bool_v) == length(jl_bool_v)
        @test size(w_cxx_bool_v) == size(jl_bool_v)
        @test Base.linearindexing(w_cxx_bool_v) == Base.LinearFast()
        @test w_cxx_bool_v == jl_bool_v
    end

    @testset "StdVector wrappers getindex and setindex!" begin
        cxx_int_v2 = icxx"std::vector<int32_t> v($cxx_int_v); v;";
        w_cxx_int_v2 = unsafe_wrap(DenseArray, cxx_int_v2)
        @test w_cxx_int_v2[4] == 8
        @test typeof(w_cxx_int_v2[4]) == Int32
        @test begin
            w_cxx_int_v2[4] = 42
            w_cxx_int_v2[4] == 42
        end
        @test begin
            w_cxx_int_v2[6] = w_cxx_int_v2[5]
            w_cxx_int_v2[6] == 10
        end

        cxx_str_v2 = icxx"std::vector<std::string> v($cxx_str_v); v;";
        w_cxx_str_v2 = unsafe_wrap(DenseArray, cxx_str_v2)
        @test String(w_cxx_str_v2[2]) == "bar"
        @test typeof(w_cxx_str_v2[2]) == cxxt"std::string&"
        @test begin
            w_cxx_str_v2[2] = "baz"
            String(w_cxx_str_v2[2]) == "baz"
        end
        @test begin
            w_cxx_str_v2[1] = w_cxx_str_v2[3]
            String(w_cxx_str_v2[1]) == "Hello, World!"
        end

        cxx_bool_v2 = icxx"std::vector<bool> v($cxx_bool_v); v;";
        w_cxx_bool_v2 = unsafe_wrap(DenseArray, cxx_bool_v2)
        @test w_cxx_bool_v2[2] == true
        @test typeof(w_cxx_bool_v2[2]) == Bool
        @test begin
            w_cxx_bool_v2[2] = false
            w_cxx_bool_v2[2] == false
        end
    end

    @testset "StdVector copy! and convert" begin
        @test begin
            dest = zeros(Int32, 7)
            copy!(dest, cxx_int_v)
            dest == jl_int_v
        end

        @test begin
            dest = icxx"""std::vector<int32_t> v(7); v;"""
            copy!(dest, jl_int_v)
            icxx"""$dest == $cxx_int_v;"""
        end

        @test begin
            dest = [41, 0, 0, 0, 42]
            copy!(dest, 2, cxx_int_v, 3, 3)
            dest == [41, 8, 10, 12, 42]
        end

        @test begin
            dest = icxx"""std::vector<int32_t>{41, 0, 0, 0, 42};"""
            copy!(dest, 1, jl_int_v, 4, 3)
            icxx"""$dest == std::vector<int32_t>{41, 8, 10, 12, 42};"""
        end

        @test convert(Vector{Int32}, cxx_int_v) == jl_int_v


        @test begin
            dest = Vector{String}(3)
            copy!(dest, cxx_str_v)
            dest == jl_str_v
        end

        @test begin
            dest = icxx"""std::vector<std::string>{"", "", ""};"""
            copy!(dest, jl_str_v);
            icxx"""$dest == std::vector<std::string>{"foo", "bar", "Hello, World!"};"""
        end

        @test convert(Vector{String}, cxx_str_v) == jl_str_v


        @test begin
            dest = zeros(Bool, 4)
            copy!(dest, cxx_bool_v)
            dest == jl_bool_v
        end

        @test begin
            dest = icxx"""std::vector<bool> v(4); v;"""
            copy!(dest, jl_bool_v);
            icxx"""$dest == $cxx_bool_v;"""
        end

        @test convert(Vector{Bool}, cxx_bool_v) == jl_bool_v
    end
end

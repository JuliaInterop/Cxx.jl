using Cxx
using Base.Test


@testset "RTTI" begin
    rtti_enabled = parse(Int, get(ENV, "JULIA_CXX_RTTI", "0")) > 0

    !rtti_enabled &&info(STDERR, "Error messages like \"cannot use typeid with -fno-rtti\" are expected and Ok.")

    @test begin
        ptr = try
            Ptr{Void}(icxx"typeid(int).name();")
        catch e
            C_NULL
        end

        if rtti_enabled
            ptr != C_NULL
        else
            ptr == C_NULL
        end
    end
end

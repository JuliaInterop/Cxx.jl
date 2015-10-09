import Base: bytestring

cxxparse("""
#include <string>
#include <vector>
#include <stdexcept>
""")

const StdString = cxxt"std::string"
typealias StdVector{T} cxxt"std::vector<$T>"

bytestring(str::StdString) = bytestring((@cxx str->data()),@cxx str->size())

import Base: showerror
import Cxx: CppValue
for T in Cxx.CxxBuiltinTypes.types
    @eval @exception function showerror(io::IO, e::$(T.parameters[1]))
        print(io, e)
    end
end
@exception function showerror(io::IO, e::cxxt"std::length_error&")
    try
        @show e
        print(io, bytestring(icxx"$e.what();"))
    catch w
        @show w
    end
end

Base.start(it::StdVector) = 0
Base.next(it::StdVector,i) = (it[i], i+1)
Base.done(it::StdVector,i) = i >= length(it)
Base.getindex(it::StdVector,i) = icxx"($(it))[$i];"
Base.length(it::StdVector) = icxx"$(it).size();"
Base.deleteat!(v::StdVector,idxs::UnitRange) =
    icxx"$(v).erase($(v).begin()+$(first(idxs)),$(v).begin()+$(last(idxs)));"

function Base.filter!(f, a::StdVector)
    insrt = start(a)
    for curr = start(a):length(a)
        if f(a[curr])
            icxx"$a[$insrt] = $a[$curr];"
            insrt += 1
        end
    end
    if insrt < length(a)
        deleteat!(a, insrt:length(a))
    end
    return a
end

function Base.show{T}(io::IO,
    ptr::Union{cxxt"std::shared_ptr<$T>",cxxt"std::shared_ptr<$T>&"})
    println(io,"shared_ptr<",typename(T),"> @",convert(UInt,icxx"(void*)$ptr.get();"))
end

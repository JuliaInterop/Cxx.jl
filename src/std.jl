import Base: String, unsafe_string
using Base.@propagate_inbounds

cxxparse("""
#include <string>
#include <vector>
#include <stdexcept>
#include <memory>
#include <map>
""")

const StdString = cxxt"std::string"
const StdStringR = cxxt"std::string&"
@compat const StdVector{T} = Union{cxxt"std::vector<$T>",cxxt"std::vector<$T>&"}
@compat const StdMap{K,V} = cxxt"std::map<$K,$V>"
if isdefined(Core, :UnionAll)
include_string("""
const GenericStdMap =
  Cxx.CppValue{Cxx.CxxQualType{Cxx.CppTemplate{
    Cxx.CppBaseType{Symbol("std::map")},Stuff},
    (false, false, false)},N} where N where Stuff
""")
else
const GenericStdMap = StdMap
end

unsafe_string(str::Union{StdString,StdStringR}) = unsafe_string((@cxx str->data()),@cxx str->size())
String(str::Union{StdString,StdStringR}) = unsafe_string(str)
Base.convert(::Type{String}, x::Union{StdString,StdStringR}) = String(x)
Base.convert(::Type{StdString}, x::AbstractString) = icxx"std::string s($(pointer(x)), $(sizeof(x))); s;"

import Base: showerror
import Cxx: CppValue
if !isdefined(Core, :UnionAll)
    uniontypes(U) = U.types
else
    const uniontypes = Base.uniontypes
end

for T in uniontypes(Cxx.CxxBuiltinTypes)
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

Base.start(v::StdVector) = 0
Base.next(v::StdVector,i) = (v[i], i+1)
Base.done(v::StdVector,i) = i >= length(v)
Base.length(v::StdVector) = Int(icxx"$(v).size();")
Base.size(v::StdVector) = (length(v),)
Base.eltype{T}(v::StdVector{T}) = T
@inline Base.indices(v::StdVector) = (0:(length(v) - 1),)
@inline Base.linearindices(v::StdVector) = indices(v)[1]
@inline function Base.checkbounds(v::StdVector, I...)
    Base.checkbounds_indices(Bool, indices(v), I) || Base.throw_boundserror(v, I)
    nothing
end

@inline Base.getindex(v::StdVector,i) = (@boundscheck checkbounds(v, i); icxx"($(v))[$i];")
@inline Base.getindex{T<:Cxx.CxxBuiltinTs}(v::StdVector{T}, i) = (@boundscheck checkbounds(v, i); icxx"$T x = ($(v))[$i]; x;")


@inline Base.setindex!{T}(v::StdVector{T}, val::T, i::Integer) =
    (@boundscheck checkbounds(v, i); icxx"($(v))[$i] = $val; void();")

@inline Base.setindex!(v::StdVector, val::Union{Cxx.CppValue, Cxx.CppRef}, i::Integer) =
    (@boundscheck checkbounds(v, i); icxx"($(v))[$i] = $val; void();")

@propagate_inbounds _setindex_conv!{T}(v::StdVector{T}, val, i::Integer) =
    setindex!(v, convert(T, val), i)

@propagate_inbounds _setindex_conv!{T<:Cxx.CxxQualType}(v::StdVector{T}, val, i::Integer) =
    setindex!(v, convert(Cxx.CppValue{T}, val), i)

@propagate_inbounds Base.setindex!(v::StdVector, val, i::Integer) =
    _setindex_conv!(v, val, i)


Base.deleteat!(v::StdVector,idxs::UnitRange) =
    icxx"$(v).erase($(v).begin()+$(first(idxs)),$(v).begin()+$(last(idxs)));"
Base.push!(v::StdVector,i) = icxx"$v.push_back($i);"
Base.resize!(v::StdVector, n) = icxx"$v.resize($n);"

Base.start(map::GenericStdMap) = icxx"$map.begin();"
function Base.next(map::GenericStdMap,i)
    v = icxx"$i->first;" => icxx"$i->second;"
    icxx"++$i;"
    (v,i)
end
Base.done(map::GenericStdMap,i) = icxx"$i == $map.end();"
Base.length(map::GenericStdMap) = icxx"$map.size();"
Base.eltype{K,V}(::Type{StdMap{K,V}}) = Pair{K,V}

Base.pointer(v::StdVector) = pointer(v, 0)
Base.pointer(v::StdVector, i::Integer) = icxx"&$v[$i];"

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

const CxxBuiltinVecTs = Union{Float32,Float64,Int16,Int32,Int64,Int8,UInt16,UInt32,UInt64,UInt8}

Base.unsafe_wrap{T}(::Type{DenseArray}, v::StdVector{T}) = WrappedCppObjArray(pointer(v), length(v))
Base.unsafe_wrap{T<:CxxBuiltinVecTs}(::Type{DenseArray}, v::StdVector{T}) = WrappedCppPrimArray(pointer(v), length(v))
Base.unsafe_wrap(::Type{DenseArray}, v::StdVector{Bool}) = WrappedCppBoolVector(icxx"std::vector<bool> &vr = $v; vr;", length(v))

Base.copy!(dest::StdVector, src) = copy!(unsafe_wrap(DenseArray, dest), src)
Base.copy!(dest::AbstractArray, src::StdVector) = copy!(dest, unsafe_wrap(DenseArray, src))
# Base.copy!(dest::StdVector, src::StdVector) = ...

Base.copy!(dest::StdVector, doffs::Integer, src, soffs::Integer, n::Integer) =
    copy!(unsafe_wrap(DenseArray, dest), doffs + 1, src, soffs, n)
Base.copy!(dest::AbstractArray, doffs::Integer, src::StdVector, soffs::Integer, n::Integer) =
    copy!(dest, doffs, unsafe_wrap(DenseArray, src), soffs + 1, n)
# Base.copy!(dest::StdVector, doffs::Integer, src::StdVector, soffs::Integer, n::Integer) = ...

Base.convert{CT<:AbstractArray}(::Type{CT}, v::StdVector) = convert(CT, unsafe_wrap(DenseArray, v))

function Base.convert{T}(::Type{cxxt"std::vector<$T>"}, x::AbstractArray)
    n = length(linearindices(x))
    result = icxx"std::vector<$T> v($n); v;"
    copy!(result, x)
    result
end


@compat abstract type WrappedCppDenseValues{T} <: DenseArray{T,1} end

Base.size(A::WrappedCppDenseValues) = (length(A),)
@compat Base.IndexStyle(::WrappedCppDenseValues) = IndexLinear()


@propagate_inbounds Base.setindex!{T}(A::WrappedCppDenseValues{T}, val, i::Integer) =
    setindex!(A, convert(T, val), i)

@propagate_inbounds Base.setindex!{T<:Cxx.CxxQualType}(A::WrappedCppDenseValues{T}, val, i::Integer) =
    setindex!(A, convert(Cxx.CppValue{T}, val), i)


immutable WrappedCppObjArray{T, CVR} <: WrappedCppDenseValues{T}
    ptr::Cxx.CppPtr{T,CVR}
    len::Int
end

Base.pointer(A::WrappedCppObjArray) = A.ptr
Base.pointer{T}(A::WrappedCppObjArray{T}, i::Integer) = icxx"&$(A.ptr)[$(i - 1)];"
Base.length(A::WrappedCppObjArray) = A.len

@inline Base.getindex(A::WrappedCppObjArray, i::Integer) =
    (@boundscheck checkbounds(A, i); icxx"($(A.ptr))[$(i - 1)];")

@inline Base.setindex!{T}(A::WrappedCppObjArray{T}, val::T, i::Integer) =
    (@boundscheck checkbounds(A, i); icxx"($(A.ptr))[$(i - 1)] = $val; void();")
@inline Base.setindex!(A::WrappedCppObjArray, val::Union{Cxx.CppValue, Cxx.CppRef}, i::Integer) =
    (@boundscheck checkbounds(A, i); icxx"($(A.ptr))[$(i - 1)] = $val; void();")


immutable WrappedCppPrimArray{T<:CxxBuiltinVecTs} <: WrappedCppDenseValues{T}
    ptr::Ptr{T}
    len::Int
end

Base.pointer(A::WrappedCppPrimArray) = A.ptr
Base.pointer{T}(A::WrappedCppPrimArray{T}, i::Integer) = A.ptr + sizeof(T) * (i - 1)
Base.length(A::WrappedCppPrimArray) = A.len

@inline Base.getindex(A::WrappedCppPrimArray, i::Integer) =
    (@boundscheck checkbounds(A, i); unsafe_load(A.ptr, i))

@inline Base.setindex!{T}(A::WrappedCppPrimArray{T}, val::T, i::Integer) =
    (@boundscheck checkbounds(A, i); unsafe_store!(A.ptr, val, i) )


immutable WrappedCppBoolVector <: WrappedCppDenseValues{Bool}
    vref::cxxt"std::vector<bool>&"
    len::Int
end

Base.length(A::WrappedCppBoolVector) = A.len

@inline Base.getindex(A::WrappedCppBoolVector, i::Integer) =
    (@boundscheck checkbounds(A, i); icxx"bool x = ($(A.vref))[$(i - 1)]; x;")

@inline Base.setindex!(A::WrappedCppBoolVector, val::Bool, i::Integer) =
    (@boundscheck checkbounds(A, i); icxx"($(A.vref))[$(i - 1)] = $val; void();")


function Base.show{T}(io::IO,
    ptr::Union{cxxt"std::shared_ptr<$T>",cxxt"std::shared_ptr<$T>&"})
    println(io,"shared_ptr<",typename(T),"> @",convert(UInt,icxx"(void*)$ptr.get();"))
end

#Cxx.cpptype{T<:Union{ASCIIString,UTF8String}}(C,::Type{T}) = Cxx.cpptype(C,Ptr{UInt8})

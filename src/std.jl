import Base: String, unsafe_string
using Base: @propagate_inbounds, uniontypes

cxxparse("""
#include <string>
#include <vector>
#include <stdexcept>
#include <memory>
#include <map>
""")

const StdString = cxxt"std::string"
const StdStringR = cxxt"std::string&"
const StdVector{T} = Union{cxxt"std::vector<$T>",cxxt"std::vector<$T>&"}
const StdMap{K,V} = cxxt"std::map<$K,$V>"
const GenericStdMap =
  CppValue{CxxQualType{CppTemplate{
    CppBaseType{Symbol("std::map")},Stuff},
    (false, false, false)},N} where N where Stuff

unsafe_string(str::Union{StdString,StdStringR}) = unsafe_string((@cxx str->data()),@cxx str->size())
String(str::Union{StdString,StdStringR}) = unsafe_string(str)
Base.convert(::Type{String}, x::Union{StdString,StdStringR}) = String(x)
Base.convert(::Type{StdString}, x::AbstractString) = icxx"std::string s($(pointer(x)), $(sizeof(x))); s;"

import Base: showerror

for T in uniontypes(CxxBuiltinTypes)
    @eval @exception function showerror(io::IO, e::$(T.parameters[1]))
        print(io, e)
    end
end
@exception function showerror(io::IO, e::cxxt"std::length_error&")
    try
        @show e
        print(io, unsafe_string(icxx"$e.what();"))
    catch w
        @show w
    end
end

Base.iterate(v::StdVector, i = 0) = i >= length(v) ? nothing : (v[i], i+1)
Base.length(v::StdVector) = Int(icxx"$(v).size();")
Base.firstindex(v::StdVector) = 0
Base.lastindex(v::StdVector) = length(v) - 1
Base.size(v::StdVector) = (length(v),)
Base.eachindex(v::StdVector) = firstindex(v):lastindex(v)
Base.eltype(v::StdVector{T}) where {T} = T
@inline Base.axes(v::StdVector) = (0:(length(v) - 1),)
@inline function Base.checkbounds(v::StdVector, I...)
    Base.checkbounds_indices(Bool, axes(v), I) || Base.throw_boundserror(v, I)
    nothing
end

@inline Base.getindex(v::StdVector,i) = (@boundscheck checkbounds(v, i); icxx"($(v))[$i];")
@inline Base.getindex(v::StdVector{T}, i) where {T<:CxxBuiltinTypes} = (@boundscheck checkbounds(v, i); icxx"$T x = ($(v))[$i]; x;")


@inline Base.setindex!(v::StdVector{T}, val::T, i::Integer) where {T} =
    (@boundscheck checkbounds(v, i); icxx"($(v))[$i] = $val; void();")

@inline Base.setindex!(v::StdVector, val::Union{CppValue, CppRef}, i::Integer) =
    (@boundscheck checkbounds(v, i); icxx"($(v))[$i] = $val; void();")

@propagate_inbounds _setindex_conv!(v::StdVector{T}, val, i::Integer) where {T} =
    setindex!(v, convert(T, val), i)

@propagate_inbounds _setindex_conv!(v::StdVector{T}, val, i::Integer) where {T<:CxxQualType} =
    setindex!(v, convert(CppValue{T}, val), i)

@propagate_inbounds Base.setindex!(v::StdVector, val, i::Integer) =
    _setindex_conv!(v, val, i)


Base.deleteat!(v::StdVector,idxs::UnitRange) =
    icxx"$(v).erase($(v).begin()+$(first(idxs)),$(v).begin()+$(last(idxs)));"
Base.push!(v::StdVector,i) = icxx"$v.push_back($i);"
Base.resize!(v::StdVector, n) = icxx"$v.resize($n);"

function Base.iterate(map::GenericStdMap, i = icxx"$map.begin();")
    if icxx"$i == $map.end();"
        return nothing
    end
    v = icxx"$i->first;" => icxx"$i->second;"
    icxx"++$i;"
    (v,i)
end
Base.length(map::GenericStdMap) = icxx"$map.size();"
Base.eltype(::Type{StdMap{K,V}}) where {K,V} = Pair{K,V}

Base.pointer(v::StdVector) = pointer(v, 0)
Base.pointer(v::StdVector, i::Integer) = icxx"&$v[$i];"

function Base.filter!(f, a::StdVector)
    insrt = start(a)
    for curr = eachindex(a)
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

Base.unsafe_wrap(::Type{DenseArray}, v::StdVector{T}) where {T} = WrappedCppObjArray(pointer(v), length(v))
Base.unsafe_wrap(::Type{DenseArray}, v::StdVector{T}) where {T<:CxxBuiltinVecTs} = WrappedCppPrimArray(pointer(v), length(v))
Base.unsafe_wrap(::Type{DenseArray}, v::StdVector{Bool}) = WrappedCppBoolVector(icxx"std::vector<bool> &vr = $v; vr;", length(v))

Base.copy!(dest::StdVector, src) = copy!(unsafe_wrap(DenseArray, dest), src)
Base.copy!(dest::AbstractArray, src::StdVector) = copy!(dest, unsafe_wrap(DenseArray, src))
# Base.copy!(dest::StdVector, src::StdVector) = ...

Base.copy!(dest::StdVector, doffs::Integer, src, soffs::Integer, n::Integer) =
    copy!(unsafe_wrap(DenseArray, dest), doffs + 1, src, soffs, n)
Base.copy!(dest::AbstractArray, doffs::Integer, src::StdVector, soffs::Integer, n::Integer) =
    copy!(dest, doffs, unsafe_wrap(DenseArray, src), soffs + 1, n)
# Base.copy!(dest::StdVector, doffs::Integer, src::StdVector, soffs::Integer, n::Integer) = ...

Base.convert(::Type{CT}, v::StdVector) where {CT<:AbstractArray} = convert(CT, unsafe_wrap(DenseArray, v))

function Base.convert(::Type{cxxt"std::vector<$T>"}, x::AbstractArray) where T
    n = length(linearindices(x))
    result = icxx"std::vector<$T> v($n); v;"
    copy!(result, x)
    result
end


abstract type WrappedCppDenseValues{T} <: DenseArray{T,1} end

Base.size(A::WrappedCppDenseValues) = (length(A),)
Base.IndexStyle(::WrappedCppDenseValues) = IndexLinear()


@propagate_inbounds Base.setindex!(A::WrappedCppDenseValues{T}, val, i::Integer) where {T} =
    setindex!(A, convert(T, val), i)

@propagate_inbounds Base.setindex!(A::WrappedCppDenseValues{T}, val, i::Integer) where {T<:CxxQualType} =
    setindex!(A, convert(CppValue{T}, val), i)


struct WrappedCppObjArray{T, CVR} <: WrappedCppDenseValues{T}
    ptr::CppPtr{T,CVR}
    len::Int
end

Base.pointer(A::WrappedCppObjArray) = A.ptr
Base.pointer(A::WrappedCppObjArray{T}, i::Integer) where {T} = icxx"&$(A.ptr)[$(i - 1)];"
Base.length(A::WrappedCppObjArray) = A.len

@inline Base.getindex(A::WrappedCppObjArray, i::Integer) =
    (@boundscheck checkbounds(A, i); icxx"($(A.ptr))[$(i - 1)];")

@inline Base.setindex!(A::WrappedCppObjArray{T}, val::T, i::Integer) where {T} =
    (@boundscheck checkbounds(A, i); icxx"($(A.ptr))[$(i - 1)] = $val; void();")
@inline Base.setindex!(A::WrappedCppObjArray, val::Union{CppValue, CppRef}, i::Integer) =
    (@boundscheck checkbounds(A, i); icxx"($(A.ptr))[$(i - 1)] = $val; void();")


struct WrappedCppPrimArray{T<:CxxBuiltinVecTs} <: WrappedCppDenseValues{T}
    ptr::Ptr{T}
    len::Int
end

Base.pointer(A::WrappedCppPrimArray) = A.ptr
Base.pointer(A::WrappedCppPrimArray{T}, i::Integer) where {T} = A.ptr + sizeof(T) * (i - 1)
Base.length(A::WrappedCppPrimArray) = A.len

@inline Base.getindex(A::WrappedCppPrimArray, i::Integer) =
    (@boundscheck checkbounds(A, i); unsafe_load(A.ptr, i))

@inline Base.setindex!(A::WrappedCppPrimArray{T}, val::T, i::Integer) where {T} =
    (@boundscheck checkbounds(A, i); unsafe_store!(A.ptr, val, i) )


struct WrappedCppBoolVector <: WrappedCppDenseValues{Bool}
    vref::cxxt"std::vector<bool>&"
    len::Int
end

Base.length(A::WrappedCppBoolVector) = A.len

@inline Base.getindex(A::WrappedCppBoolVector, i::Integer) =
    (@boundscheck checkbounds(A, i); icxx"bool x = ($(A.vref))[$(i - 1)]; x;")

@inline Base.setindex!(A::WrappedCppBoolVector, val::Bool, i::Integer) =
    (@boundscheck checkbounds(A, i); icxx"($(A.vref))[$(i - 1)] = $val; void();")


function Base.show(io::IO,
    ptr::Union{cxxt"std::shared_ptr<$T>",cxxt"std::shared_ptr<$T>&"}) where T
    println(io,"shared_ptr<",typename(T),"> @",convert(UInt,icxx"(void*)$ptr.get();"))
end

#Cxx.cpptype{T<:Union{ASCIIString,UTF8String}}(C,::Type{T}) = Cxx.cpptype(C,Ptr{UInt8})

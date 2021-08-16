# Representing C++ values
#
# Since we can't always keep C++ values in C++ land and to make C++ values
# convenient to work with, we need to come up with a way to represent them in
# Julia. In particular, we would like to be able to represent both C++ types
# has well as having a way to represent runtime instances of C++ values.
#
# One way to do this would be to have a
#
# struct CppObject{ClangType}
#   data::Ptr{Cvoid}
# end
#
# where ClangType is simply a pointer to Clang's in memory representation. This
# has the advantage that working with this type does not introduce a separate
# name lookup whenever it is used. However, it also has the disadvantage that
# it is not stable across serialization and not very meaningful.
#
# Instead, what we do here is build up a hierarchy of Julia types that represent
# the C++ type hierarchy. This has the advantage that clang does not necessarily
# need to be in memory to work with these object, as well as allowing these
# types to be stable across serialization. However, it comes with the disadvantage
# of having to perform a name lookup to get the clang::Type* pointer back.
#
# In the future, we may want to have a cache that maps types to clang types,
# or go with a different model entirely, but that decision should be based
# on experience how these behave in practice.
#
# A note on CVR qualifiers
#
# Though I had hoped to avoid it, correctly representing template parameters
# requires tracking CVR (const, volatile, restrict) qualifiers on types. The way
# this is currently implemented is as an extra CVR type parameter on
# applicable julia types. This type parameter should be a tuple of Bools
# indicating whether the qualifier is present in CVR order.
#

export @cpcpp_str, @pcpp_str, @vcpp_str, @rcpp_str

"""
    struct CxxBaseType{S} <: Any
Represents a base C++ type, i.e. a type that is not a pointer, a reference or a template.

`S` is a symbol of the types fully qualified name, e.g. `int`, `char` or `foo::bar`.

This is usually used directly as a type, rather than as an instance.
"""
struct CxxBaseType{S} end

"""
    struct CxxTemplate{T,TARGS} <: Any
A templated type where `T` is the [`CxxBaseType`](@ref) to be templated and
`TARGS` is a tuple of template arguments.
"""
struct CxxTemplate{T,TARGS} end

"""
    struct CxxQualType{T,CVR} <: Any
A base type with extra CVR qualifications.
"""
struct CxxQualType{T,CVR} end

"""
    struct CxxArrayType{T} <: Any
The abstract notion of a C++ array type.
"""
struct CxxArrayType{T} end

"""
    mutable struct CxxValue{T,N} <: Any
The equivalent of a C++ on-stack value.

`T` is a [`CxxBaseType`](@ref) or a [`CxxTemplate`](@ref).

See note on CVR above.
"""
mutable struct CxxValue{T,N}
    data::NTuple{N,UInt8}
    CxxValue{T,N}(data::NTuple{N,UInt8}) where {T,N} = new{T,N}(data)
    CxxValue{T,N}() where {T,N} = new{T,N}()
end

# All types that are recgonized as builtins
const CxxBuiltinTypes = Union{Type{Bool},Type{UInt8},Type{Int8},Type{UInt16},Type{Int16},
                              Type{Int32},Type{UInt32},Type{Int64},Type{UInt64},
                              Type{Float32},Type{Float64}}

const CxxBuiltinTs = Union{Bool,UInt8,Int8,UInt16,Int16,Int32,UInt32,Int64,UInt64,Float32,
                           Float64}

"""
    primitive type CxxRef{T,CVR}
The equivalent of a C++ reference. `T` can be any valid C++ type other than [`CxxRef`](@ref).

See note on CVR above and note on bitstype below.
"""
primitive type CxxRef{T,CVR} 8 * sizeof(Ptr{Cvoid}) end

CxxRef{T,CVR}(p::Ptr{Cvoid}) where {T,CVR} = reinterpret(CxxRef{T,CVR}, p)

Base.cconvert(::Type{Ptr{Cvoid}}, p::CxxRef) = reinterpret(Ptr{Cvoid}, p)

function Base.unsafe_load(p::CxxRef{T}) where {T<:Union{CxxBuiltinTs,Ptr}}
    return unsafe_load(reinterpret(Ptr{T}, p))
end

Base.convert(::Type{T}, p::CxxRef{T}) where {T<:CxxBuiltinTs} = unsafe_load(p)


# TODO: Maybe use Ptr{CxxValue} and Ptr{CxxFunc} instead?
# struct CxxPtr{T,CVR}
#     ptr::Ptr{Cvoid}
# end
# Make CxxPtr and Ptr the same in the julia calling convention
"""
    primitive type CxxPtr{T,CVR}
The equivalent of a C++ pointer.

`T` can be a [`CxxValue`](@ref), [`CxxPtr`](@ref), etc. depending on the pointed to type,
but is never a [`CxxBaseType`](@ref) or [`CxxTemplate`](@ref) directly.
"""
primitive type CxxPtr{T,CVR} 8 * sizeof(Ptr{Cvoid}) end

CxxPtr{T,CVR}(p::Ptr{Cvoid}) where {T,CVR} = reinterpret(CxxPtr{T,CVR}, p)

Base.cconvert(::Type{Ptr{Cvoid}}, p::CxxPtr) = reinterpret(Ptr{Cvoid}, p)
Base.convert(::Type{Int}, p::CxxPtr) = convert(Int, reinterpret(Ptr{Cvoid}, p))
Base.convert(::Type{UInt}, p::CxxPtr) = convert(UInt, reinterpret(Ptr{Cvoid}, p))
Base.convert(::Type{Ptr{Cvoid}}, p::CxxPtr) = reinterpret(Ptr{Cvoid}, p)

Base.:(==)(p1::CxxPtr, p2::Ptr) = convert(Ptr{Cvoid}, p1) == p2
Base.:(==)(p1::Ptr, p2::CxxPtr) = p1 == convert(Ptr{Cvoid}, p2)

Base.unsafe_load(p::CxxRef{T}) where {T<:CxxPtr} = unsafe_load(reinterpret(Ptr{T}, p))

# Provides a common type for CxxFptr and CxxMFptr
struct CxxFunc{RT,ARGT} end

"""
    struct CxxFptr{F} <: Any
The equivalent of a C++ ARGT (*foo)(ARGT...)
"""
struct CxxFptr{F}
    ptr::Ptr{Cvoid}
end

"""
    struct CxxMFptr{BASE,FPTR} <: Any
A pointer to a C++ member function. Refer to the Itanium ABI for its meaning.
"""
struct CxxMFptr{BASE,FPTR}
    ptr::UInt64
    adj::UInt64
end

"""
    struct CxxEnum{S,T} <: Any
Represent a C/C++ Enum.

`S` is a symbol, representing the fully qualified name of the enum, `T` the underlying type.
"""
struct CxxEnum{S,T}
    val::T
end

Base.:(==)(p1::CxxEnum, p2::Integer) = p1.val == p2
Base.:(==)(p1::Integer, p2::CxxEnum) = p1 == p2.val

Base.unsafe_load(p::CxxRef{T}) where {T<:CxxEnum} = unsafe_load(reinterpret(Ptr{Cint}, p))


"""
    struct CxxLambda{N} <: Any
Representa a C++ Lambda.

As lambdas are not nameable, we need to number them and record the corresponding type.
"""
struct CxxLambda{N}
    captureData::Ptr{Cvoid}
end

const LAMBDA_TYPES = Vector{QualType}()
const LAMBDA_INDEXES = Dict{QualType,Int}()
function lambda_for_type(T)
    if !haskey(LAMBDA_INDEXES, T)
        push!(LAMBDA_TYPES, T)
        LAMBDA_INDEXES[T] = length(LAMBDA_TYPES)
    end
    return CxxLambda{LAMBDA_INDEXES[T]}
end
type_for_lambda(::Type{CxxLambda{N}}) where {N} = LAMBDA_TYPES[N]

# Convenience string literals for the above - part of the user facing
# functionality. Due to the complexity of the representation hierarchy,
# it is convenient to have these string macros, for the common case where
# a user simply wants to refer to a type but does not care about CVR qualifiers
# etc.

const NullCVR = (false, false, false)  # non-const, non-volatile, non-restrict

macro pcpp_str(s, args...)
    CxxPtr{
        CxxQualType{
            CxxBaseType{Symbol(s)},
            NullCVR,  # points to a non-const, non-volatile, non-restrict C++ type
        },
        NullCVR,  # a non-const, non-volatile, non-restrict pointer
    }
end

macro cpcpp_str(s, args...)
    CxxPtr{
        CxxQualType{
            CxxBaseType{Symbol(s)},
            (true, false, false),  # points to a const, non-volatile, non-restrict C++ type
        },
        NullCVR,  # a non-const, non-volatile, non-restrict pointer
    }
end

macro rcpp_str(s, args...)
    CxxRef{
        CxxBaseType{Symbol(s)},
        NullCVR,
    } # a reference to a non-const, non-volatile, non-volatile, non-restrict C++ type
end

macro vcpp_str(s, args...)
    CxxValue{
        CxxQualType{
            CxxBaseType{Symbol(s)},
            NullCVR,  # value of a non-const, non-volatile, non-volatile, non-restrict C++ type
        },
    }
end

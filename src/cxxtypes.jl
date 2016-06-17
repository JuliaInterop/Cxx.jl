# Clang's QualType. A QualType is a pointer to a clang class object that
# contains the information about the actual type, as well as storing the CVR
# qualifiers in the unused bits of the pointer. Here we just treat QualType
# as an opaque struct with one pointer-sized member.
immutable QualType
    ptr::Ptr{Void}
end
Base.convert(::Type{Ptr{Void}}, QT::QualType) = QT.ptr

# All types that are recgonized as builtins
const CxxBuiltinTypes = Union{Type{Bool},
    Type{UInt8},  Type{Int8},    Type{UInt16}, Type{Int16},
    Type{Int32},  Type{UInt32},  Type{Int64},  Type{UInt64},
    Type{Float32}, Type{Float64}}
const CxxBuiltinTs = Union{Bool, UInt8, Int8, UInt16, Int16,
    Int32, UInt32, Int64, UInt64, Float32, Float64}

# # # Representing C++ values
#
# Since we can't always keep C++ values in C++ land and to make C++ values
# convenient to work with, we need to come up with a way to represent them in
# Julia. In particular, we would like to be able to represent both C++ types
# has well as having a way to represent runtime instances of C++ values.
#
# One way to do this would be to have a
#
# immutable CppObject{ClangType}
#   data::Ptr{Void}
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
# types to be stable across serialization. However, it comes with the
# it comes with the disadvantage of having to perform a name lookup to get
# the clang::Type* pointer back.
#
# In the future, we may want to have a cache that maps types to clang types,
# or go with a different model entirely, but that decision should be based
# on experience how these behave in practice.
#
# # A note on CVR qualifiers
#
# Though I had hoped to avoid it, correctly representing template parameters
# requires tracking CVR (const, volatile, restrict) qualifiers on types. The way
# this is currently implemented is as an extra CVR type parameter on
# applicable julia types. This type parameter should be a tuple of Bools
# indicating whether the qualifier is present in CVR order.
#

import Base: ==, cconvert
export @cpcpp_str, @pcpp_str, @vcpp_str, @rcpp_str

# Represents a base C++ type
# i.e. a type that is not a pointer, a reference or a template
# `s` is a symbol of the types fully qualified name, e.g. `int`, `char`
# or `foo::bar`. It is usually used directly as a type, rather than as an
# instance
immutable CppBaseType{s}
end

# A templated type where `T` is the CppBaseType to be templated and `targs`
# is a tuple of template arguments
immutable CppTemplate{T,targs}
end

# A base type with extra CVR qualifications
immutable CxxQualType{T,CVR}
end

# The abstract notion of a C++ array type
immutable CxxArrayType{T}
end

# The equivalent of a C++ on-stack value.
# T is a CppBaseType or a CppTemplate
# See note on CVR above
type CppValue{T,N}
    data::NTuple{N,UInt8}
    CppValue(data::NTuple{N,UInt8}) = new(data)
    CppValue() = new()
end

# The equivalent of a C++ reference
# T can be any valid C++ type other than CppRef
# See note on CVR above and note on bitstype below
bitstype 8*sizeof(Ptr{Void}) CppRef{T,CVR}
(::Type{CppRef{T,CVR}}){T,CVR}(p::Ptr{Void}) = reinterpret(CppRef{T,CVR}, p)

cconvert(::Type{Ptr{Void}},p::CppRef) = reinterpret(Ptr{Void}, p)
Base.unsafe_load{T<:Union{CxxBuiltinTs,Ptr}}(p::CppRef{T}) = unsafe_load(reinterpret(Ptr{T}, p))
Base.convert{T<:CxxBuiltinTs}(::Type{T},p::CppRef{T}) = unsafe_load(p)

# The equivalent of a C++ pointer.
# T can be a CppValue, CppPtr, etc. depending on the pointed to type,
# but is never a CppBaseType or CppTemplate directly
# TODO: Maybe use Ptr{CppValue} and Ptr{CppFunc} instead?
# immutable CppPtr{T,CVR}
#    ptr::Ptr{Void}
# end
# Make CppPtr and Ptr the same in the julia calling convention
bitstype 8*sizeof(Ptr{Void}) CppPtr{T,CVR}
(::Type{CppPtr{T,CVR}}){T,CVR}(p::Ptr{Void}) = reinterpret(CppPtr{T,CVR}, p)

cconvert(::Type{Ptr{Void}},p::CppPtr) = reinterpret(Ptr{Void}, p)
Base.convert(::Type{Int},p::CppPtr) = convert(Int,reinterpret(Ptr{Void}, p))
Base.convert(::Type{UInt},p::CppPtr) = convert(UInt,reinterpret(Ptr{Void}, p))
Base.convert(::Type{Ptr{Void}},p::CppPtr) = reinterpret(Ptr{Void}, p)

==(p1::CppPtr,p2::Ptr) = convert(Ptr{Void}, p1) == p2
==(p1::Ptr,p2::CppPtr) = p1 == convert(Ptr{Void}, p2)

Base.unsafe_load{T<:CppPtr}(p::CppRef{T}) = unsafe_load(reinterpret(Ptr{T}, p))

# Provides a common type for CppFptr and CppMFptr
immutable CppFunc{rt, argt}; end

# The equivalent of a C++ rt (*foo)(argt...)
immutable CppFptr{func}
    ptr::Ptr{Void}
end

# A pointer to a C++ member function.
# Refer to the Itanium ABI for its meaning
immutable CppMFptr{base, fptr}
    ptr::UInt64
    adj::UInt64
end

# Represent a C/C++ Enum. `S` is a symbol, representing the fully qualified name
# of the enum, `T` the underlying type
immutable CppEnum{S, T}
    val::T
end
==(p1::CppEnum,p2::Integer) = p1.val == p2
==(p1::Integer,p2::CppEnum) = p1 == p2.val

Base.unsafe_load{T<:CppEnum}(p::CppRef{T}) = unsafe_load(reinterpret(Ptr{Cint}, p))

# Representa a C++ Lambda. Since they are not nameable, we need to number them
# and record the corresponding type
immutable CppLambda{num}
    captureData::Ptr{Void}
end

const lambdaTypes = Vector{QualType}()
const lambdaIndxes = Dict{QualType,Int}()
function lambdaForType(T)
    if !haskey(lambdaIndxes, T)
        push!(lambdaTypes,T)
        lambdaIndxes[T] = length(lambdaTypes)
    end
    CppLambda{lambdaIndxes[T]}
end
typeForLambda{N}(::Type{CppLambda{N}}) = lambdaTypes[N]

# Convenience string literals for the above - part of the user facing
# functionality. Due to the complexity of the representation hierarchy,
# it is convenient to have these string macros, for the common case where
# a user simply wants to refer to a type but does not care about CVR qualifiers
# etc.

const NullCVR = (false,false,false)
simpleCppType(s) = CppBaseType{Symbol(s)}
simpleCppValue(s) = CxxQualType{simpleCppType(s),NullCVR}

macro pcpp_str(s,args...)
    CppPtr{simpleCppValue(s),NullCVR}
end

macro cpcpp_str(s,args...)
    CppPtr{CxxQualType{simpleCppType(s),(true,false,false)},NullCVR}
end

macro rcpp_str(s,args...)
    CppRef{simpleCppType(s),NullCVR}
end

macro vcpp_str(s,args...)
    CppValue{simpleCppValue(s)}
end

pcpp{T,N}(x::Type{CppValue{T,N}}) = CppPtr{T,NullCVR}
pcpp{T}(x::Type{CppValue{T}}) = CppPtr{T,NullCVR}

# Convert C++ QualType representation to julia representation
Base.convert(::Type{QualType},T::vcpp"clang::QualType") = QualType(reinterpret(Ptr{UInt8}, T.data))

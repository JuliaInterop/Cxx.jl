# Cxx - The Julia C++ FFI
#
# This file contains the julia parts of the C++ FFI.
# For bootstrapping purposes, there is a small C++ shim
# that we will call out to. In general I try to keep the amount of
# code duplication on the julia side to a minimum, even if this
# means having more code on the C++ side (the original version
# had a messy 4 step bootstrap process).
#
# There are two ways to access the main functionality, provided by
# this package. The first is using the @cxx macro, which puns on
# julia syntax to provide C++ compatibility.
# The three basic features provided by the @cxx macro are:
#
#   - Static function call
#       @cxx mynamespace::func(args...)
#   - Membercall (where m is a CppPtr, CppRef or CppValue)
#       @cxx m->foo(args...)
#   - Value Reference
#       @cxx foo
#
# Note that unary * inside a call, e.g. @cxx foo(*a) is treated as
# a (C++ side) dereference of a. Further, prefixing any value by `&`
# takes the address of a given value.
#
# Additionally, this package provides the cxx"" and icxx"" custom
# string literals for inputting C++ syntax directly. The two string
# literals are distinguished by the C++ level scope they represent.
# The cxx"" literal evaluates the contained C++ code at global scope
# and can be used for declaring namespaces, classes, functions, global
# variables, etc. while the icxx"" evaluates the contained code at
# function scope and should be used for calling C++ functions or
# performing computations.
#

# # # High Level Overview
#
# The two primary Julia features that enable Cxx.jl to work are
# llvmcall and staged functions.
#
# # llvmcall
#
# llvmcall allows the user to pass in an LLVM IR expression which
# will then be embedded directly in the julia expressions. This
# functionality could be considered the `inline assembly` equivalent
# for julia. However, all optimizations are fun after `llvmcall` IR
# has been inlined into the julia IR, all LLVM optimizations such
# as constant propagation, dead code elimination, etc. are applied
# across both sources of IR, eliminating a common inefficiency of
# using inline (machine code) assembly.
#
# The primary llvmcall syntax is as follows (reminiscent of the
# ccall syntax):
#
# llvmcall("""%3 = add i32 %1, %0
#              ret i32 %3         """, Int32, (Int32, Int32), x, y)
#
#          \________________________/ \_____/ \____________/ \___/
#               Input LLVM IR            |     Argument Tuple  |
#                                    Return Type            Argument
#
# Behind the scenes, LLVM will take the IR, wrap it in an LLVM function
# with the given return type and argument types. To call this function,
# julia does the same argument translation it would for a ccall (e.g.
# unboxing x and y if necessary). Afterwards, the resulting call instruction
# is inlined.
#
# In this package, however, we use the second form of llvmcall, which differs
# from the first inthat the IR argument is not a string, but a Ptr{Void}. In
# this case, julia will skip the wrapping and proceed straight to argument
# translation and inlining.
#
# The underlying idea is thus simple: have Clang generate some
# LLVM IR in memory and then use the second form of LLVM IR to actually call it.
#
# # The @cxx macro
#
# The @cxx macro (see above for a description of its usage) thus needs to
# analyze the expression passed to it and generate an equivalent representation
# as a Clang AST, compile it and splice the resulting function pointer into
# llvmcall. In principle, this is quite straightforward. We simply need to
# match on the appropriate Julia AST and call the appropriate methods in Clang's
# Sema instance to generate the expression. And while it can be tricky to figure
# out what method to call, the real problem with this approach is types. Since
# C++ has compile time function overloading based on types, we need to know
# the argument types to call the function with, so we may select the correct to
# call. However, since @cxx is a macro, it operates on syntax only and,
# in particular, does not know the types of the expressions that form the
# parameters of the C++ function.
#
# The solution to this is to, as always in computing, add an extra layer of
# indirection.
#
# # Staged functions
#
# Staged function are similar to macros in that they return expressions rather
# than values. E.g.
#
# stagedfunction staged_t1(a,b)
#    if a == Int
#        return :(a+b)
#    else
#        return :(a*b)
#    end
# end
# @test staged_t1(1,2) == 3         # a is an Int
# @test staged_t1(1.0,0.5) == 0.5   # a is a Float64 (i.e. not an Int)
# @test staged_t1(1,0.5) == 1.5     # a is an Int
#
# Though the example above could have of course been done using regular
# dispatch, it does illustrate the usage of staged functions: Instead of
# being passed the values, the staged function is first given the type of
# the argument and, after some computation, returns an expression that
# represents the actual body of the function to run.
#
# An important feature of staged functions is that, though a staged function
# may be called with abstract types, if the staged function throws an error
# when passed abstract types, execution of the staged function is delayed until
# all argument types are known.
#
# # Implementation of the @cxx macro
#
# We can thus see how macros and staged functions fit together. First, @cxx
# does some syntax transformation to make sure all the required information
# is available to the staged function, e.g. 
#
# julia> :( @cxx foo(a,b) ) |> macroexpand
# :( cppcall( CppNNS{(:foo,)}(), a, b))
#
# Here cppcall is the staged function. Note that the name of the function to
# call was wrapped as the type parameter to a CppNNS type. This is important,
# because otherwise the staged function would not have access to the function
# name (since it's a symbol rather than a value). With this, cppcall will get
# the function name and the types of the two parameters, which is all it needs
# to build up the clang AST. The expression returned by the staged function
# will then simply be the `llvmcall` with the appropriate generated LLVM
# Function (in some cases we need to return some extra code, but those cases
# are discussed below)
#

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

# The equivalent of a C++ on-stack value.
# The representation of this is important and subject to change.
# The current implementation is inefficient, because it puts the object on the
# heap (ouch). A better implementation would use fixed-size arrays, ideally
# coupled with the necessary escape analysis to be able to put it on the stack
# in the common case. However, this will require (planned, but not yet
# implemented) improvements in core Julia.
#
# T is a CppBaseType or a CppTemplate
# See note on CVR above
immutable CppValue{T,CVR}
    data::Vector{Uint8}
end

# The equivalent of a C++ reference
# T can be any valid C++ type other than CppRef
# See note on CVR above
immutable CppRef{T,CVR}
    ptr::Ptr{Void}
end

cconvert(::Type{Ptr{Void}},p::CppRef) = p.ptr

# The equivalent of a C++ pointer.
# T can be a CppValue, CppPtr, etc. depending on the pointed to type,
# but is never a CppBaseType or CppTemplate directly
# TODO: Maybe use Ptr{CppValue} and Ptr{CppFunc} instead?
immutable CppPtr{T,CVR}
    ptr::Ptr{Void}
end

cconvert(::Type{Ptr{Void}},p::CppPtr) = p.ptr

==(p1::CppPtr,p2::Ptr) = p1.ptr == p2
==(p1::Ptr,p2::CppPtr) = p1 == p2.ptr

# Provides a common type for CppFptr and CppMFptr
immutable CppFunc{rt, argt}; end

# The equivalent of a C++ rt (*foo)(argt...)
immutable CppFptr{func}
    ptr::Ptr{Void}
end

# A pointer to a C++ member function.
# Refer to the Itanium ABI for its meaning
immutable CppMFptr{base, fptr}
    ptr::Uint64
    adj::Uint64
end

# Represent a C/C++ Enum. `T` is a symbol, representing the fully qualified name
# of the enum
immutable CppEnum{T}
    val::Int32
end

# Convenience string literals for the above - part of the user facing
# functionality. Due to the complexity of the representation hierarchy,
# it is convenient to have these string macros, for the common case where
# a user simply wants to refer to a type but does not care about CVR qualifiers
# etc.

const NullCVR = (false,false,false)
simpleCppType(s) = CppBaseType{symbol(s)}
simpleCppValue(s) = CppValue{simpleCppType(s),NullCVR}

macro pcpp_str(s,args...)
    CppPtr{simpleCppValue(s),NullCVR}
end

macro cpcpp_str(s,args...)
    CppPtr{CppValue{simpleCppType(s),(true,false,false)},NullCVR}
end

macro rcpp_str(s,args...)
    CppRef{simpleCppType(s),NullCVR}
end

macro vcpp_str(s,args...)
    simpleCppValue(s)
end

pcpp{T,CVR}(x::Type{CppValue{T,CVR}}) = CppPtr{x}


using Base.Meta

include("initialization.jl")
include("clangwrapper.jl")
include("typetranslation.jl")
include("codegen.jl")
include("cxxmacro.jl")
include("cxxstr.jl")
include("utils.jl")

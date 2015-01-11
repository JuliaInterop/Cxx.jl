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

# Force cast the data portion of a jl_value_t to the given C++
# type
immutable JLCppCast{T,JLT}
    data::JLT
    function call{T,JLT}(::Type{JLCppCast{T}},data::JLT)
        JLT.mutable ||
            error("Can only pass pointers to mutable values. " *
                  "To pass immutables, use an array instead.")
        new{T,JLT}(data)
    end
end

macro jpcpp_str(s,args...)
    JLCppCast{CppBaseType{symbol(s)}}
end

# Represents a forced cast form the value T
# (which may be any C++ compatible value)
# to the the C++ type To
immutable CppCast{T,To}
    from::T
end
CppCast{T,To}(from::T,::Type{To}) = CppCast{T,To}(from)
cast{T,To}(from::T,::Type{To}) = CppCast{T,To}(from)

# Represents a C++ Deference
immutable CppDeref{T}
    val::T
end
CppDeref{T}(val::T) = CppDeref{T}(val)

# Represent a C++ addrof (&foo)
immutable CppAddr{T}
    val::T
end
CppAddr{T}(val::T) = CppAddr{T}(val)


using Base.Meta

include("initialization.jl")
include("clangwrapper.jl")
include("typetranslation.jl")

# Main interface

immutable CppNNS{chain}; end

immutable CppExpr{T,targs}; end

# Checks the arguments to make sure we have concrete C++ compatible
# types in the signature. This is used both in cases where type inference
# cannot infer the appropriate argument types during staging (in which case
# the error here will cause it to fall back to runtime) as well as when the
# user has bad types (in which case you'll get a compile-time (but not stage-time)
# error.
function check_args(argt,f)
    for (i,t) in enumerate(argt)
        if isa(t,UnionType) || (isa(t,DataType) && t.abstract) ||
            (!(t <: CppPtr) && !(t <: CppRef) && !(t <: CppValue) && !(t <: CppCast) &&
                !(t <: CppFptr) && !(t <: CppMFptr) && !(t <: CppEnum) &&
                !(t <: CppDeref) && !(t <: CppAddr) && !(t <: Ptr) &&
                !(t <: JLCppCast) &&
                !in(t,[Bool, Uint8, Int32, Uint32, Int64, Uint64, Float32, Float64]))
            error("Got bad type information while compiling $f (got $t for argument $i)")
        end
    end
end

julia_to_llvm(x::ANY) = pcpp"llvm::Type"(ccall(:julia_type_to_llvm,Ptr{Void},(Any,),x))
# Various clang conversions (bootstrap definitions)

# @cxx llvm::dyn_cast{vcpp"clang::ClassTemplateDecl"}
cxxtmplt(p::pcpp"clang::Decl") = pcpp"clang::ClassTemplateDecl"(ccall((:cxxtmplt,libcxxffi),Ptr{Void},(Ptr{Void},),p))

const CxxBuiltinTypes = Union(Type{Bool},Type{Int64},Type{Int32},Type{Uint32},Type{Uint64},Type{Float32},Type{Float64})

stripmodifier{f}(cppfunc::Type{CppFptr{f}}) = cppfunc
stripmodifier{T,CVR}(p::Union(Type{CppPtr{T,CVR}},
    Type{CppRef{T,CVR}}, Type{CppValue{T,CVR}})) = p
stripmodifier{s}(p::Type{CppEnum{s}}) = p
stripmodifier{T,To}(p::Type{CppCast{T,To}}) = T
stripmodifier{T}(p::Type{CppDeref{T}}) = T
stripmodifier{T}(p::Type{CppAddr{T}}) = T
stripmodifier{base,fptr}(p::Type{CppMFptr{base,fptr}}) = p
stripmodifier{T}(p::Type{Ptr{T}}) = Ptr{T}
stripmodifier(p::CxxBuiltinTypes) = p
stripmodifier{T,JLT}(p::Type{JLCppCast{T,JLT}}) = p

resolvemodifier{T,CVR}(p::Union(Type{CppPtr{T,CVR}}, Type{CppRef{T,CVR}},
    Type{CppValue{T,CVR}}), e::pcpp"clang::Expr") = e
resolvemodifier(p::CxxBuiltinTypes, e::pcpp"clang::Expr") = e
resolvemodifier{T}(p::Type{Ptr{T}}, e::pcpp"clang::Expr") = e
resolvemodifier{s}(p::Type{CppEnum{s}}, e::pcpp"clang::Expr") = e
    #createCast(e,cpptype(p),CK_BitCast)
resolvemodifier{T,To}(p::Type{CppCast{T,To}}, e::pcpp"clang::Expr") =
    createCast(e,cpptype(To),CK_BitCast)
resolvemodifier{T}(p::Type{CppDeref{T}}, e::pcpp"clang::Expr") =
    createDerefExpr(e)
resolvemodifier{T}(p::Type{CppAddr{T}}, e::pcpp"clang::Expr") =
    CreateAddrOfExpr(e)
resolvemodifier{base,fptr}(p::Type{CppMFptr{base,fptr}}, e::pcpp"clang::Expr") = e
resolvemodifier{f}(cppfunc::Type{CppFptr{f}}, e::pcpp"clang::Expr") = e
resolvemodifier{T,JLT}(p::Type{JLCppCast{T,JLT}}, e::pcpp"clang::Expr") = e

resolvemodifier_llvm{T,To}(builder, t::Type{CppCast{T,To}}, v::pcpp"llvm::Value") =
    resolvemodifier_llvm(builder, t.parameters[1], ExtractValue(v,0))

resolvemodifier_llvm{T,CVR}(builder, t::Union(Type{CppPtr{T,CVR}}, Type{CppRef{T,CVR}}),
        v::pcpp"llvm::Value") = ExtractValue(v,0)

resolvemodifier_llvm{s}(builder, t::Type{CppEnum{s}}, v::pcpp"llvm::Value") = ExtractValue(v,0)

resolvemodifier_llvm{ptr}(builder, t::Type{Ptr{ptr}}, v::pcpp"llvm::Value") = v
resolvemodifier_llvm(builder, t::CxxBuiltinTypes, v::pcpp"llvm::Value") = v
#resolvemodifier_llvm(builder, t::Type{Uint8}, v::pcpp"llvm::Value") = v
function resolvemodifier_llvm{base,fptr}(builder, t::Type{CppMFptr{base,fptr}}, v::pcpp"llvm::Value")
    t = getLLVMStructType([julia_to_llvm(Uint64),julia_to_llvm(Uint64)])
    undef = getUndefValue(t)
    i1 = InsertValue(builder, undef, ExtractValue(v,0), 0)
    return InsertValue(builder, i1, ExtractValue(v,1), 1)
end

function resolvemodifier_llvm{s,targs}(builder, t::Type{CppValue{s,targs}}, v::pcpp"llvm::Value")
    @assert v != C_NULL
    ty = cpptype(t)
    if !isPointerType(getType(v))
        dump(v)
        error("Value is not of pointer type")
    end
    # Get the array
    array = CreateConstGEP1_32(builder,v,1)
    arrayp = CreateLoad(builder,CreateBitCast(builder,array,getPointerTo(getType(array))))
    # Get the data pointer
    data = CreateConstGEP1_32(builder,arrayp,1)
    dp = CreateBitCast(builder,data,getPointerTo(getPointerTo(tollvmty(ty))))
    # A pointer to the actual data
    CreateLoad(builder,dp)
end

resolvemodifier_llvm{f}(builder, t::Type{CppFptr{f}}, v::pcpp"llvm::Value") = ExtractValue(v,0)
resolvemodifier_llvm{f}(builder, t::Type{CppDeref{f}}, v::pcpp"llvm::Value") = resolvemodifier_llvm(builder,f,ExtractValue(v,0))
resolvemodifier_llvm{T}(builder, t::Type{CppAddr{T}}, v::pcpp"llvm::Value") =
    resolvemodifier_llvm(builder,T,ExtractValue(v,0))

function resolvemodifier_llvm{T,jlt}(builder, t::Type{JLCppCast{T,jlt}}, v::pcpp"llvm::Value")
    # Skip the type pointer to get to the actual data
    return CreateConstGEP1_32(builder,v,1)
end

# LLVM-level manipulation
function llvmargs(builder, f, argt)
    args = Array(pcpp"llvm::Value", length(argt))
    for i in 1:length(argt)
        t = argt[i]
        args[i] = pcpp"llvm::Value"(ccall((:get_nth_argument,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),f,i-1))
        @assert args[i] != C_NULL
        args[i] = resolvemodifier_llvm(builder, t, args[i])
        if args[i] == C_NULL
            error("Failed to process argument")
        end
    end
    args
end

# C++ expression manipulation
function buildargexprs(argt)
    callargs = pcpp"clang::Expr"[]
    pvds = pcpp"clang::ParmVarDecl"[]
    for i in 1:length(argt)
        #@show argt[i]
        t = argt[i]
        st = stripmodifier(t)
        argit = cpptype(st)
        st <: CppValue && (argit = pointerTo(argit))
        argpvd = CreateParmVarDecl(argit)
        push!(pvds, argpvd)
        expr = CreateDeclRefExpr(argpvd)
        st <: CppValue && (expr = createDerefExpr(expr))
        expr = resolvemodifier(t, expr)
        push!(callargs,expr)
    end
    callargs, pvds
end

function associateargs(builder,argt,args,pvds)
    for i = 1:length(args)
        t = stripmodifier(argt[i])
        argit = cpptype(t)
        if t <: CppValue
            argit = pointerTo(argit)
        end
        AssociateValue(pvds[i],argit,args[i])
    end
end


AssociateValue(d::pcpp"clang::ParmVarDecl", ty::QualType, V::pcpp"llvm::Value") = ccall((:AssociateValue,libcxxffi),Void,(Ptr{Void},Ptr{Void},Ptr{Void}),d,ty,V)

irbuilder() = pcpp"clang::CodeGen::CGBuilderTy"(ccall((:clang_get_builder,libcxxffi),Ptr{Void},()))

# # # Staging

# Main implementation.
# The two staged functions cppcall and cppcall_member below just change
# the thiscall flag depending on which ones is called.

setup_cpp_env(f::pcpp"llvm::Function") = ccall((:setup_cpp_env,libcxxffi),Ptr{Void},(Ptr{Void},),f)
function cleanup_cpp_env(state)
    ccall((:cleanup_cpp_env,libcxxffi),Void,(Ptr{Void},),state)
    RunGlobalConstructors()
end

dump(d::pcpp"clang::Decl") = ccall((:cdump,libcxxffi),Void,(Ptr{Void},),d)
dump(d::pcpp"clang::FunctionDecl") = ccall((:cdump,libcxxffi),Void,(Ptr{Void},),d)
dump(expr::pcpp"clang::Expr") = ccall((:exprdump,libcxxffi),Void,(Ptr{Void},),expr)
dump(t::pcpp"clang::Type") = ccall((:typedump,libcxxffi),Void,(Ptr{Void},),t)
dump(t::pcpp"llvm::Value") = ccall((:llvmdump,libcxxffi),Void,(Ptr{Void},),t)
dump(t::pcpp"llvm::Type") = ccall((:llvmtdump,libcxxffi),Void,(Ptr{Void},),t)

function build_me(T,name,pvds)
    # Create an expression to refer to the `this` parameter.
    ct = cpptype(T)
    if T <: CppValue
        # We want the this argument to be modified in place,
        # so we make a deref of the pointer to the
        # data.
        pct = pointerTo(ct)
        pvd = CreateParmVarDecl(pct)
        push!(pvds, pvd)
        dre = createDerefExpr(CreateDeclRefExpr(pvd))
    else
        pvd = CreateParmVarDecl(ct)
        push!(pvds, pvd)
        dre = CreateDeclRefExpr(pvd)
    end
    # Create an expression to reference the member
    me = BuildMemberReference(dre, ct, T <: CppPtr, name)
    if me == C_NULL
        error("Could not find member $name")
    end
    me
end

function emitRefExpr(expr, pvd = nothing, ct = nothing)
    rt = DeduceReturnType(expr)

    if isFunctionType(rt)
        error("Cannot reference function by value")
    end

    rett = juliatype(rt)

    @assert !(rett <: None)

    needsret = false
    if rett <: CppValue
        needsret = true
    end

    argt = Type[]
    needsret && push!(argt,Ptr{Uint8})
    (pvd != nothing) && push!(argt,ct)

    llvmrt = julia_to_llvm(rett)
    f = CreateFunction(llvmrt, map(julia_to_llvm,argt))
    state = setup_cpp_env(f)
    builder = irbuilder()

    args = llvmargs(builder, f, argt)

    (pvd != nothing) && associateargs(builder,[ct],args[needsret ? 1:1 : 2:2],[pvd])

    MarkDeclarationsReferencedInExpr(expr)
    if !needsret
        ret = EmitAnyExpr(expr)
    else
        EmitAnyExprToMem(expr, args[1], false)
    end

    createReturn(builder,f,ct !== nothing ? (ct,) : (),
        ct !== nothing ? [ct] : [],llvmrt,rett,rt,ret,state)
end

stagedfunction cxxmemref(expr, args...)
    this = args[1]
    check_args([this], expr)
    isaddrof = false
    if expr <: CppAddr
        expr = expr.parameters[1]
        isaddrof = true
    end
    pvds = pcpp"clang::ParmVarDecl"[]
    me = build_me(this, expr.parameters[1], pvds)
    isaddrof && (me = CreateAddrOfExpr(me))
    emitRefExpr(me, pvds[1], this)
end

function typeForNNS{nns}(T::Type{CppNNS{nns}})
    if length(nns) == 1 && (nns[1] <: CppPtr || nns[1] <: CppRef)
        return cpptype(nns[1])
    end
    typeForDecl(declfornns(T))
end

function declfornns{nns}(::Type{CppNNS{nns}},cxxscope=C_NULL)
    @assert isa(nns,Tuple)
    d = tu = translation_unit()
    for (i,n) in enumerate(nns)
        if !isa(n, Symbol)
            if n <: CppTemplate
                d = lookup_name((n.parameters[1],),C_NULL,d)
                cxxt = cxxtmplt(d)
                @assert cxxt != C_NULL
                arr = Any[]
                for arg in n.parameters[2]
                    if isa(arg,Type)
                        if arg <: CppNNS
                            push!(arr,typeForNNS(arg))
                        elseif arg <: CppPtr
                            push!(arr,cpptype(arg))
                        end
                    else
                        push!(arr,arg)
                    end
                end
                d = specialize_template_clang(cxxt,arr,cpptype)
                @assert d != C_NULL
                #(nnsbuilder != C_NULL) && ExtendNNSType(nnsbuilder,QualType(typeForDecl(d)))
            else
                @assert d == tu
                t = cpptype(n)
                dump(t)
                dump(getPointeeType(t))
                #(nnsbuilder != C_NULL) && ExtendNNSType(nnsbuilder,getPointeeType(t))
                d = getAsCXXRecordDecl(getPointeeType(t))
            end
        else
            d = lookup_name((n,), cxxscope, d, i != length(nns))
        end
        @assert d != C_NULL
    end
    d
end

function _cppcall(expr, thiscall, isnew, argt)
    check_args(argt, expr)

    pvds = pcpp"clang::ParmVarDecl"[]

    rslot = C_NULL

    rt = Void

    if thiscall
        @assert expr <: CppNNS
        fname = expr.parameters[1][1]
        @assert isa(fname,Symbol)

        me = build_me(argt[1],fname,pvds)

        # And now the expressions for all the arguments
        callargs, callpvds = buildargexprs(argt[2:end])
        append!(pvds, callpvds)
        # The actual call expression
        mce = BuildCallToMemberFunction(me,callargs)

        # At this point we're done with creating the clang AST,
        # and can move on to llvm code generation

        # First we need to get the return type of the C++ expression
        rt = getCalleeReturnType(pcpp"clang::CallExpr"(mce.ptr))
        rett = juliatype(rt)
        llvmrt = julia_to_llvm(rett)
        llvmargt = [argt...]

        issret = (rett != None) && rett <: CppValue

        if issret
            llvmargt = [Ptr{Uint8},llvmargt]
        end

        # Let's create an LLVM fuction
        f = CreateFunction(issret ? julia_to_llvm(Void) : llvmrt,
            map(julia_to_llvm,llvmargt))

        # Clang's code emitter needs some extra information about the function, so let's
        # initialize that as well
        state = setup_cpp_env(f)

        builder = irbuilder()

        # First compute the llvm arguments (unpacking them from their julia wrappers),
        # then associate them with the clang level variables
        args = llvmargs(builder, f, llvmargt)
        associateargs(builder,argt,issret ? args[2:end] : args,pvds)

        if issret
            rslot = CreateBitCast(builder,args[1],getPointerTo(toLLVM(rt)))
        end

        ret = pcpp"llvm::Value"(ccall((:emitcppmembercallexpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),mce.ptr,rslot))

        #if jlrslot != C_NULL && rslot != C_NULL && (length(args) == 0 || rslot != args[1])
        #    @cxx1 builder->CreateRet(pcpp"llvm::Value"(jlrslot.ptr))
        #else

        if rett <: CppValue
            ret = C_NULL
        end

        #return createReturn(builder,f,argt,llvmrt,rt,ret,state)
    else
        targs = ()
        if expr <: CppTemplate
            targs = expr.args[2]
            expr = expr.args[1]
        end

        d = declfornns(expr)
        @assert d.ptr != C_NULL
        # If this is a typedef or something we'll try to get the primary one
        primary_decl = to_decl(primary_ctx(toctx(d)))
        if primary_decl != C_NULL
            d = primary_decl
        end
        # Let's see if we're constructing something. And, if so, let's
        # setup an array to accept the result
        cxxd = dcastCXXRecordDecl(d)
        fname = symbol(_decl_name(d))
        cxxt = cxxtmplt(d)
        if cxxd != C_NULL || cxxt != C_NULL
            if cxxd == C_NULL
                cxxd = specialize_template(cxxt,targs,cpptype)
            end

            # targs may have changed because the name is canonical
            # but the default targs may be substituted by typedefs
            targs = getTemplateParameters(cxxd)

            T = CppBaseType{fname}
            if !isempty(targs)
                T = CppTemplate{T,tuple(targs...)}
            end
            T = CppValue{T,NullCVR}
            juliart = T

            # The arguments to llvmcall will have an extra
            # argument for the return slot
            llvmargt = [argt...]
            if !isnew
                llvmargt = [Ptr{Uint8}, llvmargt]
            end

            # And now the expressions for all the arguments
            callargs, callpvds = buildargexprs(argt)
            append!(pvds, callpvds)

            rett = Void
            if isnew
                rett = CppPtr{CppValue{CppBaseType{fname},NullCVR},NullCVR}
            end
            llvmrt = julia_to_llvm(rett)

            # Let's create an LLVM fuction
            f = CreateFunction(llvmrt,
                map(julia_to_llvm,llvmargt))

            state = setup_cpp_env(f)
            builder = irbuilder()

            # First compute the llvm arguments (unpacking them from their julia wrappers),
            # then associate them with the clang level variables
            args = llvmargs(builder, f, llvmargt)
            associateargs(builder,argt,isnew ? args : args[2:end],pvds)

            if isnew
                nE = BuildCXXNewExpr(QualType(typeForDecl(cxxd)),callargs)
                if nE == C_NULL
                    error("Could not construct `new` expression")
                end
                MarkDeclarationsReferencedInExpr(nE)
                ret = EmitCXXNewExpr(nE)
            else
                ctce = BuildCXXTypeConstructExpr(QualType(typeForDecl(cxxd)),callargs)

                MarkDeclarationsReferencedInExpr(ctce)
                EmitAnyExprToMem(ctce,args[1],true)
                ret = Void

                CreateRetVoid(builder)

                cleanup_cpp_env(state)

                arguments = [:(pointer(r.data)), [:(args[$i]) for i = 1:length(argt)]]

                size = cxxsizeof(cxxd)
                rr = Expr(:block,
                    :( r = ($(T))(Array(Uint8,$size)) ),
                    Expr(:call,:llvmcall,f.ptr,Void,tuple(llvmargt...),arguments...),
                    :r)
                return rr
            end
        else
            myctx = getContext(d)
            while declKind(myctx) == LinkageSpec
                myctx = getParentContext(myctx)
            end
            @assert myctx != C_NULL
            dne = BuildDeclarationNameExpr(split(string(fname),"::")[end],myctx)

            return CallDNE(dne,argt)
        end
    end

    # Common return path for everything that's calling a normal function
    # (i.e. everything but constructors)
    createReturn(builder,f,argt,llvmargt,llvmrt,rett,rt,ret,state)
end

function CallDNE(dne,argt; argidxs = [1:length(argt)])
    if dne == C_NULL
        error("Could not resolve DNE")
    end

    pvds = pcpp"clang::ParmVarDecl"[]
    rslot = C_NULL

    # And now the expressions for all the arguments
    callargs, callpvds = buildargexprs(argt)
    append!(pvds, callpvds)

    ce = CreateCallExpr(dne,callargs)

    if ce == C_NULL
        error("Failed to create CallExpr")
    end

    # First we need to get the return type of the C++ expression
    rt = BuildDecltypeType(ce)
    rett = juliatype(rt)

    llvmargt = [argt...]

    issret = (rett != None) && rett <: CppValue

    if issret
        llvmargt = [Ptr{Uint8},llvmargt]
    end

    llvmrt = julia_to_llvm(rett)

    # Let's create an LLVM fuction
    f = CreateFunction(issret ? julia_to_llvm(Void) : llvmrt,
        map(julia_to_llvm,llvmargt))

    # Clang's code emitter needs some extra information about the function, so let's
    # initialize that as well
    state = setup_cpp_env(f)

    builder = irbuilder()

    args = llvmargs(builder, f, llvmargt)
    associateargs(builder,argt,issret ? args[2:end] : args,pvds)

    if issret
        rslot = CreateBitCast(builder,args[1],getPointerTo(toLLVM(rt)))
    end

    MarkDeclarationsReferencedInExpr(ce)
    ret = pcpp"llvm::Value"(ccall((:emitcallexpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),ce,rslot))

    if rett <: CppValue
        ret = C_NULL
    end

    createReturn(builder,f,argt,llvmargt,llvmrt,rett,rt,ret,state; argidxs = argidxs)
end

function createReturn(builder,f,argt,llvmargt,llvmrt,rett,rt,ret,state; argidxs = [1:length(argt)])
    argt = Type[argt...]

    jlrt = rett
    if ret == C_NULL
        jlrt = Void
        CreateRetVoid(builder)
    else
        #@show rett
        if rett == Void
            CreateRetVoid(builder)
        else
            if rett <: CppPtr || rett <: CppRef || rett <: CppEnum || rett <: CppFptr
                undef = getUndefValue(llvmrt)
                elty = getStructElementType(llvmrt,0)
                ret = CreateBitCast(builder,ret,elty)
                ret = InsertValue(builder, undef, ret, 0)
            elseif rett <: CppMFptr
                undef = getUndefValue(llvmrt)
                i1 = InsertValue(builder,undef,CreateBitCast(builder,
                        ExtractValue(ret,0),getStructElementType(llvmrt,0)),0)
                ret = InsertValue(builder,i1,CreateBitCast(builder,
                        ExtractValue(ret,1),getStructElementType(llvmrt,1)),1)
            end
            CreateRet(builder,ret)
        end
    end

    cleanup_cpp_env(state)

    args2 = Expr[]
    for (j,i) = enumerate(argidxs)
        if argt[j] <: JLCppCast
            push!(args2,:(args[$i].data))
            argt[j] = JLCppCast.parameters[1]
        else
            push!(args2,:(args[$i]))
        end
    end

    if (rett != None) && rett <: CppValue
        arguments = [:(pointer(r.data)), args2]
        size = cxxsizeof(rt)
        return Expr(:block,
            :( r = ($(rett))(Array(Uint8,$size)) ),
            Expr(:call,:llvmcall,f.ptr,Void,tuple(llvmargt...),arguments...),
            :r)
    else
        return Expr(:call,:llvmcall,f.ptr,rett,tuple(argt...),args2...)
    end
end


stagedfunction cppcall(expr, args...)
    _cppcall(expr, false, false, args)
end

stagedfunction cppcall_member(expr, args...)
    _cppcall(expr, true, false, args)
end

stagedfunction cxxnewcall(expr, args...)
    _cppcall(expr, false, true, args)
end

stagedfunction cxxref(expr)
    isaddrof = false
    if expr <: CppAddr
        expr = expr.parameters[1]
        isaddrof = true
    end
    #nnsbuilder = newNNSBuilder()
    cxxscope = newCXXScopeSpec()

    d = declfornns(expr,cxxscope)
    @assert d.ptr != C_NULL
    # If this is a typedef or something we'll try to get the primary one
    primary_decl = to_decl(primary_ctx(toctx(d)))
    if primary_decl != C_NULL
        d = primary_decl
    end

    if isaValueDecl(d)
        expr = dre = CreateDeclRefExpr(d;
            islvalue = isaVarDecl(d) ||
                (isaFunctionDecl(d) && !isaCXXMethodDecl(d)),
            cxxscope=cxxscope)
        #deleteNNSBuilder(nnsbuilder)
        deleteCXXScopeSpec(cxxscope)

        if isaddrof
            expr = CreateAddrOfExpr(dre)
        end

        return emitRefExpr(expr)
    else
        return :( $(juliatype(QualType(typeForDecl(d)))) )
    end
end

function cpp_ref(expr,nns,isaddrof)
    @assert isa(expr, Symbol)
    nns = Expr(:tuple,nns.args...,quot(expr))
    x = :(CppNNS{$nns}())
    ret = Expr(:call, :cxxref, isaddrof ? :(CppAddr($x)) : x)
end

function refderefarg(arg)
    if isexpr(arg,:call)
        # is unary *
        if length(arg.args) == 2 && arg.args[1] == :*
            return :( CppDeref($(refderefarg(arg.args[2]))) )
        end
    elseif isexpr(arg,:&)
        return :( CppAddr($(refderefarg(arg.args[1]))) )
    end
    arg
end

# Builds a call to the cppcall staged functions that represents a
# call to a C++ function.
# Arguments:
#   - cexpr:    The (julia-side) call expression
#   - this:     For a member call the expression corresponding to
#               object of which the function is being called
#   - prefix:   For a call namespaced call, all namespace qualifiers
#
# E.g.:
#   - @cxx foo::bar::baz(a,b,c)
#       - cexpr == :( baz(a,bc) )
#       - this === nothing
#       - prefix == "foo::bar"
#   - @cxx m->DoSomething(a,b,c)
#       - cexpr == :( DoSomething(a,b,c) )
#       - this == :( m )
#       - prefix = ""
#
function build_cpp_call(cexpr, this, nns, isnew = false)
    if !isexpr(cexpr,:call)
        error("Expected a :call not $cexpr")
    end
    targs = ()

    # Turn prefix and call expression, back into a fully qualified name
    # (and optionally type arguments)
    if isexpr(cexpr.args[1],:curly)
        nns = Expr(:tuple,nns.args...,quot(cexpr.args[1].args[1]))
        targs = map(macroexpand, copy(cexpr.args[1].args[2:end]))
    else
        nns = Expr(:tuple,nns.args...,quot(cexpr.args[1]))
        targs = ()
    end

    arguments = cexpr.args[2:end]

    # Unary * is treated as a deref
    for (i, arg) in enumerate(arguments)
        arguments[i] = refderefarg(arg)
    end

    # Add `this` as the first argument
    this !== nothing && unshift!(arguments, this)

    e = curly = :( CppNNS{$nns} )

    # Add templating
    if targs != ()
        e = :( CppTemplate{$curly,$targs} )
    end

    # The actual call to the staged function
    ret = Expr(:call, isnew ? :cxxnewcall : this === nothing ? :cppcall : :cppcall_member)
    push!(ret.args,:($e()))
    append!(ret.args,arguments)
    ret
end

function build_cpp_ref(member, this, isaddrof)
    @assert isa(member,Symbol)
    x = :(CppExpr{$(quot(symbol(member))),()}())
    ret = Expr(:call, :cxxmemref, isaddrof ? :(CppAddr($x)) : x, this)
end

function to_prefix(expr, isaddrof=false)
    if isa(expr,Symbol)
        return (Expr(:tuple,quot(expr)), isaddrof)
    elseif isa(expr, Bool)
        return (Expr(:tuple,expr),isaddrof)
    elseif isexpr(expr,:(::))
        nns1, isaddrof = to_prefix(expr.args[1],isaddrof)
        nns2, _ = to_prefix(expr.args[2],isaddrof)
        return (Expr(:tuple,nns1.args...,nns2.args...), isaddrof)
    elseif isexpr(expr,:&)
        return to_prefix(expr.args[1],true)
    elseif isexpr(expr,:$)
        @show expr.args[1]
        return (Expr(:tuple,expr.args[1],),isaddrof)
    elseif isexpr(expr,:curly)
        nns, isaddrof = to_prefix(expr.args[1],isaddrof)
        tup = Expr(:tuple)
        @show expr
        for i = 2:length(expr.args)
            nns2, isaddrof2 = to_prefix(expr.args[i],false)
            @assert !isaddrof2
            isnns = length(nns2.args) > 1 || isa(nns2.args[1],Expr)
            push!(tup.args, isnns ? :(CppNNS{$nns2}) : nns2.args[1])
        end
        @assert length(nns.args) == 1
        @assert isexpr(nns.args[1],:quote)

        return (Expr(:tuple,:(CppTemplate{$(nns.args[1]),$tup}),),isaddrof)
    end
    error("Invalid NNS $expr")
end

function cpps_impl(expr,nns=Expr(:tuple),isaddrof=false,isderef=false,isnew=false)
    if isa(expr,Symbol)
        @assert !isnew
        return cpp_ref(expr,nns,isaddrof)
    elseif expr.head == :(->)
        @assert !isnew
        a = expr.args[1]
        b = expr.args[2]
        i = 1
        while !(isexpr(b,:call) || isa(b,Symbol))
            b = expr.args[2].args[i]
            if !(isexpr(b,:call) || isexpr(b,:line) || isa(b,Symbol))
                error("Malformed C++ call. Expected member not $b")
            end
            i += 1
        end
        if isexpr(b,:call)
            return build_cpp_call(b,a,nns)
        else
            if isexpr(a,:&)
                a = a.args[1]
                isaddrof = true
            end
            return build_cpp_ref(b,a,isaddrof)
        end
    elseif isexpr(expr,:(=))
        @assert !isnew
        error("Unimplemented")
    elseif isexpr(expr,:(::))
        nns2, isaddrof = to_prefix(expr.args[1])
        return cpps_impl(expr.args[2],Expr(:tuple,nns.args...,nns2.args...),isaddrof,isderef,isnew)
    elseif isexpr(expr,:&)
        return cpps_impl(expr.args[1],nns,true,isderef,isnew)
    elseif isexpr(expr,:call)
        if expr.args[1] == :*
            return cpps_impl(expr.args[2],nns,isaddrof,true,isnew)
        end
        return build_cpp_call(expr,nothing,nns,isnew)
    end
    error("Unrecognized CPP Expression ",expr," (",expr.head,")")
end

macro cxx(expr)
    cpps_impl(expr)
end

macro cxxnew(expr)
    cpps_impl(expr, Expr(:tuple), false, false, true)
end

# cxx"" string implementation (global scope)

global varnum = 1

const jns = cglobal((:julia_namespace,libcxxffi),Ptr{Void})

#
# Takes a julia value and makes in into an llvm::Constant
#
function llvmconst(val::ANY)
    T = typeof(val)
    if isbits(T)
        if !Base.isstructtype(T)
            if T <: FloatingPoint
                return getConstantFloat(julia_to_llvm(T),float64(val))
            else
                return getConstantInt(julia_to_llvm(T),uint64(val))
            end
        else
            vals = [getfield(val,i) for i = 1:length(T.names)]
            return getConstantStruct(julia_to_llvm(T),vals)
        end
    end
    error("Cannot turn this julia value into a constant")
end

function SetDeclInitializer(decl::pcpp"clang::VarDecl",val::pcpp"llvm::Constant")
    ccall((:SetDeclInitializer,libcxxffi),Void,(Ptr{Void},Ptr{Void}),decl,val)
end

function ssv(e::ANY,ctx,varnum)
    T = typeof(e)
    if isa(e,Expr) || isa(e,Symbol)
        # Create a thunk that contains this expression
        thunk = eval(:( ()->($e) ))
        linfo = thunk.code
        (tree, ty) = Base.typeinf(linfo,(),())
        T = ty
        thunk.code.ast = tree
        # Pretend we're a specialized generic function
        # to get the good calling convention. The compiler
        # will never know :)
        setfield!(thunk.code,6,())
        if isa(T,UnionType) || T.abstract
            error("Inferred Union or abstract type $T for expression $e")
        end
        sv = CreateFunctionDecl(ctx,string("call",varnum),makeFunctionType(cpptype(T),QualType[]))
        e = thunk
    else
        name = string("var",varnum)
        sv = CreateVarDecl(ctx,name,cpptype(T))
    end
    AddDeclToDeclCtx(ctx,pcpp"clang::Decl"(sv.ptr))
    e, sv
end

function ArgCleanup(e,sv)
    if isa(sv,pcpp"clang::FunctionDecl")
        f = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Ptr{Void},Bool), e, C_NULL, false))
        ReplaceFunctionForDecl(sv,f)
    else
        SetDeclInitializer(sv,llvmconst(e))
    end
end

const sourcebuffers = Array((String,Symbol,Int,Int),0)

immutable SourceBuf{id}; end
sourceid{id}(::Type{SourceBuf{id}}) = id

icxxcounter = 0

ActOnStartOfFunction(D) = pcpp"clang::Decl"(ccall((:ActOnStartOfFunction,libcxxffi),Ptr{Void},(Ptr{Void},),D))
ParseFunctionStatementBody(D) = ccall((:ParseFunctionStatementBody,libcxxffi),Void,(Ptr{Void},),D)

ActOnStartNamespaceDef(name) = pcpp"clang::Decl"(ccall((:ActOnStartNamespaceDef,libcxxffi),Ptr{Void},(Ptr{Uint8},),name))
ActOnFinishNamespaceDef(D) = ccall((:ActOnFinishNamespaceDef,libcxxffi),Void,(Ptr{Void},),D)

const icxx_ns = createNamespace("__icxx")

function EmitTopLevelDecl(D::pcpp"clang::Decl")
    if isDeclInvalid(D)
        error("Tried to emit invalid decl")
    end
    ccall((:EmitTopLevelDecl,libcxxffi),Void,(Ptr{Void},),D)
end
EmitTopLevelDecl(D::pcpp"clang::FunctionDecl") = EmitTopLevelDecl(pcpp"clang::Decl"(D.ptr))

SetFDParams(FD::pcpp"clang::FunctionDecl",params::Vector{pcpp"clang::ParmVarDecl"}) =
    ccall((:SetFDParams,libcxxffi),Void,(Ptr{Void},Ptr{Ptr{Void}},Csize_t),FD,[p.ptr for p in params],length(params))

#
# Create a clang FunctionDecl with the given body and
# and the given types for embedded __juliavars
#
function CreateFunctionWithBody(body,args...; filename = symbol(""), line = 1, col = 1)
    global icxxcounter

    argtypes = (Int,QualType)[]
    typeargs = (Int,QualType)[]
    llvmargs = Any[]
    argidxs = Int[]
    # Make a first part about the arguments
    # and replace __juliavar$i by __julia::type$i
    # for all types. Also remember all types and remove them
    # from `args`.
    for (i,arg) in enumerate(args)
        # We passed in an actual julia type
        if arg <: Type
            body = replace(body,"__juliavar$i","__juliatype$i")
            push!(typeargs,(i,cpptype(arg.parameters[1])))
        else
            T = cpptype(arg)
            (arg <: CppValue) && (T = referenceTo(T))
            push!(argtypes,(i,T))
            push!(llvmargs,arg)
            push!(argidxs,i)
        end
    end

    if filename == symbol("")
        EnterBuffer(body)
    else
        EnterVirtualSource(body,VirtualFileName(filename))
    end

    local FD
    local dne
    try
        ND = ActOnStartNamespaceDef("__icxx")
        fname = string("icxx",icxxcounter)
        icxxcounter += 1
        ctx = toctx(ND)
        FD = CreateFunctionDecl(ctx,fname,makeFunctionType(QualType(C_NULL),
            QualType[ T for (_,T) in argtypes ]),false)
        params = pcpp"clang::ParmVarDecl"[]
        for (i,argt) in argtypes
            param = CreateParmVarDecl(argt,string("__juliavar",i))
            push!(params,param)
        end
        for (i,T) in typeargs
            D = CreateTypeDefDecl(ctx,"__juliatype$i",T)
            AddDeclToDeclCtx(ctx,pcpp"clang::Decl"(D.ptr))
        end
        SetFDParams(FD,params)
        FD = ActOnStartOfFunction(pcpp"clang::Decl"(FD.ptr))
        ParseFunctionStatementBody(FD)
        ActOnFinishNamespaceDef(ND)
    catch e
        @show e
    end

    #dump(FD)

    EmitTopLevelDecl(FD)

    FD, llvmargs, argidxs
end

stagedfunction cxxstr_impl(sourcebuf, args...)
    id = sourceid(sourcebuf)
    buf, filename, line, col = sourcebuffers[id]

    FD, llvmargs, argidxs = CreateFunctionWithBody(buf, args...; filename = filename, line = line, col = col)

    dne = CreateDeclRefExpr(FD)
    return CallDNE(dne,tuple(llvmargs...); argidxs = argidxs)
end

#
# Generate a virtual name for a file in the same directory as `filename`.
# This will be the virtual filename for clang to refer to the source snippet by.
# What this is doesn't really matter as long as it's distring for every snippet,
# as we #line it to the proper filename afterwards anyway.
#
VirtualFileNameCounter = 0
function VirtualFileName(filename)
    global VirtualFileNameCounter
    name = joinpath(dirname(string(filename)),string("__cxxjl_",VirtualFileNameCounter,".cpp"))
    VirtualFileNameCounter += 1
    name
end

function process_cxx_string(str,global_scope = true,filename=symbol(""),line=1,col=1)
    # First we transform the source buffer by pulling out julia expressions
    # and replaceing them by expression like __julia::var1, which we can
    # later intercept in our external sema source
    # TODO: Consider if we need more advanced scope information in which
    # case we should probably switch to __julia_varN instead of putting
    # things in namespaces.
    # TODO: It would be nice diagnostics were reported on the original source,
    # rather than the source with __julia* substitutions
    pos = 1
    sourcebuf = IOBuffer()
    if !global_scope
        write(sourcebuf,"{\n")
    end
    if filename != symbol("")
        if filename == :none
            filename = :REPL
        end
        write(sourcebuf,"#line $line \"$filename\"\n")
        if filename == :REPL
            filename = symbol(joinpath(pwd(),"REPL"))
        end
    end
    # Clang has no function for setting the column
    # so we just write a bunch of spaces to match the
    # indentation for the first line.
    # However, due to the processing below columns are off anyway,
    # so let's not do this until we can actually gurantee it'll be correct
    # for _ in 1:(col-1)
    #    write(sourcebuf," ")
    # end
    exprs = Any[]
    isexprs = Bool[]
    global varnum
    startvarnum = varnum
    localvarnum = 1
    while true
        idx = search(str,'$',pos)
        if idx == 0
            write(sourcebuf,str[pos:end])
            break
        end
        write(sourcebuf,str[pos:(idx-1)])
        # Parse the first expression after `$`
        expr,pos = parse(str, idx + 1; greedy=false)
        push!(exprs,expr)
        isexpr = (str[idx+1] == ':')
        push!(isexprs,isexpr)
        if global_scope
            write(sourcebuf,
                isexpr ? string("__julia::call",varnum,"()") :
                         string("__julia::var",varnum))
            varnum += 1
        elseif isexpr
            write(sourcebuf, string("__julia::call",varnum,"()"))
            varnum += 1
        else
            write(sourcebuf, string("__juliavar",localvarnum))
            localvarnum += 1
        end
    end
    if global_scope
        argsetup = Expr(:block)
        argcleanup = Expr(:block)
        for expr in exprs
            s = gensym()
            sv = gensym()
            push!(argsetup.args,:(($s, $sv) = ssv($expr,ctx,$startvarnum)))
            startvarnum += 1
            push!(argcleanup.args,:(ArgCleanup($s,$sv)))
        end
        parsecode = filename == "" ? :( cxxparse($(takebuf_string(sourcebuf))) ) :
            :( ParseVirtual( $(takebuf_string(sourcebuf)),
                $( VirtualFileName(filename) ),
                $( quot(filename) ),
                $( line ),
                $( col )) )
        return quote
            let
                jns = cglobal((:julia_namespace,libcxxffi),Ptr{Void})
                ns = createNamespace("julia")
                ctx = toctx(pcpp"clang::Decl"(ns.ptr))
                unsafe_store!(jns,ns.ptr)
                $argsetup
                $parsecode
                unsafe_store!(jns,C_NULL)
                $argcleanup
            end
        end
    else
        write(sourcebuf,"\n}")
        push!(sourcebuffers,(takebuf_string(sourcebuf),filename,line,col))
        id = length(sourcebuffers)
        ret = Expr(:call,cxxstr_impl,:(SourceBuf{$id}()))
        for (i,e) in enumerate(exprs)
            @assert !isexprs[i]
            push!(ret.args,e)
        end
        return ret
    end
end

macro cxx_str(str,args...)
    process_cxx_string(str,true,args...)
end

macro icxx_str(str,args...)
    process_cxx_string(str,false,args...)
end

macro icxx_mstr(str,args...)
    process_cxx_string(str,false,args...)
end

macro cxx_mstr(str,args...)
    process_cxx_string(str,true,args...)
end

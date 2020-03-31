# This file contains the logic that turns the "pseudo-AST" created by @cxx
# into a clang AST, as well as performing the necessary work to do the
# actual codegen.

# # # Section 1: Pseudo-AST handling
#
# Recall from the general overview, that in order to get the AST information
# through to the staged function, we represent this information as type
# and decode it into a clang AST. The main vehicle to do this is CppNNS,
# which represents a C++ name, potentially qualified by templates or namespaces.
#
# E.g. the @cxx macro will rewrite `@cxx foo::bar()` into
#
# # This is a call, so we use the staged function cppcall
# cppcall(
#    # The name to be called is foo::bar. This gets turned into a tuple
#    # representing the `::` separated parts (which may include template
#    # instantiations, etc.). Note that we then create an instance, to make
#    # sure the staged function gets the type CppNNS{(:foo,:bar)} as its
#    # argument, so we may reconstruct the intent.
#    CppNNS{(:foo,:bar)}()
# )
#
# For more details on the macro, see cxxmacro.jl.
#
# In addition to CppNNS, there are several modifiers that can be applied such
# as `CppAddr` or `CppDeref` for introducing address-of or deref operators into
# the clang AST.
#
# These modifiers are handles by three functions, stripmodifier, resolvemodifier
# and resolvemodifier_llvm. As the names indicate, stripmodifier, just returns
# the modified NNS while resolvemodifier and resolvemodifier_llvm apply any
# necessary transformations at the LLVM, resp. Clang level.
#

# Pseudo-AST definitions

struct CppNNS{chain}; end

struct CppExpr{T,targs}; end

# Force cast the data portion of a jl_value_t to the given C++
# type
struct JLCppCast{T,JLT}
    data::JLT
end
@generated function JLCppCast{T}(data::JLT) where {T,JLT}
    JLT.mutable ||
        error("Can only pass pointers to mutable values. " *
              "To pass immutables, use an array instead.")
    quote
        JLCppCast{T,JLT}(data)
    end
end

cpptype(C,p::Type{JLCppCast{T,jlt}}) where {T,jlt} = pointerTo(C,cpptype(C,T))

macro jpcpp_str(s,args...)
    JLCppCast{CppBaseType{Symbol(s)}}
end

# Represents a forced cast form the value T
# (which may be any C++ compatible value)
# to the the C++ type To
struct CppCast{T,To}
    from::T
end
CppCast(from::T,::Type{To}) where {T,To} = CppCast{T,To}(from)
cast(from::T,::Type{To}) where {T,To} = CppCast{T,To}(from)

# Represents a C++ Deference
struct CppDeref{T}
    val::T
end

# Represent a C++ addrof (&foo)
struct CppAddr{T}
    val::T
end

# On base types, don't do anything for stripmodifer/resolvemodifier. Since,
# we'll be dealing with these directly

stripmodifier(cppfunc::Type{CppFptr{f}}) where {f} = cppfunc
stripmodifier(p::Union{Type{CppPtr{T,CVR}},
    Type{CppRef{T,CVR}}}) where {T,CVR} = p
stripmodifier(p::Type{T}) where {T <: CppValue} = p
stripmodifier(p::Type{T}) where {T<:CppEnum} = p
stripmodifier(p::Type{CppMFptr{base,fptr}}) where {base,fptr} = p
stripmodifier(p::CxxBuiltinTypes) = p
stripmodifier(p::Type{T}) where {T<:Function} = p
stripmodifier(p::Type{Ptr{T}}) where {T} = p
stripmodifier(p::Type{T}) where {T<:Ref} = p
stripmodifier(p::Type{JLCppCast{T,JLT}}) where {T,JLT} = p
stripmodifier(p::Type{T}) where {T} = p

resolvemodifier(C,p::Union{Type{CppPtr{T,CVR}}, Type{CppRef{T,CVR}}}, e::pcpp"clang::Expr") where {T,CVR} = e
resolvemodifier(C, p::Type{T}, e::pcpp"clang::Expr") where {T <: CppValue} = e
resolvemodifier(C,p::CxxBuiltinTypes, e::pcpp"clang::Expr") = e
resolvemodifier(C,p::Type{Ptr{T}}, e::pcpp"clang::Expr") where {T} = e
resolvemodifier(C,p::Type{T}, e::pcpp"clang::Expr") where {T<:Ref} = e
resolvemodifier(C,p::Type{T}, e::pcpp"clang::Expr") where {T<:CppEnum} = e
resolvemodifier(C,p::Type{CppMFptr{base,fptr}}, e::pcpp"clang::Expr") where {base,fptr} = e
resolvemodifier(C,cppfunc::Type{CppFptr{f}}, e::pcpp"clang::Expr") where {f} = e
resolvemodifier(C,p::Type{JLCppCast{T,JLT}}, e::pcpp"clang::Expr") where {T,JLT} = e
resolvemodifier(C,p::Type{T}, e::pcpp"clang::Expr") where {T} = e

# For everything else, perform the appropriate transformation
stripmodifier(p::Type{CppCast{T,To}}) where {T,To} = T
stripmodifier(p::Type{CppDeref{T}}) where {T} = T
stripmodifier(p::Type{CppAddr{T}}) where {T} = T

resolvemodifier(C,p::Type{CppCast{T,To}}, e::pcpp"clang::Expr") where {T,To} =
    createCast(C,e,cpptype(C,To),CK_BitCast)
resolvemodifier(C,p::Type{CppDeref{T}}, e::pcpp"clang::Expr") where {T} =
    createDerefExpr(C,e)
resolvemodifier(C,p::Type{CppAddr{T}}, e::pcpp"clang::Expr") where {T} =
    CreateAddrOfExpr(C,e)

# The LLVM operations themselves are slightly more tricky, since we need
# to translate from julia's llvm representation to clang's llvm representation
# (note that we still insert a bitcast later, so we only have to make sure it
# matches at a level that is bitcast-able)

# Builtin types and plain pointers are easy - they are represented the
# same in julia and Clang
resolvemodifier_llvm(C, builder, t::Type{Ptr{ptr}}, v::pcpp"llvm::Value") where {ptr} = IntToPtr(builder,v,toLLVM(C,cpptype(C, Ptr{ptr})))
function resolvemodifier_llvm(C, builder, t::Type{T}, v::pcpp"llvm::Value") where {T<:Ref}
    v = CreatePointerFromObjref(C, builder, v)
    v
end
resolvemodifier_llvm(C, builder, t::Type{Bool}, v::pcpp"llvm::Value") =
    CreateTrunc(builder, v, toLLVM(C, cpptype(C, Bool)))
resolvemodifier_llvm(C, builder, t::CxxBuiltinTypes, v::pcpp"llvm::Value") = v

resolvemodifier_llvm(C, builder, t::Type{T}, v::pcpp"llvm::Value") where {T} = v

function resolvemodifier_llvm(C, builder,
    t::Type{CppRef{T,CVR}}, v::pcpp"llvm::Value") where {T,CVR}
    ty = cpptype(C, t)
    IntToPtr(builder,v,toLLVM(C,ty))
end

function resolvemodifier_llvm(C, builder, t::Type{CppPtr{T, CVR}}, v::pcpp"llvm::Value") where {T,CVR}
    ty = cpptype(C, t)
    IntToPtr(builder,v,getPointerTo(toLLVM(C,ty)))
end

# Same situation as the pointer case
resolvemodifier_llvm(C, builder, t::Type{T}, v::pcpp"llvm::Value") where {T<:CppEnum} =
    ExtractValue(C,v,0)
resolvemodifier_llvm(C, builder, t::Type{CppFptr{f}}, v::pcpp"llvm::Value") where {f} =
    ExtractValue(C,v,0)

# Very similar to the pointer case, but since there may be additional wrappers
# hiding behind the T, we need to recursively call back into
# resolvemodifier_llvm
resolvemodifier_llvm(C, builder, t::Type{CppCast{T,To}}, v::pcpp"llvm::Value") where {T,To} =
    resolvemodifier_llvm(C,builder, T, ExtractValue(C,v,0))
resolvemodifier_llvm(C, builder, t::Type{CppDeref{T}}, v::pcpp"llvm::Value") where {T} =
    resolvemodifier_llvm(C,builder, T, ExtractValue(C,v,0))
resolvemodifier_llvm(C, builder, t::Type{CppAddr{T}}, v::pcpp"llvm::Value") where {T} =
    resolvemodifier_llvm(C,builder, T, ExtractValue(C,v,0))


# We need to cast from a named struct with two fields to an anonymous struct
# with two fields. This isn't bitcastable, so we need to use to sets of insert
# and extract instructions
function resolvemodifier_llvm(C, builder,
        t::Type{CppMFptr{base,fptr}}, v::pcpp"llvm::Value") where {base,fptr}
    t = getLLVMStructType([julia_to_llvm(UInt64),julia_to_llvm(UInt64)])
    undef = getUndefValue(t)
    i1 = InsertValue(builder, undef, ExtractValue(C,v,0), 0)
    return InsertValue(builder, i1, ExtractValue(C,v,1), 1)
end

# We want to pass the content of a C-compatible julia struct to C++. Recall that
# (boxed) julia objects are layed out as
#
#  +---------------+
#  |     type      |    # pointer to the type of this julia object
#  +---------------+
#  |    field1     |    # Fields are stored inline and generally layed out
#  |    field2     |    # compatibly with (i.e. padded according to) the C
#  |     ...       |    # memory layout
#  +---------------+
#
# As of julia 0.4, jl_value_t pointers generally point to the data directly,
# so we can just pass the pointer through.
#
function resolvemodifier_llvm(C, builder,
        t::Type{JLCppCast{T,jlt}}, v::pcpp"llvm::Value") where {T,jlt}
    return v
end

# This used to be a lot more complicated before the pointer and tuple reworks
# Luckily for us, now it's just:
#
#    +-----------------+
#    |   CppValue      |
#    +-----------------+
# /--|-NTuple{N,UInt8}-|----------> The data we want
# |  |       ...       |
# |  +-----------------+
# |
# \--We start here
#

function resolvemodifier_llvm(C, builder,
        t::Type{T}, v::pcpp"llvm::Value") where T <: CppValue
    @assert v != C_NULL
    ty = cpptype(C, t)
    if !isPointerType(getType(v))
        dump(v)
        error("Value is not of pointer type")
    end
    v = CreatePointerFromObjref(C, builder, v)
    return CreateBitCast(builder,v,getPointerTo(getPointerTo(toLLVM(C,ty))))
end

# Turning a CppNNS back into a Decl
#
# This can be considered a more fancy form of name lookup, etc. because it
# can it can descend into template declarations, as well as having to
# unmarshall the CppNNS structure. However, the basic functionality and
# caveats named in typetranslation.jl still apply.
#

function typeForNNS(C,T::Type{CppNNS{Tnns}}) where Tnns
    nns = isa(Tnns, Symbol) ? Tuple{Tnns} : Tnns
    nns2 = nns.parameters
    if length(nns2) == 1 && (isa(nns2[1], Type) &&
        (nns2[1] <: CppPtr || nns2[1] <: CppRef))
        return cpptype(C,nns2[1])
    end
    typeForDecl(declfornns(C,T))
end

function declfornns(C,::Type{CppNNS{Tnns}},cxxscope=C_NULL) where Tnns
    nns = isa(Tnns, Symbol) ? Tuple{Tnns} : Tnns
    @assert nns <: Tuple
    d = tu = translation_unit(C)
    for (i,n) in enumerate(nns.parameters)
        if !isa(n, Symbol)
            if n <: CppTemplate
                d = lookup_name(C, (n.parameters[1],),C_NULL,d)
                cxxt = cxxtmplt(d)
                @assert cxxt != C_NULL
                arr = Any[]
                for arg in n.parameters[2].parameters
                    if isa(arg,Type)
                        if arg <: CppNNS
                            push!(arr,typeForNNS(C,arg))
                        elseif arg <: CppPtr
                            push!(arr,cpptype(C,arg))
                        end
                    else
                        push!(arr,arg)
                    end
                end
                d = specialize_template_clang(C,cxxt,arr)
                @assert d != C_NULL
                # TODO: Do we need to extend the cxxscope here
            else
                @assert d == tu
                t = cpptype(C, n)
                dump(t)
                dump(getPointeeType(t))
                # TODO: Do we need to extend the cxxscope here
                d = getAsCXXRecordDecl(getPointeeType(t))
            end
        else
            d = lookup_name(C, (n,), cxxscope, d, i != length(nns.parameters))
        end
        @assert d != C_NULL
    end
    d
end

function declfornns(C,::Type{Val{T}}) where T
    return T
end


# # # Section 2: CodeGen
#
# # Overview
#
# To build perform code generation, we do the following.
#
# 1. Create Clang-level ParmVarDecls (buildargexprs)
#
# In order to get clang to know about the llvm level values, we create a
# ParmVarDecl for every LLVM Value we want clang to know about. ParmVarDecls
# are the clang AST-level representation of function parameters. Luckily, Clang
# doesn't care if these match the actual parameters to any function, so they
# are the perfect way to inject our LLVM values into Clang's AST. Note that
# these should be given the clang type that will pick up where we leave the
# LLVM value off. To explain what this means, consider
#
# julia> bar = pcpp"int"(C_NULL)
# julia> @cxx foo(*(bar))
#
# The parameter of the LLVM function will have the structure
#
# { # CppDeref
#   { # CppPtr
#       ptr : C_NULL
#   }
# }
#
# The two LLVM struct wrappers around the bare pointer are stripped in llvmargs.
# However, the type of Clang-level ParmVarDecl will still be `int *`, even
# though we'll end up passing the dereferenced value to Clang. Clang itself
# will take care of emitting the code for the dereference (we introduce the
# appropriate node into the AST in `resolvemodifier`).
#
# Finally note that we also need to create a DeclRefExpr, since the ParmVarDecl
# just declares the parameter (since it's a Decl), we need to reference the decl
# to put it into the AST.
#
# 2. Create the Clang AST and emit it
#
# This basically amounts to finding the correct method to call in order to build
# up AST node we need and calling it with the DeclRefExpr's we obtained in step
# 1. One further tricky aspect is that for the next step we need to know the
# return type we'll get back from clang. In general, all clang Expression need
# to be tagged with the result type of the expression in order to construct
# them, which for our purposes can defeat the purpose (since we may need to
# provide in to construct the AST, even though we don't it yet). In cases where
# that information is still useful, it can be extracted from an Expr *, using
# the `GetExprResultType` function. However, even in other cases, we can still
# convince clang to tell us what the return type is by making use of the C++
# standard required type inference capabilities used for auto and
# decltype(auto) (we use the latter to make sure we actually return references
# when a function we're calling is declared a reference). The remaining case
# is that where we're calling a constructor for which the return type is
# obviously known.
#
# 3. Create an LLVM function that will be passed to llvmcall.
#
# The argument types of the LLVM function will still be julia representation
# of the underlying values and potentially any modifiers. This is taken care
# of by the resolvemodifier_llvm function above which is called by `llvmargs`
# below.
# The reason for this mostly historic and could be simplified,
# though some LLVM-level processing will always be necessary.
#
# 4. Hook up the LLVM level representation to Clang's (associateargs)
#
# This is fairly simple. We can simply tell clang which llvm::Value to use.
# Usually, this would be the llvm::Value representing the actual argument to the
# LLVM-level function, but it's also fine to use our adjusted Values (LLVM
# doesn't really distinguish).
#

#
# `f` is the function we are emitting into, i.e. the function that gets
# julia-level arguments. This function, goes through all the arguments and
# applies any necessary llvm-level transformation for the llvm values to be
# compatible with the type expected by clang.
#
# Returns the list of processed arguments
function llvmargs(C, builder, f, argt)
    args = Vector{pcpp"llvm::Value"}(undef, length(argt))
    for i in 1:length(argt)
        t = argt[i]
        args[i] = pcpp"llvm::Value"(ccall(
            (:get_nth_argument,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Csize_t),f,i-1))
        @assert args[i] != C_NULL
        args[i] = resolvemodifier_llvm(C, builder, t, args[i])
        if args[i] == C_NULL
            error("Failed to process argument")
        end
    end
    args
end

cxxtransform(T,ex) = (T, ex)
cxxtransform(::Type{String},ex) = (Ptr{UInt8},:(pointer($ex)))

function buildargexprs(C, argt; derefval = true)
    callargs = pcpp"clang::Expr"[]
    pvds = pcpp"clang::ParmVarDecl"[]
    for i in 1:length(argt)
        t = argt[i]
        st = stripmodifier(t)
        argit = cpptype(C, st)
        st <: CppValue && (argit = pointerTo(C,argit))
        argpvd = CreateParmVarDecl(C, argit)
        push!(pvds, argpvd)
        expr = CreateDeclRefExpr(C, argpvd)
        derefval && st <: CppValue && (expr = createDerefExpr(C, expr))
        expr = resolvemodifier(C, t, expr)
        push!(callargs,expr)
    end
    callargs, pvds
end

function associateargs(C, builder,argt,args,pvds)
    for i = 1:length(args)
        t = stripmodifier(argt[i])
        argit = cpptype(C, t)
        if t <: CppValue
            argit = pointerTo(C,argit)
        end
        AssociateValue(C, pvds[i],argit,args[i])
    end
end

# # #

# Some utilities

function irbuilder(C)
    pcpp"clang::CodeGen::CGBuilderTy"(
        ccall((:clang_get_builder,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},),C))
end

function _julia_to_llvm(@nospecialize x)
    isboxed = Ref{UInt8}()
    ty = pcpp"llvm::Type"(ccall(:jl_type_to_llvm,Ptr{Cvoid},(Any,Ref{UInt8}),x,isboxed))
    (isboxed[] != 0, ty)
end
function julia_to_llvm(@nospecialize x)
    isboxed, ty = _julia_to_llvm(x)
    isboxed ? getPRJLValueTy() : ty
end

# @cxx llvm::dyn_cast{vcpp"clang::ClassTemplateDecl"}
function cxxtmplt(p::pcpp"clang::Decl")
    pcpp"clang::ClassTemplateDecl"(
        ccall((:cxxtmplt,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),p))
end


# Checks the arguments to make sure we have concrete C++ compatible
# types in the signature. This is used both in cases where type inference
# cannot infer the appropriate argument types during staging (in which case
# the error here will cause it to fall back to runtime) as well as when the
# user has bad types (in which case you'll get a compile-time (but not stage-time)
# error.
function check_args(argt,f)
    for (i,t) in enumerate(argt)
        if isa(t,Union) || (isa(t,DataType) && t.abstract) || (!isCxxEquivalentType(t) &&
            !(t <: CxxBuiltinTs))
            error("Got bad type information while compiling $f (got $t for argument $i)")
        end
    end
end

function emitRefExpr(C, expr, pvd = nothing, ct = nothing)
    # Ask clang what the type is we're expecting
    rt = BuildDecltypeType(C,expr)

    if isFunctionType(rt)
        error("Cannot reference function by value")
    end

    rett = juliatype(rt)

    @assert !(rett <: Union{})

    needsret = false
    if rett <: CppValue
        needsret = true
    end

    argt = Type[]
    needsret && push!(argt, rett)
    (pvd != nothing) && push!(argt,ct)

    llvmrt = julia_to_llvm(rett)
    f = CreateFunctionWithPersonality(C, needsret ? julia_to_llvm(Cvoid) : llvmrt, map(julia_to_llvm,argt))
    state = setup_cpp_env(C, f)
    builder = irbuilder(C)

    args = llvmargs(C, builder, f, argt)

    (pvd != nothing) && associateargs(C,builder,[ct],args[needsret ? (2:2) : (1:1)],[pvd])

    MarkDeclarationsReferencedInExpr(C, expr)
    if !needsret
        ret = EmitAnyExpr(C, expr)
    else
        expr = PerformMoveOrCopyInitialization(C, rt, expr)
        EmitAnyExprToMem(C, expr, args[1], false)
        ret = C_NULL
    end

    createReturn(C,builder,f,argt,argt,llvmrt,rett,rt,ret,state;
        argidxs=pvd == nothing ? [] : [1])
end

#
# Call Handling
#
# There are four major cases we need to take care of:
#
# 1) Membercall, e.g. @cxx foo->bar(...)
# 2) Regular call, e.g. @cxx foo()
# 3) Constructors e.g. @cxx fooclass()
# 4) Heap allocation, e.g. @cxxnew fooclass()
#

const cxx_binops = Dict(
    # Arithmetic operators
    :+ => BO_Add, :- => BO_Sub, :* => BO_Mul, :/ => BO_Div, :% => BO_Rem,
    # Logical Operators (not overloadable)
    # :&& => BO_LAnd, :|| => BO_LOr,
    # Bitwise Operators
    :& => BO_And, :| => BO_Or, :^ => BO_Xor, :<< => BO_Shl, :>> => BO_Shr)

function _cppcall(CT, expr, thiscall, isnew, argt)
    C = instance(CT)
    check_args(argt, expr)

    callargs, pvds = buildargexprs(C,argt)

    rett = Cvoid
    isne = isctce = isce = false
    ce = nE = ctce = C_NULL

    if thiscall # membercall
        if expr <: CppNNS
            fname = expr.parameters[1].parameters[1]
        else
            decl = declfornns(C,expr)
            @assert decl != C_NULL
            fname = Symbol(getName(pcpp"clang::NamedDecl"(convert(Ptr{Cvoid},decl))))
        end
        @assert isa(fname,Symbol)

        me = BuildMemberReference(C,callargs[1], cpptype(C, argt[1]),
            argt[1] <: CppPtr, fname)
        (me == C_NULL) && error("Could not find member $name")

        ce = BuildCallToMemberFunction(C,me,callargs[2:end])
    else
        targs = Tuple{}
        if expr <: CppTemplate
            targs = expr.parameters[2]
            expr = expr.parameters[1]
        end

        # Check if we're calling an operator
        op = nothing
        if expr <: CppNNS
            nns = expr.parameters[1]
            if nns <: Tuple && length(nns.parameters) == 1 &&
                isa(nns.parameters[1],Symbol)
                op = nns.parameters[1]
            end
        end

        if op !== nothing && in(op,keys(cxx_binops))
            ce = CreateBinOp(C, C_NULL,cxx_binops[op],callargs...)
        else
            d = declfornns(C,expr)
            @assert d != C_NULL
            # If this is a typedef or something we'll try to get the primary one
            primary_decl = to_decl(primary_ctx(toctx(d)))
            if primary_decl != C_NULL
                d = primary_decl
            end
            # Let's see if we're constructing something.
            if isaCXXConstructorDecl(pcpp"clang::Decl"(convert(Ptr{Cvoid},d)))
                cxxd = getParent(pcpp"clang::CXXMethodDecl"(convert(Ptr{Cvoid},d)))
            else
                cxxd = dcastCXXRecordDecl(d)
            end
            fname = Symbol(_decl_name(d))
            cxxt = cxxtmplt(d)
            targs = map(targ->typeForNNS(C, targ), targs.parameters)
            if cxxd != C_NULL || cxxt != C_NULL
                if cxxd == C_NULL
                    cxxd = specialize_template_clang(C, cxxt, targs)
                end

                # targs may have changed because the name is canonical
                # but the default targs may be substituted by typedefs
                targs = getTemplateParameters(cxxd)

                T = CppBaseType{fname}
                if targs != Tuple{}
                    T = CppTemplate{T,targs}
                end
                rett = juliart = T = CppValue{CxxQualType{T,NullCVR}}

                if isnew
                    rett = CppPtr{T,NullCVR}
                    nE = BuildCXXNewExpr(C,QualType(typeForDecl(cxxd)),callargs)
                    if nE == C_NULL
                        error("Could not construct `new` expression")
                    end
                    MarkDeclarationsReferencedInExpr(C,nE)
                else
                    rt = QualType(typeForDecl(cxxd))
                    ctce = BuildCXXTypeConstructExpr(C,rt,callargs)
                end
            else
                myctx = getContext(d)
                while declKind(myctx) == kindLinkageSpec
                    myctx = getParentContext(myctx)
                end
                @assert myctx != C_NULL
                dne = BuildDeclarationNameExpr(C, split(string(fname),"::")[end],myctx)

                ce = CreateCallExpr(C, dne,callargs)
            end
        end
    end

    EmitExpr(C,ce,nE,ctce, argt, pvds, rett)
end

function CreateFunctionWithPersonality(C, args...)
    f = CreateFunction(C, args...)
    if !isCCompiler(C)
        PersonalityF = pcpp"llvm::Function"(convert(Ptr{Cvoid},GetAddrOfFunction(C,
            lookup_name(C,["__cxxjl_personality_v0"]))))
        @assert PersonalityF != C_NULL
        setPersonality(f, PersonalityF)
    end
    f
end

# Emits either a CallExpr, a NewExpr, or a CxxConstructExpr, depending on which
# one is non-NULL
function EmitExpr(C,ce,nE,ctce, argt, pvds, rett = Cvoid; kwargs...)
    builder = irbuilder(C)
    argt = Type[argt...]
    map!(argt, argt) do x
        (isCxxEquivalentType(x) || x <: CxxBuiltinTs) ? x : Ref{x}
    end
    llvmargt = Type[argt...]
    issret = false
    rslot = C_NULL
    rt = C_NULL
    ret = C_NULL

    if ce != C_NULL
        # First we need to get the return type of the C++ expression
        rt = BuildDecltypeType(C,ce)
        rett = juliatype(rt)

        issret = (rett != Union{}) && rett <: CppValue
    elseif ctce != C_NULL
        issret = true
        rt = GetExprResultType(ctce)
    end

    if issret
        pushfirst!(llvmargt,rett)
    end

    llvmrt = julia_to_llvm(rett)
    # Let's create an LLVM function
    f = CreateFunctionWithPersonality(C, issret ? julia_to_llvm(Cvoid) : llvmrt,
        map(julia_to_llvm,llvmargt))

    # Clang's code emitter needs some extra information about the function, so let's
    # initialize that as well
    state = setup_cpp_env(C,f)

    builder = irbuilder(C)

    # First compute the llvm arguments (unpacking them from their julia wrappers),
    # then associate them with the clang level variables
    args = llvmargs(C, builder, f, llvmargt)
    associateargs(C, builder, argt, issret ? args[2:end] : args,pvds)

    if ce != C_NULL
        if issret
            rslot = CreateBitCast(builder,args[1],getPointerTo(toLLVM(C,rt)))
        end
        MarkDeclarationsReferencedInExpr(C,ce)
        ret = EmitCallExpr(C,ce,rslot)
        if rett <: CppValue
            ret = C_NULL
        end
    elseif nE != C_NULL
        ret = EmitCXXNewExpr(C,nE)
    elseif ctce != C_NULL
        MarkDeclarationsReferencedInExpr(C,ctce)
        EmitAnyExprToMem(C,ctce,args[1],true)
    end

    # Common return path for everything that's calling a normal function
    # (i.e. everything but constructors)
    createReturn(C,builder,f,argt,llvmargt,llvmrt,rett,rt,ret,state; kwargs...)
end

#
# Common return path for a number of codegen functions. It takes cares of
# actually emitting the llvmcall and packaging the LLVM values we get
# from clang back into the format that julia expects. Unfortunately, it needs
# access to an alarming number of parameters. Hopefully this can be cleaned up
# in the future
#
function createReturn(C,builder,f,argt,llvmargt,llvmrt,rett,rt,ret,state; argidxs = [1:length(argt);], symargs = nothing)
    argt = Type[argt...]

    jlrt = rett
    if ret == C_NULL
        jlrt = Cvoid
        CreateRetVoid(builder)
    else
        if rett == Cvoid || isVoidTy(llvmrt)
            CreateRetVoid(builder)
        else
            if rett <: CppEnum || rett <: CppFptr
                undef = getUndefValue(llvmrt)
                elty = getStructElementType(llvmrt,0)
                ret = rett <: CppFptr ?
                    PtrToInt(builder, ret, elty) :
                    CreateBitCast(builder, ret, elty)
                ret = InsertValue(builder, undef, ret, 0)
            elseif rett <: CppRef || rett <: CppPtr || rett <: Ptr
                ret = PtrToInt(builder, ret, llvmrt)
            elseif rett <: CppMFptr
                undef = getUndefValue(llvmrt)
                i1 = InsertValue(builder,undef,CreateBitCast(builder,
                        ExtractValue(C,ret,0),getStructElementType(llvmrt,0)),0)
                ret = InsertValue(builder,i1,CreateBitCast(builder,
                        ExtractValue(C,ret,1),getStructElementType(llvmrt,1)),1)
            elseif rett == Bool
                ret = CreateZext(builder,ret,julia_to_llvm(rett))
            else
                ret = CreateBitCast(builder,ret,julia_to_llvm(rett))
            end
            CreateRet(builder,ret)
        end
    end

    cleanup_cpp_env(C,state)

    args2 = Any[]
    for (j,i) = enumerate(argidxs)
        if symargs === nothing
            arg = :(args[$i])
        else
            arg = symargs[i]
        end
        if argt[j] <: JLCppCast
            push!(args2,:($arg.data))
            argt[j] = CppPtr{argt[i].parameters[1]}
        else
            push!(args2,arg)
        end
    end

    if (rett != Union{}) && rett <: CppValue
        arguments = vcat([:r], args2)
        size = cxxsizeof(C,rt)
        B = Expr(:block,
            :( r = ($(rett){$(Int(size))})() ),
                Expr(:call,Core.Intrinsics.llvmcall,convert(Ptr{Cvoid},f),Cvoid,Tuple{llvmargt...},arguments...))
        T = cpptype(C, rett)
        D = getAsCXXRecordDecl(T)
        if D != C_NULL && !hasTrivialDestructor(C,D)
            # Need to call the destructor
            push!(B.args,:( finalizer($(get_destruct_for_instance(C)), r) ))
        end
        push!(B.args,:r)
        return B
    else
        return Expr(:call,Core.Intrinsics.llvmcall,convert(Ptr{Cvoid},f),rett,Tuple{argt...},args2...)
    end
end

#
# Code generation for value references (basically everything that's not a call).
# Syntactically, these are of the form
#
#   - @cxx foo
#   - @cxx foo::bar
#   - @cxx foo->bar
#

# Handle member references, i.e. syntax of the form `@cxx foo->bar`
@generated function cxxmemref(CT::CxxInstance, expr, args...)
    C = instance(CT)
    this = args[1]
    check_args([this], expr)
    isaddrof = false
    if expr <: CppAddr
        expr = expr.parameters[1]
        isaddrof = true
    end
    exprs, pvds = buildargexprs(C,[this])
    me = BuildMemberReference(C, exprs[1], cpptype(C, this), this <: CppPtr,
        expr.parameters[1])
    isaddrof && (me = CreateAddrOfExpr(C,me))
    emitRefExpr(C, me, pvds[1], this)
end

# Handle all other references. This is more complicated than the above for two
# reasons.
# a) We can reference types (e.g. `@cxx int`)
# b) Clang cares about how the reference was qualified, so we need to deal with
#    cxxscopes.
@generated function cxxref(CT,expr)
    C = instance(CT)
    isaddrof = false
    if expr <: CppAddr
        expr = expr.parameters[1]
        isaddrof = true
    end

    cxxscope = newCXXScopeSpec(C)
    d = declfornns(C,expr,cxxscope)
    @assert d != C_NULL

    # If this is a typedef or something we'll try to get the primary one
    primary_decl = to_decl(primary_ctx(toctx(d)))
    if primary_decl != C_NULL
        d = primary_decl
    end

    if isaValueDecl(d)
        expr = dre = CreateDeclRefExpr(C, d;
            islvalue = isaVarDecl(d) ||
                (isaFunctionDecl(d) && !isaCXXMethodDecl(d)),
            cxxscope=cxxscope)

        deleteCXXScopeSpec(cxxscope)

        if isaddrof
            expr = CreateAddrOfExpr(C,dre)
        end

        return emitRefExpr(C, expr)
    else
        return :( $(juliatype(QualType(typeForDecl(d)))) )
    end
end

# And finally the staged functions to drive the call logic above
@generated function cppcall(CT::CxxInstance, expr, args...)
    _cppcall(CT, expr, false, false, args)
end

@generated function cppcall_member(CT::CxxInstance, expr, args...)
    _cppcall(CT, expr, true, false, args)
end

@generated function cxxnewcall(CT::CxxInstance, expr, args...)
    _cppcall(CT, expr, false, true, args)
end

# Memory management
@generated function destruct(CT::CxxInstance, x)
    check_args([x],:destruct)
    C = instance(CT)
    f = CreateFunctionWithPersonality(C, julia_to_llvm(Cvoid), [julia_to_llvm(x)])
    state = setup_cpp_env(C,f)
    builder = irbuilder(C)
    args = llvmargs(C, builder, f, [x])
    T = cpptype(C, x)
    D = getAsCXXRecordDecl(T)
    (D == C_NULL || hasTrivialDestructor(C,D)) && error("Destruct called on object with trivial destructor")
    emitDestroyCXXObject(C, args[1], T)
    CreateRetVoid(builder)
    cleanup_cpp_env(C, state)
    return Expr(:call,Core.Intrinsics.llvmcall,convert(Ptr{Cvoid},f),Cvoid,Tuple{x},:x)
end

# This file contains the logic that turns the "pseudo-AST" created by @cxx
# into a clang AST, as well as performing the necessary work to do the
# actual codegen.

const CxxBuiltinTypes = Union(Type{Bool},Type{Int64},Type{Int32},Type{Uint32},
    Type{Uint64},Type{Float32},Type{Float64})

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

immutable CppNNS{chain}; end

immutable CppExpr{T,targs}; end

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

cpptype{T,jlt}(p::Type{JLCppCast{T,jlt}}) = pointerTo(cpptype(T))

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

# On base types, don't do anything for stripmodifer/resolvemodifier. Since,
# we'll be dealing with these directly

stripmodifier{f}(cppfunc::Type{CppFptr{f}}) = cppfunc
stripmodifier{T,CVR}(p::Union(Type{CppPtr{T,CVR}},
    Type{CppRef{T,CVR}}, Type{CppValue{T,CVR}})) = p
stripmodifier{s}(p::Type{CppEnum{s}}) = p
stripmodifier{base,fptr}(p::Type{CppMFptr{base,fptr}}) = p
stripmodifier(p::CxxBuiltinTypes) = p
stripmodifier{T}(p::Type{Ptr{T}}) = p
stripmodifier{T,JLT}(p::Type{JLCppCast{T,JLT}}) = p

resolvemodifier{T,CVR}(p::Union(Type{CppPtr{T,CVR}}, Type{CppRef{T,CVR}},
    Type{CppValue{T,CVR}}), e::pcpp"clang::Expr") = e
resolvemodifier(p::CxxBuiltinTypes, e::pcpp"clang::Expr") = e
resolvemodifier{T}(p::Type{Ptr{T}}, e::pcpp"clang::Expr") = e
resolvemodifier{s}(p::Type{CppEnum{s}}, e::pcpp"clang::Expr") = e
resolvemodifier{base,fptr}(p::Type{CppMFptr{base,fptr}}, e::pcpp"clang::Expr") = e
resolvemodifier{f}(cppfunc::Type{CppFptr{f}}, e::pcpp"clang::Expr") = e
resolvemodifier{T,JLT}(p::Type{JLCppCast{T,JLT}}, e::pcpp"clang::Expr") = e

# For everything else, perform the appropriate transformation
stripmodifier{T,To}(p::Type{CppCast{T,To}}) = T
stripmodifier{T}(p::Type{CppDeref{T}}) = T
stripmodifier{T}(p::Type{CppAddr{T}}) = T

resolvemodifier{T,To}(p::Type{CppCast{T,To}}, e::pcpp"clang::Expr") =
    createCast(e,cpptype(To),CK_BitCast)
resolvemodifier{T}(p::Type{CppDeref{T}}, e::pcpp"clang::Expr") =
    createDerefExpr(e)
resolvemodifier{T}(p::Type{CppAddr{T}}, e::pcpp"clang::Expr") =
    CreateAddrOfExpr(e)

# The LLVM operations themselves are slightly more tricky, since we need
# to translate from julia's llvm representation to clang's llvm representation
# (note that we still insert a bitcast later, so we only have to make sure it
# matches at a level that is bitcast-able)

# Builtin types and plain pointers are easy - they are represented the
# same in julia and Clang
resolvemodifier_llvm{ptr}(builder, t::Type{Ptr{ptr}}, v::pcpp"llvm::Value") = v
resolvemodifier_llvm(builder, t::CxxBuiltinTypes, v::pcpp"llvm::Value") = v

function resolvemodifier_llvm{T,CVR}(builder,
    t::Union(Type{CppPtr{T,CVR}}, Type{CppRef{T,CVR}}), v::pcpp"llvm::Value")
    # CppPtr and CppRef are julia immutables with one field, so at the LLVM
    # level they are represented as LLVM structrs with one (pointer) field.
    # To get at the pointer itself, we simply need to emit an extract
    # instruction
    ExtractValue(v,0)
end

# Same situation as the pointer case
resolvemodifier_llvm{s}(builder, t::Type{CppEnum{s}}, v::pcpp"llvm::Value") =
    ExtractValue(v,0)
resolvemodifier_llvm{f}(builder, t::Type{CppFptr{f}}, v::pcpp"llvm::Value") =
    ExtractValue(v,0)

# Very similar to the pointer case, but since there may be additional wrappers
# hiding behind the T, we need to recursively call back into
# resolvemodifier_llvm
resolvemodifier_llvm{T,To}(builder, t::Type{CppCast{T,To}}, v::pcpp"llvm::Value") =
    resolvemodifier_llvm(builder, T, ExtractValue(v,0))
resolvemodifier_llvm{T}(builder, t::Type{CppDeref{T}}, v::pcpp"llvm::Value") =
    resolvemodifier_llvm(builder, T, ExtractValue(v,0))
resolvemodifier_llvm{T}(builder, t::Type{CppAddr{T}}, v::pcpp"llvm::Value") =
    resolvemodifier_llvm(builder, T, ExtractValue(v,0))


# We need to cast from a named struct with two fields to an anonymous struct
# with two fields. This isn't bitcastable, so we need to use to sets of insert
# and extract instructions
function resolvemodifier_llvm{base,fptr}(builder,
        t::Type{CppMFptr{base,fptr}}, v::pcpp"llvm::Value")
    t = getLLVMStructType([julia_to_llvm(Uint64),julia_to_llvm(Uint64)])
    undef = getUndefValue(t)
    i1 = InsertValue(builder, undef, ExtractValue(v,0), 0)
    return InsertValue(builder, i1, ExtractValue(v,1), 1)
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
# An LLVM value acts like a value to the first address of the object, i.e. the
# type pointer. Thus to get to the data, all we have to do is skip the type
# pointer.
#
function resolvemodifier_llvm{T,jlt}(builder,
        t::Type{JLCppCast{T,jlt}}, v::pcpp"llvm::Value")
    # Skip the type pointer to get to the actual data
    return CreateConstGEP1_32(builder,v,1)
end

# CppValue is perhaps the trickiest of them all, since we store the data in an
# array. This means that the CppValue is boxed and so we need to do some pointer
# arithmetic to get to the data:
#
#  +---------------+    +--------------------+
#  |   CppValue    |    |    Array{Uint8}    |
#  +---------------+    +--------------------+
#              ^                     ^
#  +-----------|---+      +----------|----+
#  |     type -|   |  /---|---> type-/    |
#  +---------------+  |   +---------------+
#  |     data -----|--/   |     data -----|-----> The data we want
#  +---------------+      +---------------+
#    We start here
#

function resolvemodifier_llvm{s,targs}(builder,
        t::Type{CppValue{s,targs}}, v::pcpp"llvm::Value")
    @assert v != C_NULL
    ty = cpptype(t)
    if !isPointerType(getType(v))
        dump(v)
        error("Value is not of pointer type")
    end
    # Get the array
    array = CreateConstGEP1_32(builder,v,1)
    arrayp = CreateLoad(builder,
        CreateBitCast(builder,array,getPointerTo(getType(array))))
    # Get the data pointer
    data = CreateConstGEP1_32(builder,arrayp,1)
    dp = CreateBitCast(builder,data,getPointerTo(getPointerTo(tollvmty(ty))))
    # A pointer to the actual data
    CreateLoad(builder,dp)
end

# # # Section 2: CodeGen
#
# # Overview
#
# To build perform code generation, we do the following.
#
# 1. Create an LLVM function that will be passed to llvmcall. (llvmargs)
#
# The argument types of the LLVM function will still be julia representation
# of the underlying values and potentially any modifiers. This is taken care
# of by the resolvemodifier_llvm function above which is called by `llvmargs`
# below.
# The reason for this mostly historic and could be simplified,
# though some LLVM-level processing will always be necessary.
#
# 2. Create Clang-level ParmVarDecls (buildargexprs)
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
# 3. Hook up the LLVM level representation to Clang's (associateargs)
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
function llvmargs(builder, f, argt)
    args = Array(pcpp"llvm::Value", length(argt))
    for i in 1:length(argt)
        t = argt[i]
        args[i] = pcpp"llvm::Value"(ccall(
            (:get_nth_argument,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),f,i-1))
        @assert args[i] != C_NULL
        args[i] = resolvemodifier_llvm(builder, t, args[i])
        if args[i] == C_NULL
            error("Failed to process argument")
        end
    end
    args
end

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

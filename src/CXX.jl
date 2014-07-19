# CXXFFI - The Julia C++ FFI
#
# This file contains the julia parts of the C++ FFI.
# For bootstrapping purposes, there is a small C++ shim
# that we will call out to. In general I try to keep the amount of
# code duplication on the julia side to a minimum, even if this
# means having more code on the C++ side (the original version
# had a messy 4 step bootstrap process).
#
#
# The main interface provided by this file is the @cpp macro.
# The following usages are currently supportd.
#
#   - Stactic function call
#       @cpp mynamespace::func(args...)
#   - Membercall (where m is a CppPtr, CppRef or CppValue)
#       @cp m->foo(args...)
#
# Note that unary * inside a call, e.g. @cpp foo(*a) is treated as
# a (C++ side) derefence of a.

using Base.Meta
import Base: ==
import Base.Intrinsics.llvmcall

# # # Bootstap initialization

const libcxxffi = joinpath(dirname(Base.source_path()),string("../deps/usr/lib/libcxxffi",
    ccall(:jl_is_debugbuild, Cint, ()) != 0 ? "-debug" : ""))

function init()
    ccall((:init_julia_clang_env,libcxxffi),Void,())
    ccall((:init_header,libcxxffi),Void,(Ptr{Uint8},),joinpath(dirname(Base.source_path()),"test.h"))
end
init()

# # # Types we will use to represent C++ values

# The equiavlent of a C++ T<targs...> *
immutable CppPtr{T,targs}
    ptr::Ptr{Void}
end

==(p1::CppPtr,p2::Ptr) = p1.ptr == p2
==(p1::Ptr,p2::CppPtr) = p1 == p2.ptr

# The equiavlent of a C++ T<targs...> &
immutable CppRef{T,targs}
    ptr::Ptr{Void}
end

# The equiavlent of a C++ T<targs...>
immutable CppValue{T,targs}
    data::Vector{Uint8}
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

macro pcpp_str(s)
    CppPtr{symbol(s),()}
end

macro rcpp_str(s)
    CppRef{symbol(s),()}
end

macro vcpp_str(s)
    CppValue{symbol(s),()}
end


import Base: cconvert

cconvert(::Type{Ptr{Void}},p::CppPtr) = p.ptr
cconvert(::Type{Ptr{Void}},p::CppRef) = p.ptr

# Bootstrap definitions
pointerTo(t::pcpp"clang::Type") = pcpp"clang::Type"(ccall((:getPointerTo,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))
referenceTo(t::pcpp"clang::Type") = pcpp"clang::Type"(ccall((:getReferenceTo,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))

tovdecl(p::pcpp"clang::Decl") = pcpp"clang::ValueDecl"(ccall((:tovdecl,libcxxffi),Ptr{Void},(Ptr{Void},),p.ptr))
tovdecl(p::pcpp"clang::ParmVarDecl") = pcpp"clang::ValueDecl"(p.ptr)

CreateDeclRefExpr(p::pcpp"clang::ValueDecl",ty::pcpp"clang::Type") = pcpp"clang::Expr"(ccall((:CreateDeclRefExpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),p.ptr,ty.ptr))
CreateDeclRefExpr(p,ty::pcpp"clang::Type") = CreateDeclRefExpr(tovdecl(p),ty)

CreateParmVarDecl(p::pcpp"clang::Type") = pcpp"clang::ParmVarDecl"(ccall((:CreateParmVarDecl,libcxxffi),Ptr{Void},(Ptr{Void},),p.ptr))

CreateMemberExpr(base::pcpp"clang::Expr",isarrow::Bool,member::pcpp"clang::ValueDecl") = pcpp"clang::Expr"(ccall((:CreateMemberExpr,libcxxffi),Ptr{Void},(Ptr{Void},Cint,Ptr{Void}),base.ptr,isarrow,member.ptr))
BuildCallToMemberFunction(me::pcpp"clang::Expr", args::Vector{pcpp"clang::Expr"}) = pcpp"clang::Expr"(ccall((:build_call_to_member,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        me.ptr,[arg.ptr for arg in args],length(args)))

BuildMemberReference(base, t, IsArrow, name) =
    pcpp"clang::Expr"(ccall((:BuildMemberReference,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Cint,Ptr{Uint8}),base, t, IsArrow, name))

DeduceReturnType(expr) = pcpp"clang::Type"(ccall((:DeduceReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),expr))

CreateFunction(rt,argt) = pcpp"llvm::Function"(ccall((:CreateFunction,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Csize_t),rt,argt,length(argt)))

ExtractValue(v::pcpp"llvm::Value",idx) = pcpp"llvm::Value"(ccall((:create_extract_value,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),v.ptr,idx))

tollvmty(t::pcpp"clang::Type") = pcpp"llvm::Type"(ccall((:tollvmty,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))

getTemplateArgs(tmplt::pcpp"clang::ClassTemplateSpecializationDecl") =
    rcpp"clang::TemplateArgumentList"(ccall((:getTemplateArgs,libcxxffi),Ptr{Void},(Ptr{Void},),tmplt))

getTargsSize(targs) =
 ccall((:getTargsSize,libcxxffi),Csize_t,(Ptr{Void},),targs)

getTargTypeAtIdx(targs, i) =
    pcpp"clang::Type"(ccall((:getTargTypeAtIdx,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),targs,i))

getUndefValue(t::pcpp"llvm::Type") =
    pcpp"llvm::Value"(ccall((:getUndefValue,libcxxffi),Ptr{Void},(Ptr{Void},),t))

getStructElementType(t::pcpp"llvm::Type",i) =
    pcpp"llvm::Type"(ccall((:getStructElementType,libcxxffi),Ptr{Void},(Ptr{Void},Uint32),t,i))

CreateRet(builder,val::pcpp"llvm::Value") =
    pcpp"llvm::Value"(ccall((:CreateRet,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),builder,val))

CreateRetVoid(builder) =
    pcpp"llvm::Value"(ccall((:CreateRetVoid,libcxxffi),Ptr{Void},(Ptr{Void},),builder))

CreateBitCast(builder,val,ty) =
    pcpp"llvm::Value"(ccall((:CreateBitCast,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Ptr{Void}),builder,val,ty))

BuildCXXTypeConstructExpr(t::pcpp"clang::Type", exprs::Vector{pcpp"clang::Expr"}) =
    pcpp"clang::Expr"(ccall((:typeconstruct,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        t,[expr.ptr for expr in exprs],length(exprs)))

cxxsizeof(t::pcpp"clang::CXXRecordDecl") = ccall((:cxxsizeof,libcxxffi),Csize_t,(Ptr{Void},),t)
cxxsizeof(t::pcpp"clang::Type") = ccall((:cxxsizeofType,libcxxffi),Csize_t,(Ptr{Void},),t)

createDerefExpr(e::pcpp"clang::Expr") = pcpp"clang::Expr"(ccall((:createDerefExpr,libcxxffi),Ptr{Void},(Ptr{Void},),e.ptr))

getType(v::pcpp"llvm::Value") = pcpp"llvm::Type"(ccall((:getValueType,libcxxffi),Ptr{Void},(Ptr{Void},),v))

isPointerType(t::pcpp"llvm::Type") = ccall((:isLLVMPointerType,libcxxffi),Cint,(Ptr{Void},),t) > 0

CreateConstGEP1_32(builder,x,idx) = pcpp"llvm::Value"(ccall((:CreateConstGEP1_32,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Uint32),builder,x,uint32(idx)))

getPointerTo(t::pcpp"llvm::Type") = pcpp"llvm::Type"(ccall((:getLLVMPointerTo,libcxxffi),Ptr{Void},(Ptr{Void},),t))

CreateLoad(builder,val::pcpp"llvm::Value") = pcpp"llvm::Value"(ccall((:createLoad,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),builder.ptr,val.ptr))

BuildDeclarationNameExpr(name, ctx::pcpp"clang::DeclContext") =
    pcpp"clang::Expr"(ccall((:BuildDeclarationNameExpr,libcxxffi),Ptr{Void},(Ptr{Uint8},Ptr{Void}),name,ctx))

getContext(decl::pcpp"clang::Decl") = pcpp"clang::DeclContext"(ccall((:getContext,libcxxffi),Ptr{Void},(Ptr{Void},),decl))

CreateCallExpr(Fn::pcpp"clang::Expr",args::Vector{pcpp"clang::Expr"}) = pcpp"clang::Expr"(
    ccall((:CreateCallExpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        Fn,[arg.ptr for arg in args],length(args)))

toLLVM(t::pcpp"clang::Type") = pcpp"llvm::Type"(ccall((:ConvertTypeForMem,libcxxffi),Ptr{Void},(Ptr{Void},),t))

getDirectCallee(t::pcpp"clang::CallExpr") = pcpp"clang::FunctionDecl"(ccall((:getDirectCallee,libcxxffi),Ptr{Void},(Ptr{Void},),t))
getCalleeReturnType(t::pcpp"clang::CallExpr") = pcpp"clang::Type"(ccall((:getCalleeReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),t))

const CK_Dependent      = 0
const CK_BitCast        = 1
const CK_LValueBitCast  = 2
const CK_LValueToRValue = 3
const CK_NoOp           = 4
const CK_BaseToDerived  = 5
const CK_DerivedToBase  = 6
const CK_UncheckedDerivedToBase = 7
const CK_Dynamic = 8
const CK_ToUnion = 9
const CK_ArrayToPointerDecay = 10
const CK_FunctionToPointerDecay = 11
const CK_NullToPointer = 12
const CK_NullToMemberPointer = 13
const CK_BaseToDerivedMemberPointer = 14
const CK_DerivedToBaseMemberPointer = 15
const CK_MemberPointerToBoolean = 16
const CK_ReinterpretMemberPointer = 17
const CK_UserDefinedConversion = 18
const CK_ConstructorConversion = 19
const CK_IntegralToPointer = 20
const CK_PointerToIntegral = 21
const CK_PointerToBoolean = 22
const CK_ToVoid = 23
const CK_VectorSplat = 24
const CK_IntegralCast = 25

createCast(arg,t,kind) = pcpp"clang::Expr"(ccall((:createCast,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Cint),arg,t,kind))
# Built-in clang types
chartype() = pcpp"clang::Type"(unsafe_load(cglobal((:cT_cchar,libcxxffi),Ptr{Void})))
cpptype(::Type{Uint8}) = chartype()#pcpp"clang::Type"(unsafe_load(cglobal(:cT_uint8,Ptr{Void})))
cpptype(::Type{Int8}) = pcpp"clang::Type"(unsafe_load(cglobal((:cT_int8,libcxxffi),Ptr{Void})))
cpptype(::Type{Uint32}) = pcpp"clang::Type"(unsafe_load(cglobal((:cT_uint32,libcxxffi),Ptr{Void})))
cpptype(::Type{Int32}) = pcpp"clang::Type"(unsafe_load(cglobal((:cT_int32,libcxxffi),Ptr{Void})))
cpptype(::Type{Uint64}) = pcpp"clang::Type"(unsafe_load(cglobal((:cT_uint64,libcxxffi),Ptr{Void})))
cpptype(::Type{Int64}) = pcpp"clang::Type"(unsafe_load(cglobal((:cT_int64,libcxxffi),Ptr{Void})))
cpptype(::Type{Bool}) = pcpp"clang::Type"(unsafe_load(cglobal((:cT_int1,libcxxffi),Ptr{Void})))
cpptype(::Type{Void}) = pcpp"clang::Type"(unsafe_load(cglobal((:cT_void,libcxxffi),Ptr{Void})))

# CXX Level Casting

for (rt,argt) in ((pcpp"clang::ClassTemplateSpecializationDecl",pcpp"clang::Decl"),
                  (pcpp"clang::CXXRecordDecl",pcpp"clang::Decl"))
    s = split(string(rt.parameters[1]),"::")[end]
    isas = symbol(string("isa",s))
    ds = symbol(string("dcast",s))
    # @cxx llvm::isa{$rt}(t)
    @eval $(isas)(t::$(argt)) = ccall($(quot(isas)),Int,(Ptr{Void},),t) != 0
    @eval $(ds)(t::$(argt)) = ($rt)(ccall($(quot(ds)),Ptr{Void},(Ptr{Void},),t))
end

# Clang Type* Bootstrap

for s in (:isVoidType,:isBooleanType,:isPointerType,:isReferenceType,
    :isCharType,:isIntegerType)
    @eval ($s)(t::pcpp"clang::Type") = ccall($(quot(s)),Int,(Ptr{Void},),t) != 0
end

for (r,s) in ((pcpp"clang::CXXRecordDecl",:getPointeeCXXRecordDecl),
              (pcpp"clang::CXXRecordDecl",:getAsCXXRecordDecl))
    @eval ($s)(t::pcpp"clang::Type") = ($(quot(r)))(ccall($(quot(s)),Ptr{Void},(Ptr{Void},),t))
end

# Main interface

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
            (!(t <: CppPtr) && !(t <: CppRef) && !(t <: CppValue) && !(t <: CppCast) && !in(t,
                [Bool, Uint8, Uint32, Uint64, Int64, Ptr{Void}, Ptr{Uint8}]))
            error("Got bad type information while compiling $f (got $t for argument $i)")
        end
    end
end

# # # Clang Level Decl Access

# Do C++ name lookup
translation_unit() = pcpp"clang::Decl"(ccall((:tu_decl,libcxxffi),Ptr{Void},()))

primary_ctx(p::pcpp"clang::DeclContext") =
    pcpp"clang::DeclContext"(p == C_NULL ? C_NULL : ccall((:get_primary_dc,libcxxffi),Ptr{Void},(Ptr{Void},),p))

toctx(p::pcpp"clang::Decl") =
    pcpp"clang::DeclContext"(p == C_NULL ? C_NULL : ccall((:decl_context,libcxxffi),Ptr{Void},(Ptr{Void},),p))

to_decl(p::pcpp"clang::DeclContext") =
    pcpp"clang::Decl"(p == C_NULL ? C_NULL : ccall((:to_decl,libcxxffi),Ptr{Void},(Ptr{Void},),p))

function lookup_name(fname::String, ctx::pcpp"clang::DeclContext")
    @assert ctx != C_NULL
    pcpp"clang::Decl"(
        ccall((:lookup_name,libcxxffi),Ptr{Void},(Ptr{Uint8},Ptr{Void}),bytestring(fname),ctx))
end

function lookup_name(parts)
    cur = translation_unit()
    for fpart in parts
        cur = lookup_name(fpart,primary_ctx(toctx(cur)))
        cur == C_NULL && error("Could not find $fpart as part of $(join(parts,"::")) lookup")
    end
    cur
end

lookup_ctx(fname::String) = lookup_name(split(fname,"::"))
lookup_ctx(fname::Symbol) = lookup_ctx(string(fname))

function specialize_template(cxxt::pcpp"clang::ClassTemplateDecl",targs,cpptype)
    @assert cxxt != C_NULL
    ts = pcpp"clang::Type"[cpptype(t) for t in targs]
    d = pcpp"clang::ClassTemplateSpecializationDecl"(ccall((:SpecializeClass,libcxxffi),Ptr{Void},
            (Ptr{Void},Ptr{Void},Uint32),cxxt.ptr,[p.ptr for p in ts],length(ts)))
    d
end

function cppdecl(fname,targs)
    # Let's get a clang level representation of this type
    ctx = lookup_ctx(fname)

    # If this is a templated class, we need to do template
    # resolution
    cxxt = cxxtmplt(ctx)
    if cxxt != C_NULL
        ts = map(cpptype,targs)
        deduced_class = specialize_template(cxxt,targs,cpptype)
        ctx = deduced_class
    end

    ctx
end
cppdecl{fname,targs}(::Union(Type{CppPtr{fname,targs}}, Type{CppValue{fname,targs}},
    Type{CppRef{fname,targs}})) = cppdecl(fname,targs)

# @cpp (@cpp dyn_cast{vcpp"clang::TypeDecl"}(d))->getTypeForDecl()
typeForDecl(d::pcpp"clang::Decl") = pcpp"clang::Type"(ccall((:typeForDecl,libcxxffi),Ptr{Void},(Ptr{Void},),d))
typeForDecl(d::pcpp"clang::CXXRecordDecl") = typeForDecl(pcpp"clang::Decl"(d.ptr))
typeForDecl(d::pcpp"clang::ClassTemplateSpecializationDecl") = typeForDecl(pcpp"clang::Decl"(d.ptr))

cpptype{s,t}(p::Type{CppPtr{s,t}}) = pointerTo(typeForDecl(cppdecl(p)))
cpptype{T<:CppPtr}(p::Type{CppPtr{T,()}}) = pointerTo(cpptype(T))
cpptype{s,t}(p::Type{CppValue{s,t}}) = typeForDecl(cppdecl(p))
cpptype{s,t}(p::Type{CppRef{s,t}}) = referenceTo(typeForDecl(cppdecl(p)))
cpptype{T}(p::Type{Ptr{T}}) = pointerTo(cpptype(T))

function _decl_name(d)
    @assert d != C_NULL
    s = ccall((:decl_name,libcxxffi),Ptr{Uint8},(Ptr{Void},),d)
    ret = bytestring(s)
    c_free(s)
    ret
end

function simple_decl_name(d)
    s = ccall((:simple_decl_name,libcxxffi),Ptr{Uint8},(Ptr{Void},),d)
    ret = bytestring(s)
    c_free(s)
    ret
end

get_pointee_name(t) = _decl_name(getPointeeCXXRecordDecl(t))
get_name(t) = _decl_name(getAsCXXRecordDecl(t))

function juliatype(t::pcpp"clang::Type")
    if isVoidType(t)
        return Void
    elseif isBooleanType(t)
        return Bool
    elseif isPointerType(t)
        cxxd = getPointeeCXXRecordDecl(t)
        if cxxd != C_NULL
            return CppPtr{symbol(get_pointee_name(t)),()}
        else
            pt = pcpp"clang::Type"(ccall((:referenced_type,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))
            tt = juliatype(pt)
            if tt <: CppPtr
                return CppPtr{tt,()}
            else
                return Ptr{tt}
            end
        end
    elseif isReferenceType(t)
        t = pcpp"clang::Type"(ccall((:referenced_type,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))
        return CppRef{symbol(get_name(t)),()}
    elseif isCharType(t)
        return Uint8
    elseif isIntegerType(t)
        if t == cpptype(Int64)
            return Int64
        elseif t == cpptype(Uint64)
            return Uint64
        elseif t == cpptype(Uint32)
            return Uint32
        elseif t == cpptype(Int32)
            return Int32
        elseif t == cpptype(Uint8) || t == chartype()
            return Uint8
        elseif t == cpptype(Int8)
            return Int8
        end
        # This is wrong. Might be any int. Need to access the BuiltinType::Kind Enum
        return Int
    else
        rd = getAsCXXRecordDecl(t)
        if rd.ptr != C_NULL
            targt = ()
            if isaClassTemplateSpecializationDecl(pcpp"clang::Decl"(rd.ptr))
                tmplt = dcastClassTemplateSpecializationDecl(pcpp"clang::Decl"(rd.ptr))
                targs = getTemplateArgs(tmplt)
                args = pcpp"clang::Type"[]
                for i = 0:(getTargsSize(targs)-1)
                    push!(args,getTargTypeAtIdx(targs,i))
                end
                targt = tuple(map(juliatype,args)...)
            end
            return CppValue{symbol(get_name(t)),targt}
        end
    end
    return Ptr{Void}
end

julia_to_llvm(x::ANY) = pcpp"llvm::Type"(ccall(:julia_type_to_llvm,Ptr{Void},(Any,),x))
# Various clang conversions (bootstrap definitions)

# @cxx llvm::dyn_cast{vcpp"clang::ClassTemplateDecl"}
cxxtmplt(p::pcpp"clang::Decl") = pcpp"clang::ClassTemplateDecl"(ccall((:cxxtmplt,libcxxffi),Ptr{Void},(Ptr{Void},),p))

stripmodifier{s,targs}(p::Union(Type{CppPtr{s,targs}},
    Type{CppRef{s,targs}}, Type{CppValue{s,targs}})) = p
stripmodifier{T,To}(p::Type{CppCast{T,To}}) = T
stripmodifier{T}(p::Type{CppDeref{T}}) = T
stripmodifier{T}(p::Type{Ptr{T}}) = Ptr{T}
stripmodifier(p::Union(Type{Bool},Type{Int64},Type{Uint32})) = p

resolvemodifier{s,targs}(p::Union(Type{CppPtr{s,targs}}, Type{CppRef{s,targs}},
    Type{CppValue{s,targs}}), e::pcpp"clang::Expr") = e
resolvemodifier(p::Union(Type{Bool},Type{Int64}, Type{Uint32}), e::pcpp"clang::Expr") = e
resolvemodifier{T}(p::Type{Ptr{T}}, e::pcpp"clang::Expr") = e
resolvemodifier{T,To}(p::Type{CppCast{T,To}}, e::pcpp"clang::Expr") =
    createCast(e,cpptype(To),CK_BitCast)
resolvemodifier{T}(p::Type{CppDeref{T}}, e::pcpp"clang::Expr") =
    createDerefExpr(e)

resolvemodifier_llvm{s,targs}(builder, t::Type{CppCast{s,targs}}, v::pcpp"llvm::Value") =
    resolvemodifier_llvm(builder, t.parameters[1], ExtractValue(v,0))

resolvemodifier_llvm{s,targs}(builder, t::Union(Type{CppPtr{s,targs}}, Type{CppRef{s,targs}}),
        v::pcpp"llvm::Value") = ExtractValue(v,0)

resolvemodifier_llvm{ptr}(builder, t::Type{Ptr{ptr}}, v::pcpp"llvm::Value") = v
resolvemodifier_llvm(builder, t::Union(Type{Int64},Type{Uint32},Type{Bool}), v::pcpp"llvm::Value") = v
#resolvemodifier_llvm(builder, t::Type{Uint8}, v::pcpp"llvm::Value") = v

function resolvemodifier_llvm{s,targs}(builder, t::Type{CppValue{s,targs}}, v::pcpp"llvm::Value")
    ty = cpptype(t)
    @assert isPointerType(getType(v))
    # Get the array
    array = CreateConstGEP1_32(builder,v,1)
    arrayp = CreateLoad(builder,CreateBitCast(builder,array,getPointerTo(getType(array))))
    # Get the data pointer
    data = CreateConstGEP1_32(builder,arrayp,1)
    dp = CreateBitCast(builder,data,getPointerTo(getPointerTo(tollvmty(ty))))
    # A pointer to the actual data
    CreateLoad(builder,dp)
end

# LLVM-level manipulation
function llvmargs(builder, f, argt)
    args = Array(pcpp"llvm::Value", length(argt))
    for i in 1:length(argt)
        t = argt[i]
        args[i] = pcpp"llvm::Value"(ccall((:get_nth_argument,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),f,i-1))
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
        expr = CreateDeclRefExpr(argpvd,argit)
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


AssociateValue(d::pcpp"clang::ParmVarDecl", ty::pcpp"clang::Type", V::pcpp"llvm::Value") = ccall((:AssociateValue,libcxxffi),Void,(Ptr{Void},Ptr{Void},Ptr{Void}),d,ty,V)

irbuilder() = pcpp"clang::CodeGen::CGBuilderTy"(ccall((:clang_get_builder,libcxxffi),Ptr{Void},()))

# # # Staging

# Main implementation.
# The two staged functions cppcall and cppcall_member below just change
# the thiscall flag depending on which ones is called.

setup_cpp_env(f::pcpp"llvm::Function") = ccall((:setup_cpp_env,libcxxffi),Ptr{Void},(Ptr{Void},),f)
cleanup_cpp_env(state) = ccall((:cleanup_cpp_env,libcxxffi),Void,(Ptr{Void},),state)

dump(d::pcpp"clang::Decl") = ccall((:cdump,libcxxffi),Void,(Ptr{Void},),d)
dump(d::pcpp"clang::FunctionDecl") = ccall((:cdump,libcxxffi),Void,(Ptr{Void},),d)
dump(expr::pcpp"clang::Expr") = ccall((:exprdump,libcxxffi),Void,(Ptr{Void},),expr)
dump(t::pcpp"clang::Type") = ccall((:typedump,libcxxffi),Void,(Ptr{Void},),t)

function _cppcall(expr, thiscall, argt)
    check_args(argt, expr)

    pvds = pcpp"clang::ParmVarDecl"[]

    rslot = C_NULL
    fname = string(expr.parameters[1])

    if thiscall
        # Create an expression to refer to the `this` parameter.
        ct = cpptype(argt[1])
        if argt[1] <: CppValue
            # We want the this argument to be modified in place,
            # so we make a deref of the pointer to the
            # data.
            pct = pointerTo(ct)
            pvd = CreateParmVarDecl(pct)
            push!(pvds, pvd)
            dre = createDerefExpr(CreateDeclRefExpr(pvd,pct))
        else
            pvd = CreateParmVarDecl(ct)
            push!(pvds, pvd)
            dre = CreateDeclRefExpr(pvd,ct)
        end
        me = BuildMemberReference(dre, ct, argt[1] <: CppPtr, fname)

        if me == C_NULL
            error("Could not find member function $fname")
        end

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
        llvmargt = argt

        @show rett
        @show llvmrt

        # Let's create an LLVM fuction
        f = CreateFunction(llvmrt,
            map(julia_to_llvm,[argt...]))

        # Clang's code emitter needs some extra information about the function, so let's
        # initialize that as well
        state = setup_cpp_env(f)

        builder = irbuilder()

        # First compute the llvm arguments (unpacking them from their julia wrappers),
        # then associate them with the clang level variables
        args = llvmargs(builder, f, argt)
        associateargs(builder,argt,args,pvds)

        ret = pcpp"llvm::Value"(ccall((:emitcppmembercallexpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),mce.ptr,rslot))

        #if jlrslot != C_NULL && rslot != C_NULL && (length(args) == 0 || rslot != args[1])
        #    @cpp1 builder->CreateRet(pcpp"llvm::Value"(jlrslot.ptr))
        #else

        #return createReturn(builder,f,argt,llvmrt,rt,ret,state)
    else
        d = lookup_ctx(fname)
        @assert d.ptr != C_NULL
        # If this is a typedef or something we'll try to get the primary one
        primary_decl = to_decl(primary_ctx(toctx(d)))
        if primary_decl != C_NULL
            d = primary_decl
        end
        # Let's see if we're constructing something. And, if so, let's
        # setup an array to accept the result
        cxxd = dcastCXXRecordDecl(d)
        cxxt = cxxtmplt(d)
        if cxxd != C_NULL || cxxt != C_NULL
            targs = expr.parameters[2]
            T = CppValue{symbol(fname),tuple(targs...)}
            if cxxd == C_NULL
                cxxd = specialize_template(cxxt,targs,cpptype)
            end
            juliart = T

            # The arguments to llvmcall will have an extra
            # argument for the return slot
            llvmargt = [Ptr{Uint8},argt...]

            # And now the expressions for all the arguments
            callargs, callpvds = buildargexprs(argt)
            append!(pvds, callpvds)

            # Let's create an LLVM fuction
            f = CreateFunction(julia_to_llvm(Void),
                map(julia_to_llvm,map(stripmodifier,llvmargt)))

            state = setup_cpp_env(f)
            builder = irbuilder()

            # First compute the llvm arguments (unpacking them from their julia wrappers),
            # then associate them with the clang level variables
            args = llvmargs(builder, f, llvmargt)
            associateargs(builder,argt,args[2:end],pvds)

            ctce = BuildCXXTypeConstructExpr(typeForDecl(cxxd),callargs)

            ccall((:emitexprtomem,libcxxffi),Void,(Ptr{Void},Ptr{Void},Cint),ctce,args[1],1)
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
        else
            myctx = getContext(d)
            dne = BuildDeclarationNameExpr(split(fname,"::")[end],myctx)

            # And now the expressions for all the arguments
            callargs, callpvds = buildargexprs(argt)
            append!(pvds, callpvds)

            ce = CreateCallExpr(dne,callargs)

            # First we need to get the return type of the C++ expression
            rt = DeduceReturnType(ce)
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

            ret = pcpp"llvm::Value"(ccall((:emitcallexpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),ce,rslot))

            if rett <: CppValue
                ret = C_NULL
            end
            #return createReturn(builder,f,argt,llvmrt,rt,ret,state)
        end
    end

    # Common return path for everything that's calling a normal function
    # (i.e. everything but constructors)
    jlrt = rett
    if ret == C_NULL
        jlrt = Void
        CreateRetVoid(builder)
    else
        #@show rett
        if rett == Void
            CreateRetVoid(builder)
        else
            if rett <: CppPtr || rett <: CppRef
                undef = getUndefValue(llvmrt)
                elty = getStructElementType(llvmrt,0)
                ret = CreateBitCast(builder,ret,elty)
                ret = pcpp"llvm::Value"(ccall((:create_insert_value,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Csize_t),undef.ptr,ret.ptr,0))
            end
            CreateRet(builder,ret)
        end
    end

    cleanup_cpp_env(state)

    if (rett != None) && rett <: CppValue
        arguments = [:(pointer(r.data)), [:(args[$i]) for i = 1:length(argt)]]
        size = cxxsizeof(rt)
        return Expr(:block,
            :( r = ($(rett))(Array(Uint8,$size)) ),
            Expr(:call,:llvmcall,f.ptr,Void,tuple(llvmargt...),arguments...),
            :r)
    else
        return Expr(:call,:llvmcall,f.ptr,rett,argt,
            [:(args[$i]) for i = 1:length(argt)]...)
    end

end

stagedfunction cppcall(expr, args...)
    _cppcall(expr, false, args)
end

stagedfunction cppcall_member(expr, args...)
    _cppcall(expr, true, args)
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
#   - @cpp foo::bar::baz(a,b,c)
#       - cexpr == :( baz(a,bc) )
#       - this === nothing
#       - prefix == "foo::bar"
#   - @cpp m->DoSomething(a,b,c)
#       - cexpr == :( DoSomething(a,b,c) )
#       - this == :( m )
#       - prefix = ""
#
function build_cpp_call(cexpr, this, prefix = "")
    @assert isexpr(cexpr,:call)
    targs = []

    # Turn prefix and call expression, back into a fully qualified name
    # (and optionally type arguments)
    if isexpr(cexpr.args[1],:curly)
        fname = string(prefix, cexpr.args[1].args[1])
        targs = map(macroexpand, copy(cexpr.args[1].args[2:end]))
    else
        fname = string(prefix, cexpr.args[1])
        targs = ()
    end

    arguments = cexpr.args[2:end]

    # Unary * is treated as a deref
    for (i, arg) in enumerate(arguments)
        if isexpr(arg,:call)
            # is unary *
            if length(arg.args) == 2 && arg.args[1] == :*
                arguments[i] = :( CppDeref($arg) )
            end
        end
    end

    # Add `this` as the first argument
    this !== nothing && unshift!(arguments, this)

    # The actual call to the staged function
    ret = Expr(:call, this === nothing ? :cppcall : :cppcall_member,
        :(CppExpr{$(quot(symbol(fname))),$(quot(targs))}()), arguments...)

    ret
end

function to_prefix(expr)
    if isa(expr,Symbol)
        return string(expr)
    elseif isexpr(expr,:(::))
        return string(to_prefix(expr.args[1]),"::",to_prefix(expr.args[2]))
    end
    error("Invalid NSS $expr")
end

function cpps_impl(expr,prefix="")
    # Expands a->b to
    # llvmcall((cpp_member,typeof(a),"b"))
    if isa(expr,Symbol)
        error("Unfinished")
        return cpp_ref(expr,prefix,uuid)
    elseif expr.head == :(->)
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
            return build_cpp_call(b,a)
        else
            error("Unsupported!")
        end
    elseif isexpr(expr,:(=))
        error("Unimplemented")
    elseif isexpr(expr,:(::))
        return cpps_impl(expr.args[2],string(to_prefix(expr.args[1]),"::"))
    elseif isexpr(expr,:call)
        return build_cpp_call(expr,nothing,prefix)
    end
    error("Unrecognized CPP Expression ",expr," (",expr.head,")")
end

macro cxx(expr)
    cpps_impl(expr)
end

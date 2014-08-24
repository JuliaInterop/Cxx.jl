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

push!(DL_LOAD_PATH, joinpath(dirname(Base.source_path()),"../deps/usr/lib/"))

const libcxxffi = string("libcxxffi", ccall(:jl_is_debugbuild, Cint, ()) != 0 ? "-debug" : "")

function init()
    # Force libcxxffi to be opened with RTLD_GLOBAL
    dlopen(libcxxffi, RTLD_GLOBAL)
    ccall((:init_julia_clang_env,libcxxffi),Void,())
end
init()

function cxxinclude(fname; dir = Base.source_path() === nothing ? pwd() : dirname(Base.source_path()), isAngled = false)
    if ccall((:cxxinclude, libcxxffi), Cint, (Ptr{Uint8}, Ptr{Uint8} ,Cint),
        fname, dir, isAngled) == 0
        error("Could not include file $fname")
    end
end

function cxxparse(string)
    if ccall((:cxxparse, libcxxffi), Cint, (Ptr{Uint8}, Csize_t), string, sizeof(string)) == 0
        error("Could not parse string")
    end
end

const C_User            = 0
const C_System          = 1
const C_ExternCSystem   = 2

function addHeaderDir(dirname; kind = C_User, isFramework = false)
    ccall((:add_directory, libcxxffi), Void, (Cint, Cint, Ptr{Uint8}), kind, isFramework, dirname)
end

function defineMacro(Name)
    ccall((:defineMacro, libcxxffi), Void, (Ptr{Uint8},), Name)
end

# Setup Search Paths

basepath = joinpath(JULIA_HOME, "../../")

@osx_only begin
    xcode_path =
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/"
    addHeaderDir(joinpath(xcode_path,"usr/lib/c++/v1/"), kind = C_ExternCSystem)
end

@linux_only begin
    addHeaderDir("/usr/include/c++/4.8", kind = C_System);
    addHeaderDir("/usr/include/x86_64-linux-gnu/c++/4.8/", kind = C_System);
    addHeaderDir("/usr/include", kind = C_System);
    addHeaderDir("/usr/include/x86_64-linux-gnu", kind = C_System);
end

@windows_only begin
  base = "C:/mingw-builds/x64-4.8.1-win32-seh-rev5/mingw64/"
  addHeaderDir(joinpath(base,"x86_64-w64-mingw32/include"), kind = C_System)
  #addHeaderDir(joinpath(base,"lib/gcc/x86_64-w64-mingw32/4.8.1/include/"), kind = C_System)
  addHeaderDir(joinpath(base,"lib/gcc/x86_64-w64-mingw32/4.8.1/include/c++"), kind = C_System)
  addHeaderDir(joinpath(base,"lib/gcc/x86_64-w64-mingw32/4.8.1/include/c++/x86_64-w64-mingw32"), kind = C_System)
end

addHeaderDir(joinpath(basepath,"usr/lib/clang/3.6.0/include/"), kind = C_ExternCSystem)
cxxinclude("stdint.h",isAngled = true)

# # # Types we will use to represent C++ values

# TODO: Maybe use Ptr{CppValue} and Ptr{CppFunc} instead?

# The equiavlent of a C++ T<targs...> *
immutable CppPtr{T,targs}
    ptr::Ptr{Void}
end

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

# Represent a C++ addrof (&foo)
immutable CppAddr{T}
    val::T
end
CppAddr{T}(val::T) = CppAddr{T}(val)

# Represent a C/C++ Enum
immutable CppEnum{T}
    val::Int32
end

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

CreateDeclRefExpr(p::pcpp"clang::ValueDecl"; islvalue=true, nnsbuilder=C_NULL
    ) = pcpp"clang::Expr"(ccall((:CreateDeclRefExpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Cint),p.ptr,nnsbuilder,islvalue))
CreateDeclRefExpr(p; nnsbuilder=C_NULL, islvalue=true) = CreateDeclRefExpr(tovdecl(p);islvalue=islvalue,nnsbuilder=nnsbuilder)

CreateParmVarDecl(p::pcpp"clang::Type") = pcpp"clang::ParmVarDecl"(ccall((:CreateParmVarDecl,libcxxffi),Ptr{Void},(Ptr{Void},),p.ptr))
CreateVarDecl(DC::pcpp"clang::DeclContext",name,T::pcpp"clang::Type") = pcpp"clang::VarDecl"(ccall((:CreateVarDecl,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Uint8},Ptr{Void}),DC,name,T))

CreateMemberExpr(base::pcpp"clang::Expr",isarrow::Bool,member::pcpp"clang::ValueDecl") = pcpp"clang::Expr"(ccall((:CreateMemberExpr,libcxxffi),Ptr{Void},(Ptr{Void},Cint,Ptr{Void}),base.ptr,isarrow,member.ptr))
BuildCallToMemberFunction(me::pcpp"clang::Expr", args::Vector{pcpp"clang::Expr"}) = pcpp"clang::Expr"(ccall((:build_call_to_member,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        me.ptr,[arg.ptr for arg in args],length(args)))

BuildMemberReference(base, t, IsArrow, name) =
    pcpp"clang::Expr"(ccall((:BuildMemberReference,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Cint,Ptr{Uint8}),base, t, IsArrow, name))

DeduceReturnType(expr) = pcpp"clang::Type"(ccall((:DeduceReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),expr))

CreateFunction(rt,argt) = pcpp"llvm::Function"(ccall((:CreateFunction,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Csize_t),rt,argt,length(argt)))

ExtractValue(v::pcpp"llvm::Value",idx) = pcpp"llvm::Value"(ccall((:create_extract_value,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),v.ptr,idx))
InsertValue(builder, into::pcpp"llvm::Value", v::pcpp"llvm::Value", idx) =
    pcpp"llvm::Value"(ccall((:create_insert_value,libcxxffi),Ptr{Void},
        (Ptr{Void},Ptr{Void},Ptr{Void},Csize_t),builder,into,v,idx))

tollvmty(t::pcpp"clang::Type") = pcpp"llvm::Type"(ccall((:tollvmty,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))

getTemplateArgs(tmplt::pcpp"clang::ClassTemplateSpecializationDecl") =
    rcpp"clang::TemplateArgumentList"(ccall((:getTemplateArgs,libcxxffi),Ptr{Void},(Ptr{Void},),tmplt))

getTargsSize(targs) =
 ccall((:getTargsSize,libcxxffi),Csize_t,(Ptr{Void},),targs)

getTargTypeAtIdx(targs, i) =
    pcpp"clang::Type"(ccall((:getTargTypeAtIdx,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),targs,i))

getTargKindAtIdx(targs, i) =
    ccall((:getTargKindAtIdx,libcxxffi),Cint,(Ptr{Void},Csize_t),targs,i)

getTargAsIntegralAtIdx(targs, i) =
    ccall((:getTargAsIntegralAtIdx,libcxxffi),Int64,(Ptr{Void},Csize_t),targs,i)

getTargIntegralTypeAtIdx(targs, i) =
    pcpp"clang::Type"(ccall((:getTargIntegralTypeAtIdx,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),targs,i))

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

#BuildCXXNewExpr(E::pcpp"clang::Expr") = pcpp"clang::Expr"(ccall((:BuildCXXNewExpr,libcxxffi),Ptr{Void},(Ptr{Void},),E))
BuildCXXNewExpr(T::pcpp"clang::Type",exprs::Vector{pcpp"clang::Expr"}) =
    pcpp"clang::Expr"(ccall((:BuildCXXNewExpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        T,[expr.ptr for expr in exprs],length(exprs)))

EmitCXXNewExpr(E::pcpp"clang::Expr") = pcpp"llvm::Value"(ccall((:EmitCXXNewExpr,libcxxffi),Ptr{Void},(Ptr{Void},),E))
EmitAnyExpr(E::pcpp"clang::Expr") = pcpp"llvm::Value"(ccall((:EmitAnyExpr,libcxxffi),Ptr{Void},(Ptr{Void},),E))

EmitAnyExprToMem(expr,mem,isInit) = ccall((:emitexprtomem,libcxxffi),Void,(Ptr{Void},Ptr{Void},Cint),expr,mem,isInit)

cxxsizeof(t::pcpp"clang::CXXRecordDecl") = ccall((:cxxsizeof,libcxxffi),Csize_t,(Ptr{Void},),t)
cxxsizeof(t::pcpp"clang::Type") = ccall((:cxxsizeofType,libcxxffi),Csize_t,(Ptr{Void},),t)

createDerefExpr(e::pcpp"clang::Expr") = pcpp"clang::Expr"(ccall((:createDerefExpr,libcxxffi),Ptr{Void},(Ptr{Void},),e.ptr))
CreateAddrOfExpr(e::pcpp"clang::Expr") = pcpp"clang::Expr"(ccall((:createAddrOfExpr,libcxxffi),Ptr{Void},(Ptr{Void},),e.ptr))

MarkMemberReferenced(me::pcpp"clang::Expr") = ccall((:MarkMemberReferenced,libcxxffi),Void,(Ptr{Void},),me)
MarkAnyDeclReferenced(d::pcpp"clang::Decl") = ccall((:MarkAnyDeclReferenced,libcxxffi),Void,(Ptr{Void},),d)
MarkAnyDeclReferenced(d::pcpp"clang::CXXRecordDecl") = MarkAnyDeclReferenced(pcpp"clang::Decl"(d.ptr))
MarkDeclarationsReferencedInExpr(e::pcpp"clang::Expr") = ccall((:MarkDeclarationsReferencedInExpr,libcxxffi),Void,(Ptr{Void},),e)
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

newNNSBuilder() = pcpp"clang::NestedNameSpecifierLocBuilder"(ccall((:newNNSBuilder,libcxxffi),Ptr{Void},()))
deleteNNSBuilder(b::pcpp"clang::NestedNameSpecifierLocBuilder") = ccall((:deleteNNSBuilder,libcxxffi),Void,(Ptr{Void},),b)

ExtendNNS(b::pcpp"clang::NestedNameSpecifierLocBuilder", ns::pcpp"clang::NamespaceDecl") =
    ccall((:ExtendNNS,libcxxffi),Void,(Ptr{Void},Ptr{Void}),b,ns)

ExtendNNSIdentifier(b::pcpp"clang::NestedNameSpecifierLocBuilder", name) =
    ccall((:ExtendNNS,libcxxffi),Void,(Ptr{Void},Ptr{Uint8}),b,name)

makeFunctionType(rt::pcpp"clang::Type", args::Vector{pcpp"clang::Type"}) =
    pcpp"clang::Type"(ccall((:makeFunctionType,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Csize_t),rt,args,length(args)))

makeMemberFunctionType(FT::pcpp"clang::Type", class::pcpp"clang::Type") =
    pcpp"clang::Type"(ccall((:makeMemberFunctionType, libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),FT,class))

getMemberPointerClass(mptr::pcpp"clang::Type") =
    pcpp"clang::Type"(ccall((:getMemberPointerClass, libcxxffi),Ptr{Void},(Ptr{Void},),mptr))

getMemberPointerPointee(mptr::pcpp"clang::Type") =
    pcpp"clang::Type"(ccall((:getMemberPointerPointee, libcxxffi),Ptr{Void},(Ptr{Void},),mptr))

getReturnType(ft::pcpp"clang::FunctionProtoType") =
    pcpp"clang::Type"(ccall((:getFPTReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),ft))
getNumParams(ft::pcpp"clang::FunctionProtoType") =
    ccall((:getFPTNumParams,libcxxffi),Csize_t,(Ptr{Void},),ft)
getParam(ft::pcpp"clang::FunctionProtoType", idx) =
    pcpp"clang::Type"(ccall((:getFPTParam,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),ft,idx))

getLLVMStructType(argts::Vector{pcpp"llvm::Type"}) =
    pcpp"llvm::Type"(ccall((:getLLVMStructType,libcxxffi), Ptr{Void}, (Ptr{Void},Csize_t), argts, length(argts)))

getConstantFloat(llvmt::pcpp"llvm::Type",x::Float64) = pcpp"llvm::Constant"(ccall((:getConstantFloat,libcxxffi),Ptr{Void},(Ptr{Void},Float64),llvmt,x))
getConstantInt(llvmt::pcpp"llvm::Type",x::Uint64) = pcpp"llvm::Constant"(ccall((:getConstantInt,libcxxffi),Ptr{Void},(Ptr{Void},Uint64),llvmt,x))
getConstantStruct(llvmt::pcpp"llvm::Type",x::Vector{pcpp"llvm::Constant"}) = pcpp"llvm::Constant"(ccall((:getConstantStruct,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),llvmt,x,length(x)))

getDirectCallee(t::pcpp"clang::CallExpr") = pcpp"clang::FunctionDecl"(ccall((:getDirectCallee,libcxxffi),Ptr{Void},(Ptr{Void},),t))
getCalleeReturnType(t::pcpp"clang::CallExpr") = pcpp"clang::Type"(ccall((:getCalleeReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),t))

isIncompleteType(t::pcpp"clang::Type") = pcpp"clang::NamedDecl"(ccall((:isIncompleteType,libcxxffi),Ptr{Void},(Ptr{Void},),t))

createNamespace(name) = pcpp"clang::NamespaceDecl"(ccall((:createNamespace,libcxxffi),Ptr{Void},(Ptr{Uint8},),bytestring(name)))

AddDeclToDeclCtx(DC::pcpp"clang::DeclContext",D::pcpp"clang::Decl") =
    ccall((:AddDeclToDeclCtx,libcxxffi),Void,(Ptr{Void},Ptr{Void}),DC,D)

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
                  (pcpp"clang::CXXRecordDecl",pcpp"clang::Decl"),
                  (pcpp"clang::NamespaceDecl",pcpp"clang::Decl"),
                  (pcpp"clang::VarDecl",pcpp"clang::Decl"))
    s = split(string(rt.parameters[1]),"::")[end]
    isas = symbol(string("isa",s))
    ds = symbol(string("dcast",s))
    # @cxx llvm::isa{$rt}(t)
    @eval $(isas)(t::$(argt)) = ccall(($(quot(isas)),libcxxffi),Int,(Ptr{Void},),t) != 0
    @eval $(ds)(t::$(argt)) = ($rt)(ccall(($(quot(ds)),libcxxffi),Ptr{Void},(Ptr{Void},),t))
end

# Clang Type* Bootstrap

for s in (:isVoidType,:isBooleanType,:isPointerType,:isReferenceType,
    :isCharType, :isIntegerType, :isFunctionPointerType, :isMemberFunctionPointerType,
    :isFunctionType, :isFunctionProtoType, :isEnumeralType)
                  @eval ($s)(t::pcpp"clang::Type") = ccall(($(quot(s)),libcxxffi),Int,(Ptr{Void},),t) != 0
end

for (r,s) in ((pcpp"clang::CXXRecordDecl",:getPointeeCXXRecordDecl),
              (pcpp"clang::CXXRecordDecl",:getAsCXXRecordDecl))
                  @eval ($s)(t::pcpp"clang::Type") = ($(quot(r)))(ccall(($(quot(s)),libcxxffi),Ptr{Void},(Ptr{Void},),t))
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
            (!(t <: CppPtr) && !(t <: CppRef) && !(t <: CppValue) && !(t <: CppCast) &&
                !(t <: CppFptr) && !(t <: CppMFptr) && !(t <: CppEnum) &&
                !(t <: CppDeref) && !(t <: CppAddr) && !(t <: Ptr) &&
                !in(t,[Bool, Uint8, Int32, Uint32, Int64, Uint64]))
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

function lookup_name(parts, nnsbuilder=C_NULL)
    cur = translation_unit()
    for fpart in parts
        if nnsbuilder != C_NULL
            if isaNamespaceDecl(cur)
                ExtendNNS(nnsbuilder, dcastNamespaceDecl(cur))
            else
                ExtendNNSIdentifier(nnsbuilder, fpart)
            end
        end
        cur = lookup_name(fpart,primary_ctx(toctx(cur)))
        cur == C_NULL && error("Could not find $fpart as part of $(join(parts,"::")) lookup")
    end
    cur
end

lookup_ctx(fname::String; nnsbuilder=C_NULL) = lookup_name(split(fname,"::"),nnsbuilder)
lookup_ctx(fname::Symbol; nnsbuilder=C_NULL) = lookup_ctx(string(fname); nnsbuilder=nnsbuilder)

function specialize_template(cxxt::pcpp"clang::ClassTemplateDecl",targs,cpptype)
    @assert cxxt != C_NULL
    integralValues = zeros(Uint64,length(targs))
    integralValuesPresent = zeros(Uint8,length(targs))
    bitwidths = zeros(Uint32,length(targs))
    ts = Array(pcpp"clang::Type",length(targs))
    for (i,t) in enumerate(targs)
        if isa(t,Type)
            ts[i] = cpptype(t)
        elseif isa(t,Integer) || isa(t,CppEnum)
            ts[i] = cpptype(typeof(t))
            integralValues[i] = convert(Uint64,isa(t,CppEnum) ? t.val : t)
            integralValuesPresent[i] = 1
            bitwidths[i] = isa(t,Bool) ? 8 : sizeof(typeof(t))
        else
            error("Unhandled template parameter type")
        end
    end
    d = pcpp"clang::ClassTemplateSpecializationDecl"(ccall((:SpecializeClass,libcxxffi),Ptr{Void},
            (Ptr{Void},Ptr{Void},Ptr{Uint64},Ptr{Uint32},Ptr{Uint8},Uint32),
            cxxt.ptr,[p.ptr for p in ts],integralValues,bitwidths,integralValuesPresent,length(ts)))
    d
end

function cppdecl(fname,targs)
    # Let's get a clang level representation of this type
    ctx = lookup_ctx(fname)

    # If this is a templated class, we need to do template
    # resolution
    cxxt = cxxtmplt(ctx)
    if cxxt != C_NULL
        deduced_class = specialize_template(cxxt,targs,cpptype)
        ctx = deduced_class
    end

    ctx
end
cppdecl{fname,targs}(::Union(Type{CppPtr{fname,targs}}, Type{CppValue{fname,targs}},
    Type{CppRef{fname,targs}})) = cppdecl(fname,targs)
cppdecl{s}(::Type{CppEnum{s}}) = cppdecl(s,())

# @cpp (@cpp dyn_cast{vcpp"clang::TypeDecl"}(d))->getTypeForDecl()
function typeForDecl(d::pcpp"clang::Decl")
    @assert d != C_NULL
    pcpp"clang::Type"(ccall((:typeForDecl,libcxxffi),Ptr{Void},(Ptr{Void},),d))
end
typeForDecl(d::pcpp"clang::CXXRecordDecl") = typeForDecl(pcpp"clang::Decl"(d.ptr))
typeForDecl(d::pcpp"clang::ClassTemplateSpecializationDecl") = typeForDecl(pcpp"clang::Decl"(d.ptr))

cpptype{s}(p::Type{CppEnum{s}}) = typeForDecl(cppdecl(p))
cpptype{s,t}(p::Type{CppPtr{s,t}}) = pointerTo(typeForDecl(cppdecl(p)))
cpptype{T<:CppPtr}(p::Type{CppPtr{T,()}}) = pointerTo(cpptype(T))
cpptype{s,t}(p::Type{CppValue{s,t}}) = typeForDecl(cppdecl(p))
cpptype{s,t}(p::Type{CppRef{s,t}}) = referenceTo(typeForDecl(cppdecl(p)))
cpptype{T}(p::Type{Ptr{T}}) = pointerTo(cpptype(T))
cpptype{base,fptr}(p::Type{CppMFptr{base,fptr}}) =
    makeMemberFunctionType(cpptype(base), cpptype(fptr))
cpptype{rt, args}(p::Type{CppFunc{rt,args}}) = makeFunctionType(cpptype(rt),pcpp"clang::Type"[cpptype(arg) for arg in args])
cpptype{f}(p::Type{CppFptr{f}}) = pointerTo(cpptype(f))

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
function get_name(t)
    d = getAsCXXRecordDecl(t)
    if d != C_NULL
        return _decl_name(d)
    end
    d = isIncompleteType(t)
    @assert d != C_NULL
    return _decl_name(d)
end

const KindNull              = 0
const KindType              = 1
const KindDeclaration       = 2
const KindNullPtr           = 3
const KindIntegral          = 4
const KindTemplate          = 5
const KindTemplateExpansion = 6
const KindExpression        = 7
const KindPack              = 8

function getTemplateParameters(cxxd)
    targt = ()
    if isaClassTemplateSpecializationDecl(pcpp"clang::Decl"(cxxd.ptr))
        tmplt = dcastClassTemplateSpecializationDecl(pcpp"clang::Decl"(cxxd.ptr))
        targs = getTemplateArgs(tmplt)
        args = Any[]
        for i = 0:(getTargsSize(targs)-1)
            kind = getTargKindAtIdx(targs,i)
            if kind == KindType
                push!(args,juliatype(getTargTypeAtIdx(targs,i)))
            elseif kind == KindIntegral
                val = getTargAsIntegralAtIdx(targs,i)
                t = getTargIntegralTypeAtIdx(targs,i)
                push!(args,convert(juliatype(t),val))
            else
                error("Unhandled template argument kind")
            end
        end
        targt = tuple(args...)
    end
    targt
end

function juliatype(t::pcpp"clang::Type")
    if isVoidType(t)
        return Void
    elseif isBooleanType(t)
        return Bool
    elseif isPointerType(t)
        cxxd = getPointeeCXXRecordDecl(t)
        if cxxd != C_NULL
            return CppPtr{symbol(get_pointee_name(t)),getTemplateParameters(cxxd)}
        else
            pt = pcpp"clang::Type"(ccall((:referenced_type,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))
            tt = juliatype(pt)
            if tt <: CppPtr
                return CppPtr{tt,()}
            else
                return Ptr{tt}
            end
        end
    elseif isFunctionPointerType(t)
        error("Is Function Pointer")
    elseif isFunctionType(t)
        if isFunctionProtoType(t)
            t = pcpp"clang::FunctionProtoType"(t.ptr)
            rt = getReturnType(t)
            args = pcpp"clang::Type"[]
            for i = 0:(getNumParams(t)-1)
                push!(args,getParam(t,i))
            end
            f = CppFunc{juliatype(rt), tuple(map(juliatype,args)...)}
            return f
        else
            error("Function has no proto type")
        end
    elseif isMemberFunctionPointerType(t)
        cxxd = getMemberPointerClass(t)
        pointee = getMemberPointerPointee(t)
        return CppMFptr{juliatype(cxxd),juliatype(pointee)}
    elseif isReferenceType(t)
        t = pcpp"clang::Type"(ccall((:referenced_type,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))
        return CppRef{symbol(get_name(t)),()}
    elseif isCharType(t)
        return Uint8
    elseif isEnumeralType(t)
        return CppEnum{symbol(get_name(t))}
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
            return CppValue{symbol(get_name(t)),getTemplateParameters(rd)}
        end
    end
    return Ptr{Void}
end

julia_to_llvm(x::ANY) = pcpp"llvm::Type"(ccall(:julia_type_to_llvm,Ptr{Void},(Any,),x))
# Various clang conversions (bootstrap definitions)

# @cxx llvm::dyn_cast{vcpp"clang::ClassTemplateDecl"}
cxxtmplt(p::pcpp"clang::Decl") = pcpp"clang::ClassTemplateDecl"(ccall((:cxxtmplt,libcxxffi),Ptr{Void},(Ptr{Void},),p))

const CxxBuiltinTypes = Union(Type{Bool},Type{Int64},Type{Int32},Type{Uint32},Type{Uint64})

stripmodifier{f}(cppfunc::Type{CppFptr{f}}) = cppfunc
stripmodifier{s,targs}(p::Union(Type{CppPtr{s,targs}},
    Type{CppRef{s,targs}}, Type{CppValue{s,targs}})) = p
stripmodifier{s}(p::Type{CppEnum{s}}) = p
stripmodifier{T,To}(p::Type{CppCast{T,To}}) = T
stripmodifier{T}(p::Type{CppDeref{T}}) = T
stripmodifier{T}(p::Type{CppAddr{T}}) = T
stripmodifier{base,fptr}(p::Type{CppMFptr{base,fptr}}) = p
stripmodifier{T}(p::Type{Ptr{T}}) = Ptr{T}
stripmodifier(p::CxxBuiltinTypes) = p

resolvemodifier{s,targs}(p::Union(Type{CppPtr{s,targs}}, Type{CppRef{s,targs}},
    Type{CppValue{s,targs}}), e::pcpp"clang::Expr") = e
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

resolvemodifier_llvm{s,targs}(builder, t::Type{CppCast{s,targs}}, v::pcpp"llvm::Value") =
    resolvemodifier_llvm(builder, t.parameters[1], ExtractValue(v,0))

resolvemodifier_llvm{s,targs}(builder, t::Union(Type{CppPtr{s,targs}}, Type{CppRef{s,targs}}),
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

function _cppcall(expr, thiscall, isnew, argt)
    check_args(argt, expr)

    pvds = pcpp"clang::ParmVarDecl"[]

    rslot = C_NULL
    fname = string(expr.parameters[1])

    rt = Void

    if thiscall
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
        #    @cpp1 builder->CreateRet(pcpp"llvm::Value"(jlrslot.ptr))
        #else

        if rett <: CppValue
            ret = C_NULL
        end

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
            llvmargt = [argt...]
            if !isnew
                llvmargt = [Ptr{Uint8}, llvmargt]
            end

            # And now the expressions for all the arguments
            callargs, callpvds = buildargexprs(argt)
            append!(pvds, callpvds)

            rett = Void
            if isnew
                rett = CppPtr{symbol(fname),()}
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
                nE = BuildCXXNewExpr(typeForDecl(cxxd),callargs)
                MarkDeclarationsReferencedInExpr(nE)
                ret = EmitCXXNewExpr(nE)
            else
                ctce = BuildCXXTypeConstructExpr(typeForDecl(cxxd),callargs)

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
            dne = BuildDeclarationNameExpr(split(fname,"::")[end],myctx)

            # And now the expressions for all the arguments
            callargs, callpvds = buildargexprs(argt)
            append!(pvds, callpvds)

            ce = CreateCallExpr(dne,callargs)

            if ce == C_NULL
                error("Failed to create CallExpr")
            end

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

            MarkDeclarationsReferencedInExpr(ce)
            ret = pcpp"llvm::Value"(ccall((:emitcallexpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),ce,rslot))

            if rett <: CppValue
                ret = C_NULL
            end
            #return createReturn(builder,f,argt,llvmrt,rt,ret,state)
        end
    end

    # Common return path for everything that's calling a normal function
    # (i.e. everything but constructors)
    createReturn(builder,f,argt,llvmargt,llvmrt,rett,rt,ret,state)
end

function createReturn(builder,f,argt,llvmargt,llvmrt,rett,rt,ret,state)

    jlrt = rett
    if ret == C_NULL
        jlrt = Void
        CreateRetVoid(builder)
    else
        #@show rett
        if rett == Void
            CreateRetVoid(builder)
        else
            if rett <: CppPtr || rett <: CppRef || rett <: CppEnum
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
    fname = string(expr.parameters[1])
    nnsbuilder = newNNSBuilder()
    d = lookup_ctx(fname; nnsbuilder=nnsbuilder)
    @assert d.ptr != C_NULL
    # If this is a typedef or something we'll try to get the primary one
    primary_decl = to_decl(primary_ctx(toctx(d)))
    if primary_decl != C_NULL
        d = primary_decl
    end

    expr = dre = CreateDeclRefExpr(d; islvalue=isaVarDecl(d), nnsbuilder=nnsbuilder)
    deleteNNSBuilder(nnsbuilder)


    if isaddrof
        expr = CreateAddrOfExpr(dre)
    end

    emitRefExpr(expr)
end

function cpp_ref(expr,prefix,isaddrof)
    @assert isa(expr, Symbol)
    fname = string(prefix, expr)
    x = :(CppExpr{$(quot(symbol(fname))),()}())
    ret = Expr(:call, :cxxref, isaddrof ? :(CppAddr($x)) : x)
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
function build_cpp_call(cexpr, this, prefix = "", isnew = false)
    if !isexpr(cexpr,:call)
        error("Expected a :call not $cexpr")
    end
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
                arguments[i] = :( CppDeref($(arg.args[2])) )
            end
        elseif isexpr(arg,:&)
            arguments[i] = :( CppAddr($(arg.args[1])) )
        end
    end

    # Add `this` as the first argument
    this !== nothing && unshift!(arguments, this)

    # The actual call to the staged function
    ret = Expr(:call, isnew ? :cxxnewcall : this === nothing ? :cppcall : :cppcall_member,
        :(CppExpr{$(quot(symbol(fname))),$(quot(targs))}()), arguments...)

    ret
end

function build_cpp_ref(member, this, isaddrof)
    @assert isa(member,Symbol)
    x = :(CppExpr{$(quot(symbol(member))),()}())
    ret = Expr(:call, :cxxmemref, isaddrof ? :(CppAddr($x)) : x, this)
end

function to_prefix(expr, isaddrof=false)
    if isa(expr,Symbol)
        return (string(expr), isaddrof)
    elseif isexpr(expr,:(::))
        prefix, isaddrof = to_prefix(expr.args[1],isaddrof)
        return (string(prefix,"::",to_prefix(expr.args[2],isaddrof)[1]), isaddrof)
    elseif isexpr(expr,:&)
        return to_prefix(expr.args[1],true)
    end
    error("Invalid NSS $expr")
end

function cpps_impl(expr,prefix="",isaddrof=false, isnew=false)
    # Expands a->b to
    # llvmcall((cpp_member,typeof(a),"b"))
    if isa(expr,Symbol)
        @assert !isnew
        return cpp_ref(expr,prefix,isaddrof)
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
            return build_cpp_call(b,a)
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
        prefix, isaddrof = to_prefix(expr.args[1])
        return cpps_impl(expr.args[2],string(prefix,"::"),isaddrof,isnew)
    elseif isexpr(expr,:&)
        return cpps_impl(expr.args[1],prefix,true,isnew)
    elseif isexpr(expr,:call)
        return build_cpp_call(expr,nothing,prefix,isnew)
    end
    error("Unrecognized CPP Expression ",expr," (",expr.head,")")
end

macro cxx(expr)
    cpps_impl(expr)
end

macro cxxnew(expr)
    cpps_impl(expr, "", false, true)
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

function process_cxx_string(str)
    # First we transform the source buffer by pulling out julia expressions
    # and replaceing them by expression like __julia::var1, which we can
    # later intercept in our external sema source
    # TODO: Consider if we need more advanced scope information in which
    # case we should probably switch to __julia_varN instead of putting
    # things in namespaces.
    pos = 1
    sourcebuf = IOBuffer()
    exprs = Any[]
    global varnum
    startvarnum = varnum
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
        write(sourcebuf,"__julia::var",string(varnum))
        varnum += 1
    end
    argsetup = Expr(:block)
    argcleanup = Expr(:block)
    for expr in exprs
        s = gensym()
        sv = gensym()
        push!(argsetup.args,:($s = $expr))
        push!(argsetup.args,:($sv = CreateVarDecl(ctx,$(string("var",startvarnum)),cpptype(typeof($s)))))
        push!(argsetup.args,:(AddDeclToDeclCtx(ctx,pcpp"clang::Decl"($(sv).ptr))))
        startvarnum += 1
        push!(argcleanup.args,:(SetDeclInitializer($sv,llvmconst($s))))
    end
    quote
        let
            jns = cglobal((:julia_namespace,libcxxffi),Ptr{Void})
            ns = createNamespace("julia")
            ctx = toctx(pcpp"clang::Decl"(ns.ptr))
            unsafe_store!(jns,ns.ptr)
            $argsetup
            cxxparse($(takebuf_string(sourcebuf)))
            unsafe_store!(jns,C_NULL)
            $argcleanup
        end
    end
end

macro cxx_str(str)
    process_cxx_string(str)
end

macro cxx_mstr(str)
    process_cxx_string(str)
end

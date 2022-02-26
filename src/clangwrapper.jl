# The julia-side interface to the clang wrappers defined in bootstrap.cpp
#
# Note that some of the functions declared in bootstrap.cpp are interfaced
# with elsewhere if more appropriate for a coherent organization. This file
# contains everything else that's just a thin wrapper of ccalls around the
# C++ routine

Base.convert(::Type{QualType},p::pcpp"clang::Type") = QualType(convert(Ptr{Cvoid},p))
cppconvert(T::QualType) = vcpp"clang::QualType"{sizeof(Ptr{Cvoid})}(tuple(reinterpret(UInt8, [T])...))

# Construct a QualType from a Type* pointer. This works, because the unused
# bits, when set to 0, indicate that none of the qualifier are set.
QualType(p::pcpp"clang::Type") = QualType(convert(Ptr{Cvoid},p))

# For convenience, we also have a QualType constructor that does nothing when
# passed a QualType.
QualType(x::QualType) = x

function extractTypePtr(T::QualType)
    @assert T.ptr != C_NULL
    pcpp"clang::Type"(
    ccall((:extractTypePtr,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),T))
end
function extractCVR(T::QualType)
    quals = ccall((:extractCVR,libcxxffi),Cuint,(Ptr{Cvoid},),T)
    ((quals&0x1)!=0,(quals&0x2)!=0,(quals&0x4)!=0)
end
function constQualified(T::QualType)
    QualType(UInt(T.ptr) | 0x1)
end

# Pass a qual type via the opaque pointer
cconvert(::Type{Ptr{Cvoid}},p::QualType) = p.ptr

# Bootstrap definitions
function pointerTo(C,t::QualType)
    QualType(ccall((:getPointerTo,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,t))
end
function referenceTo(C,t::QualType)
    QualType(ccall((:getReferenceTo,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,t))
end

function RValueRefernceTo(C,t::QualType)
    QualType(ccall((:getRvalueReferenceTo,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,t))
end


tovdecl(p::pcpp"clang::Decl") = pcpp"clang::ValueDecl"(ccall((:tovdecl,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),p))
tovdecl(p::pcpp"clang::ParmVarDecl") = pcpp"clang::ValueDecl"(convert(Ptr{Cvoid},p))
tovdecl(p::pcpp"clang::FunctionDecl") = pcpp"clang::ValueDecl"(convert(Ptr{Cvoid},p))

# For typetranslation.jl
BuildNNS(C,cxxscope,part) = ccall((:BuildNNS,libcxxffi),Bool,(Ref{ClangCompiler},Ptr{Cvoid},Ptr{UInt8}),C,cxxscope,part)

function _lookup_name(C,fname::AbstractString, ctx::pcpp"clang::DeclContext")
    @assert ctx != C_NULL
    #if !isDCComplete(ctx)
    #    dump(ctx)
    #    error("Tried to look up names in incomplete context")
    #end
    pcpp"clang::Decl"(
        ccall((:lookup_name,libcxxffi),Ptr{Cvoid},
            (Ref{ClangCompiler},Cstring,Ptr{Cvoid}),C,string(fname),ctx))
end
_lookup_name(C,fname::Symbol, ctx::pcpp"clang::DeclContext") = _lookup_name(C,string(fname),ctx)

translation_unit(C) = pcpp"clang::Decl"(ccall((:tu_decl,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},),C))

function CreateDeclRefExpr(C,p::pcpp"clang::ValueDecl"; islvalue=true, cxxscope=C_NULL)
    @assert p != C_NULL
    pcpp"clang::Expr"(ccall((:CreateDeclRefExpr,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid},Cint),C,p,cxxscope,islvalue))
end

function CreateDeclRefExpr(C, p; cxxscope=C_NULL, islvalue=true)
    @assert p != C_NULL
    vd = tovdecl(p)
    if vd == C_NULL
        dump(p)
        error("CreateDeclRefExpr called with something other than a ValueDecl")
    end
    CreateDeclRefExpr(C, vd;islvalue=islvalue,cxxscope=cxxscope)
end

function EmitDeclRef(C, DRE)
    pcpp"llvm::Value"(ccall((:EmitDeclRef, libcxxffi), Ptr{Cvoid},
        (Ref{ClangCompiler}, Ptr{Cvoid}), C, DRE))
end

cptrarr(a) = Ptr{Cvoid}[convert(Ptr{Cvoid}, x) for x in a]

function CreateParmVarDecl(C, p::QualType,name="dummy"; used = true)
    pcpp"clang::ParmVarDecl"(
        ccall((:CreateParmVarDecl,libcxxffi),Ptr{Cvoid},
            (Ref{ClangCompiler},Ptr{Cvoid},Ptr{UInt8},Cint),C,p,name,used))
end

function CreateVarDecl(C, DC::pcpp"clang::DeclContext",name,T::QualType)
    pcpp"clang::VarDecl"(ccall((:CreateVarDecl,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{UInt8},Ptr{Cvoid}),C,DC,name,T))
end

function CreateFunctionDecl(C,DC::pcpp"clang::DeclContext",name,T::QualType,isextern=true)
    pcpp"clang::FunctionDecl"(
        ccall((:CreateFunctionDecl,libcxxffi),Ptr{Cvoid},
            (Ref{ClangCompiler},Ptr{Cvoid},Ptr{UInt8},Ptr{Cvoid},Cint),C,DC,name,T,isextern))
end

function CreateTypeDefDecl(C,DC::pcpp"clang::DeclContext",name,T::QualType)
    pcpp"clang::TypeDefDecl"(
        ccall((:CreateTypeDefDecl,libcxxffi),Ptr{Cvoid},
            (Ref{ClangCompiler},Ptr{Cvoid},Ptr{UInt8},Ptr{Cvoid}),C,DC,name,T))
end

function BuildCallToMemberFunction(C, me::pcpp"clang::Expr", args::Vector{pcpp"clang::Expr"})
    ret = pcpp"clang::Expr"(ccall((:build_call_to_member,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Ptr{Cvoid}},Csize_t),
        C, me, cptrarr(args), length(args)))
    if ret == C_NULL
        error("Failed to call member")
    end
    ret
end

function BuildMemberReference(C, base, t, IsArrow, name)
    pcpp"clang::Expr"(ccall((:BuildMemberReference,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid},Cint,Ptr{UInt8}), C, base, t, IsArrow, name))
end

GetExprResultType(expr) = QualType(ccall((:DeduceReturnType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),expr))
GetFunctionReturnType(FD::pcpp"clang::FunctionDecl") = QualType(ccall((:GetFunctionReturnType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),FD))
function BuildDecltypeType(C,expr)
    QualType(ccall((:BuildDecltypeType,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,expr))
end

function CreateFunction(C,rt,argt)
    @ccall libcxxffi.CreateFunction(C::Ref{ClangCompiler}, rt::Ptr{Cvoid}, cptrarr(argt)::Ptr{Ptr{Cvoid}}, length(argt)::Csize_t)::LLVMValueRef
end

function ExtractValue(C,v::pcpp"llvm::Value",idx)
    pcpp"llvm::Value"(ccall((:create_extract_value,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Csize_t),C,v,idx))
end
InsertValue(builder, into::pcpp"llvm::Value", v::pcpp"llvm::Value", idx) =
    pcpp"llvm::Value"(ccall((:create_insert_value,libcxxffi),Ptr{Cvoid},
        (Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid},Csize_t),builder,into,v,idx))

function IntToPtr(builder, from::pcpp"llvm::Value", to::pcpp"llvm::Type")
    pcpp"llvm::Value"(ccall((:CreateIntToPtr,libcxxffi),Ptr{Cvoid},
        (Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}), builder, from, to))
end

function PtrToInt(builder, from::pcpp"llvm::Value", to::pcpp"llvm::Type")
    pcpp"llvm::Value"(ccall((:CreatePtrToInt,libcxxffi),Ptr{Cvoid},
        (Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}), builder, from, to))
end


getTemplateArgs(tmplt::pcpp"clang::ClassTemplateSpecializationDecl") =
    rcpp"clang::TemplateArgumentList"(ccall((:getTemplateArgs,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),tmplt))
getTemplateArgs(tmplt::pcpp"clang::TemplateSpecializationType") = tmplt

getTargsSize(targs::rcpp"clang::TemplateArgumentList") =
 ccall((:getTargsSize,libcxxffi),Csize_t,(Ptr{Cvoid},),targs)

getTargsSize(targs::pcpp"clang::TemplateSpecializationType") =
    ccall((:getTSTTargsSize,libcxxffi),Csize_t,(Ptr{Cvoid},),targs)

getNumParameters(targs::pcpp"clang::TemplateDecl") =
    ccall((:getTDNumParameters,libcxxffi),Csize_t,(Ptr{Cvoid},),targs)

getTargType(targ) = QualType(ccall((:getTargType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),targ))

getTargTypeAtIdx(targs::Union{rcpp"clang::TemplateArgumentList",
                              pcpp"clang::TemplateArgumentList"}, i) =
    QualType(ccall((:getTargTypeAtIdx,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Csize_t),targs,i))

getTargTypeAtIdx(targs::pcpp"clang::TemplateSpecializationType", i) =
    QualType(ccall((:getTSTTargTypeAtIdx,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Csize_t),targs,i))

getTargKindAtIdx(targs::pcpp"clang::TemplateSpecializationType", i) =
    ccall((:getTSTTargKindAtIdx,libcxxffi), Cint, (Ptr{Cvoid},Csize_t), targs, i)

getTargKindAtIdx(targs, i) =
    ccall((:getTargKindAtIdx,libcxxffi), Cint, (Ptr{Cvoid}, Csize_t), targs, i)

getTargKind(targ) =
    ccall((:getTargKind,libcxxffi),Cint,(Ptr{Cvoid},),targ)

getTargAsIntegralAtIdx(targs::rcpp"clang::TemplateArgumentList", i) =
    ccall((:getTargAsIntegralAtIdx,libcxxffi),Int64,(Ptr{Cvoid},Csize_t),targs,i)

getTargIntegralTypeAtIdx(targs, i) =
    QualType(ccall((:getTargIntegralTypeAtIdx,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Csize_t),targs,i))

getTargPackAtIdxSize(targs, i) =
    ccall((:getTargPackAtIdxSize, libcxxffi), Csize_t, (Ptr{Cvoid}, Csize_t), targs, i)

getTargPackAtIdxTargAtIdx(targs, i, j) =
    pcpp"clang::TemplateArgument"(ccall((:getTargPackAtIdxTargAtIdx, libcxxffi), Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t, Csize_t), targs, i, j))

getUndefValue(t::pcpp"llvm::Type") =
    pcpp"llvm::Value"(ccall((:getUndefValue,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),t))

getStructElementType(t::pcpp"llvm::Type",i) =
    pcpp"llvm::Type"(ccall((:getStructElementType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},UInt32),t,i))

CreateRet(builder,val::pcpp"llvm::Value") =
    pcpp"llvm::Value"(ccall((:CreateRet,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Ptr{Cvoid}),builder,val))

CreateRetVoid(builder) =
    pcpp"llvm::Value"(ccall((:CreateRetVoid,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),builder))

CreateBitCast(builder,val,ty) =
    pcpp"llvm::Value"(ccall((:CreateBitCast,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}),builder,val,ty))

CreateZext(builder,val,ty) =
    pcpp"llvm::Value"(ccall((:CreateZext,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}),builder,val,ty))

CreateTrunc(builder,val,ty) =
    pcpp"llvm::Value"(ccall((:CreateTrunc,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}),builder,val,ty))

CreatePointerFromObjref(C, builder, val) =
    pcpp"llvm::Value"(ccall((:CreatePointerFromObjref,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid}),C,builder,val))

getConstantIntToPtr(C::pcpp"llvm::Constant", ty) =
    pcpp"llvm::Constant"(ccall((:getConstantIntToPtr,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Ptr{Cvoid}),C,ty))

function BuildCXXTypeConstructExpr(C,t::QualType, exprs::Vector{pcpp"clang::Expr"})
    p = Ptr{Cvoid}[0]
    r = Bool(ccall((:typeconstruct,libcxxffi),Cint,
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Ptr{Cvoid}},Csize_t,Ptr{Ptr{Cvoid}}),
        C,t,cptrarr(exprs),length(exprs),p))
    r || error("Type construction failed")
    pcpp"clang::Expr"(p[1])
end

BuildCXXNewExpr(C, T::QualType,exprs::Vector{pcpp"clang::Expr"}) =
    pcpp"clang::Expr"(ccall((:BuildCXXNewExpr,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Ptr{Cvoid}},Csize_t),
        C,T,cptrarr(exprs),length(exprs)))

EmitCXXNewExpr(C,E::pcpp"clang::Expr") = pcpp"llvm::Value"(
    ccall((:EmitCXXNewExpr,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid},),C,E))
function EmitAnyExpr(C,E::pcpp"clang::Expr")
    pcpp"llvm::Value"(ccall((:EmitAnyExpr,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,E))
end

function EmitAnyExprToMem(C,expr,mem,isInit)
    ccall((:emitexprtomem,libcxxffi),Cvoid,
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid},Cint),C,expr,mem,isInit)
end

function EmitCallExpr(C,ce,rslot)
    pcpp"llvm::Value"(ccall((:emitcallexpr,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid}),C,ce,rslot))
end

function cxxsizeof(C,t::pcpp"clang::CXXRecordDecl")
    ccall((:cxxsizeof,libcxxffi),Csize_t,(Ref{ClangCompiler},Ptr{Cvoid}),C,t)
end
function cxxsizeof(C,t::QualType)
    ccall((:cxxsizeofType,libcxxffi),Csize_t,(Ref{ClangCompiler},Ptr{Cvoid}),C,t)
end

function createDerefExpr(C,e::pcpp"clang::Expr")
    pcpp"clang::Expr"(ccall((:createDerefExpr,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,e))
end

function CreateAddrOfExpr(C,e::pcpp"clang::Expr")
    pcpp"clang::Expr"(ccall((:createAddrOfExpr,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,e))
end

function MarkDeclarationsReferencedInExpr(C,e)
    ccall((:MarkDeclarationsReferencedInExpr,libcxxffi),Cvoid,(Ref{ClangCompiler},Ptr{Cvoid}),C,e)
end
getType(v::pcpp"llvm::Value") = pcpp"llvm::Type"(ccall((:getValueType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),v))

isPointerType(t::pcpp"llvm::Type") = ccall((:isLLVMPointerType,libcxxffi),Cint,(Ptr{Cvoid},),t) > 0

CreateConstGEP1_32(builder,x,idx) = pcpp"llvm::Value"(ccall((:CreateConstGEP1_32,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Ptr{Cvoid},UInt32),builder,x,idx))

function getPointerTo(t::pcpp"llvm::Type")
    pcpp"llvm::Type"(ccall((:getLLVMPointerTo,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),t))
end

CreateLoad(builder,val::pcpp"llvm::Value") = pcpp"llvm::Value"(ccall((:createLoad,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Ptr{Cvoid}),builder,val))

function BuildDeclarationNameExpr(C,name, ctx::pcpp"clang::DeclContext")
    pcpp"clang::Expr"(ccall((:BuildDeclarationNameExpr,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{UInt8},Ptr{Cvoid}),C,name,ctx))
end

getContext(decl::pcpp"clang::Decl") = pcpp"clang::DeclContext"(ccall((:getContext,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),decl))

getParentContext(DC::pcpp"clang::DeclContext") = pcpp"clang::DeclContext"(ccall((:getParentContext,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),DC))

declKind(DC::pcpp"clang::DeclContext") = ccall((:getDCDeclKind,libcxxffi),UInt64,(Ptr{Cvoid},),DC)

CreateCallExpr(C,Fn::pcpp"clang::Expr",args::Vector{pcpp"clang::Expr"}) = pcpp"clang::Expr"(
    ccall((:CreateCallExpr,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid},Ptr{Ptr{Cvoid}},Csize_t),
        C,Fn,cptrarr(args),length(args)))

function toLLVM(C,t::QualType)
    pcpp"llvm::Type"(ccall((:ConvertTypeForMem,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid}),C,t))
end

function newCXXScopeSpec(C)
    pcpp"clang::CXXScopeSpec"(ccall((:newCXXScopeSpec,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},),C))
end
deleteCXXScopeSpec(b::pcpp"clang::CXXScopeSpec") = ccall((:deleteCXXScopeSpec,libcxxffi),Cvoid,(Ptr{Cvoid},),b)

function AssociateValue(C,d::pcpp"clang::ParmVarDecl", ty::QualType, V::pcpp"llvm::Value")
    ccall((:AssociateValue,libcxxffi),Cvoid,(Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}),C,d,ty,V)
end

ExtendNNS(C,b::pcpp"clang::NestedNameSpecifierLocBuilder", ns::pcpp"clang::NamespaceDecl") =
    ccall((:ExtendNNS,libcxxffi),Cvoid,(Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid}),C,b,ns)

ExtendNNSType(C,b::pcpp"clang::NestedNameSpecifierLocBuilder", t::QualType) =
    ccall((:ExtendNNSType,libcxxffi),Cvoid,(Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid}),C,b,t)

ExtendNNSIdentifier(C,b::pcpp"clang::NestedNameSpecifierLocBuilder", name) =
    ccall((:ExtendNNSIdentifier,libcxxffi),Cvoid,(Ref{ClangCompiler},Ptr{Cvoid},Ptr{UInt8}),C,b,name)

function makeFunctionType(C,rt::QualType, args::Vector{QualType})
    QualType(ccall((:makeFunctionType,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Ptr{Cvoid}},Csize_t),
        C,rt,cptrarr(args),length(args)))
end

makeMemberFunctionType(C,FT::QualType, class::pcpp"clang::Type") =
    QualType(ccall((:makeMemberFunctionType, libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid}),C,FT,class))

getMemberPointerClass(mptr::pcpp"clang::Type") =
    pcpp"clang::Type"(ccall((:getMemberPointerClass, libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),mptr))

getMemberPointerPointee(mptr::pcpp"clang::Type") =
    QualType(ccall((:getMemberPointerPointee, libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),mptr))

getReturnType(ft::pcpp"clang::FunctionProtoType") =
    QualType(ccall((:getFPTReturnType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),ft))
getReturnType(FD::pcpp"clang::FunctionDecl") =
    QualType(ccall((:getFDReturnType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),FD))
getNumParams(ft::pcpp"clang::FunctionProtoType") =
    Int(ccall((:getFPTNumParams,libcxxffi),Csize_t,(Ptr{Cvoid},),ft))
getNumParams(FD::pcpp"clang::FunctionDecl") =
    Int(ccall((:getFDNumParams,libcxxffi),Csize_t,(Ptr{Cvoid},),FD))
getParam(ft::pcpp"clang::FunctionProtoType", idx) =
    QualType(ccall((:getFPTParam,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Csize_t),ft,idx))

getLLVMStructType(argts::Vector{pcpp"llvm::Type"}) =
    pcpp"llvm::Type"(ccall((:getLLVMStructType,libcxxffi), Ptr{Cvoid}, (Ptr{Ptr{Cvoid}},Csize_t), cptrarr(argts), length(argts)))

getConstantFloat(llvmt::pcpp"llvm::Type",x::Float64) = pcpp"llvm::Constant"(ccall((:getConstantFloat,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Float64),llvmt,x))
getConstantInt(llvmt::pcpp"llvm::Type",x::UInt64) = pcpp"llvm::Constant"(ccall((:getConstantInt,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},UInt64),llvmt,x))
getConstantStruct(llvmt::pcpp"llvm::Type",x::Vector{pcpp"llvm::Constant"}) = pcpp"llvm::Constant"(ccall((:getConstantStruct,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Ptr{Ptr{Cvoid}},Csize_t),llvmt,x,length(x)))

getDirectCallee(t::pcpp"clang::CallExpr") = pcpp"clang::FunctionDecl"(ccall((:getDirectCallee,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),t))
getCalleeReturnType(t::pcpp"clang::CallExpr") = QualType(ccall((:getCalleeReturnType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),t))

isIncompleteType(t::pcpp"clang::Type") = pcpp"clang::NamedDecl"(ccall((:isIncompleteType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),t))

function createNamespace(C,name::AbstractString)
    pcpp"clang::NamespaceDecl"(
        ccall((:createNamespace,libcxxffi),Ptr{Cvoid},
            (Ref{ClangCompiler},Ptr{UInt8}),C,string(name)))
end

function PerformMoveOrCopyInitialization(C,rt,expr)
    pcpp"clang::Expr"(ccall((:PerformMoveOrCopyInitialization,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid}),C,rt,expr))
end

AddDeclToDeclCtx(DC::pcpp"clang::DeclContext",D::pcpp"clang::Decl") =
    ccall((:AddDeclToDeclCtx,libcxxffi),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),DC,D)

function ReplaceFunctionForDecl(C,sv::pcpp"clang::FunctionDecl",f::pcpp"llvm::Function";
        DoInline = true, specsig = false, FirstIsEnv = false, NeedsBoxed = C_NULL,
        retty = Any, jts = C_NULL)
    @assert sv != C_NULL
    ccall((:ReplaceFunctionForDecl,libcxxffi),Cvoid,
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid},Bool,Bool,Bool,Ptr{Bool},Any,Ptr{Cvoid},Bool),
        C,sv,f,DoInline,specsig,FirstIsEnv,NeedsBoxed,retty,jts,VERSION >= v"0.7-")
end

function ReplaceFunctionForDecl(C,sv::pcpp"clang::CXXMethodDecl",f::pcpp"llvm::Function"; kwargs...)
    ReplaceFunctionForDecl(C,pcpp"clang::FunctionDecl"(convert(Ptr{Cvoid}, sv)),f; kwargs...)
end

isDeclInvalid(D::pcpp"clang::Decl") = Bool(ccall((:isDeclInvalid,libcxxffi),Cint,(Ptr{Cvoid},),D))

builtinKind(t::pcpp"clang::Type") = ccall((:builtinKind,libcxxffi),Cint,(Ptr{Cvoid},),t)

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
const CK_ToCvoid = 23
const CK_VectorSplat = 24
const CK_IntegralCast = 25

const BO_PtrMemD   =  0
const BO_PtrMemI   =  1
const BO_Mul       =  2
const BO_Div       =  3
const BO_Rem       =  4
const BO_Add       =  5
const BO_Sub       =  6
const BO_Shl       =  7
const BO_Shr       =  8
const BO_LT        =  9
const BO_GT        = 10
const BO_LE        = 11
const BO_GE        = 12
const BO_EQ        = 13
const BO_NE        = 14
const BO_And       = 15
const BO_Xor       = 16
const BO_Or        = 17
const BO_LAnd      = 18
const BO_LOr       = 19
const BO_Assign    = 20
const BO_MulAssign = 21
const BO_DivAssign = 22
const BO_RemAssign = 23
const BO_AddAssign = 24
const BO_SubAssign = 25
const BO_ShlAssign = 26
const BO_ShrAssign = 27
const BO_AndAssign = 28
const BO_XorAssign = 29
const BO_OrAssign  = 30
const BO_Comma     = 31

function createCast(C,arg,t,kind)
    pcpp"clang::Expr"(ccall((:createCast,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid},Cint),C,arg,t,kind))
end

function CreateBinOp(C,scope,opc,lhs,rhs)
    pcpp"clang::Expr"(ccall((:CreateBinOp,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Cint,Ptr{Cvoid},Ptr{Cvoid}),
        C,scope,opc,lhs,rhs))
end

# CXX Level Casting

for (rt,argt) in ((pcpp"clang::ClassTemplateSpecializationDecl",pcpp"clang::Decl"),
                  (pcpp"clang::CXXRecordDecl",pcpp"clang::Decl"),
                  (pcpp"clang::NamespaceDecl",pcpp"clang::Decl"),
                  (pcpp"clang::VarDecl",pcpp"clang::Decl"),
                  (pcpp"clang::ValueDecl",pcpp"clang::Decl"),
                  (pcpp"clang::FunctionDecl",pcpp"clang::Decl"),
                  (pcpp"clang::TypeDecl",pcpp"clang::Decl"),
                  (pcpp"clang::CXXMethodDecl",pcpp"clang::Decl"),
                  (pcpp"clang::CXXConstructorDecl",pcpp"clang::Decl"))
    s = split(string(rt.parameters[1].parameters[1].parameters[1]),"::")[end]
    isas = Symbol(string("isa",s))
    ds = Symbol(string("dcast",s))
    # @cxx llvm::isa{$rt}(t)
    @eval $(isas)(t::$(argt)) = ccall(($(quot(isas)),libcxxffi),Cint,(Ptr{Cvoid},),t) != 0
    @eval $(ds)(t::$(argt)) = ($rt)(ccall(($(quot(ds)),libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),t))
end

# Clang Type* Bootstrap

for s in (:isVoidType,:isBooleanType,:isPointerType,:isReferenceType,
    :isCharType, :isIntegerType, :isFunctionPointerType, :isMemberFunctionPointerType,
    :isFunctionType, :isFunctionProtoType, :isEnumeralType, :isFloatingType,
    :isElaboratedType, :isTemplateSpecializationType, :isDependentType,
    :isTemplateTypeParmType, :isArrayType)

    @eval ($s)(t::QualType) = ($s)(extractTypePtr(t))
    @eval ($s)(t::pcpp"clang::Type") = ccall(($(quot(s)),libcxxffi),Cint,(Ptr{Cvoid},),t) != 0
end

for (r,s) in ((pcpp"clang::CXXRecordDecl",:getPointeeCXXRecordDecl),
              (pcpp"clang::CXXRecordDecl",:getAsCXXRecordDecl))
                  @eval ($s)(t::pcpp"clang::Type") = ($(quot(r)))(ccall(($(quot(s)),libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),t))
end

getAsCXXRecordDecl(t::QualType) = getAsCXXRecordDecl(extractTypePtr(t))
getAsCXXRecordDecl(d::pcpp"clang::TemplateDecl") = getAsCXXRecordDecl(getTemplatedDecl(d))
getAsCXXRecordDecl(d::pcpp"clang::NamedDecl") = dcastCXXRecordDecl(pcpp"clang::Decl"(convert(Ptr{Cvoid},d)))

# Access to clang decls

primary_ctx(p::pcpp"clang::DeclContext") =
    pcpp"clang::DeclContext"(p == C_NULL ? C_NULL : ccall((:get_primary_dc,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),p))

toctx(p::pcpp"clang::Decl") =
    pcpp"clang::DeclContext"(p == C_NULL ? C_NULL : ccall((:decl_context,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),p))

toctx(p::pcpp"clang::FunctionDecl") = toctx(pcpp"clang::Decl"(convert(Ptr{Cvoid},p)))

toctx(p::pcpp"clang::CXXRecordDecl") = toctx(pcpp"clang::Decl"(convert(Ptr{Cvoid},p)))
toctx(p::pcpp"clang::ClassTemplateSpecializationDecl") = toctx(pcpp"clang::Decl"(convert(Ptr{Cvoid},p)))

isVoidTy(p::pcpp"llvm::Type") = ccall((:isVoidTy,libcxxffi),Cint,(Ptr{Cvoid},),p) != 0

to_decl(p::pcpp"clang::DeclContext") =
    pcpp"clang::Decl"(p == C_NULL ? C_NULL : ccall((:to_decl,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),p))

isaNamespaceDecl(d::pcpp"clang::CXXRecordDecl") = false

ActOnTypeParameter(C, Name, pos) =
    pcpp"clang::Decl"(ccall((:ActOnTypeParameter,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{UInt8},Cuint),C,Name,pos))

CreateTemplateParameterList(C, decls) =
    pcpp"clang::TemplateParameterList"(ccall((:CreateTemplateParameterList,libcxxffi),
        Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Ptr{Cvoid}},Csize_t),C,decls,length(decls)))

CreateFunctionTemplateDecl(C, DC::pcpp"clang::DeclContext", Params, FD) =
    pcpp"clang::FunctionTemplateDecl"(ccall((:CreateFunctionTemplateDecl,libcxxffi),
        Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}), C, DC, Params, FD))

function getSpecializations(FTD::pcpp"clang::FunctionTemplateDecl")
    v = ccall((:newFDVector,libcxxffi),Ptr{Cvoid},())
    ccall((:getSpecializations,libcxxffi),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),FTD,v)
    ret = Vector{pcpp"clang::FunctionDecl"}(undef, ccall((:getFDVectorSize,libcxxffi),Csize_t,(Ptr{Cvoid},),v))
    ccall((:copyFDVector,libcxxffi),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),ret,v);
    ccall((:deleteFDVector,libcxxffi),Cvoid,(Ptr{Cvoid},),v)
    ret
end

function getMangledFunctionName(C, FD)
    unsafe_string(ccall((:getMangledFunctionName,libcxxffi),Ptr{UInt8},(Ref{ClangCompiler},Ptr{Cvoid}),C,FD))
end

function templateParameters(FD)
    pcpp"clang::TemplateArgumentList"(ccall((:getTemplateSpecializationArgs,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),FD))
end

getTargsPointer(ctargs) = Ptr{vcpp"clang::TemplateArgument"}(ccall((:getTargsPointer,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),ctargs))
getTargsSize(ctargs) = ccall((:getTargsSize,libcxxffi),Csize_t,(Ptr{Cvoid},),ctargs)

function getLambdaCallOperator(R::pcpp"clang::CXXRecordDecl")
    pcpp"clang::CXXMethodDecl"(ccall((:getLambdaCallOperator,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),R))
end

function getCallOperator(C, R::pcpp"clang::CXXRecordDecl")
    pcpp"clang::CXXMethodDecl"(ccall((:getCallOperator,libcxxffi),
        Ptr{Cvoid}, (Ref{ClangCompiler}, Ptr{Cvoid}), C, R))
end

function isLambda(R::pcpp"clang::CXXRecordDecl")
    ccall((:isCxxDLambda,libcxxffi),Bool,(Ptr{Cvoid},),R)
end

function CreateCxxOperatorCallCall(C,meth,args)
    @assert meth != C_NULL
    pcpp"clang::CXXOperatorCall"(ccall((:CreateCxxOperatorCallCall,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid},Csize_t),C,meth,args,endof(args)))
end

function CreateCStyleCast(C,E,T)
    pcpp"clang::Expr"(ccall((:CreateCStyleCast,libcxxffi),Ptr{Cvoid},
        (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid}),C,E,T))
end

function CreateReturnStmt(C, E)
    pcpp"clang::Stmt"(ccall((:CreateReturnStmt,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,E))
end

function SetFDBody(FD,body)
    ccall((:SetFDBody,libcxxffi),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),FD,body)
end

SetFDParams(FD::pcpp"clang::FunctionDecl",params::Vector{pcpp"clang::ParmVarDecl"}) =
    ccall((:SetFDParams,libcxxffi),Cvoid,(Ptr{Cvoid},Ptr{Ptr{Cvoid}},Csize_t),
        FD,[convert(Ptr{Cvoid},p) for p in params],length(params))

SetFDParams(FD::pcpp"clang::CXXMethodDecl",params::Vector{pcpp"clang::ParmVarDecl"}) =
    SetFDParams(pcpp"clang::FunctionDecl"(convert(Ptr{Cvoid}, FD)), params)

function CreateFunctionRefExpr(C,FD::pcpp"clang::FunctionDecl")
    pcpp"clang::Expr"(ccall((:CreateFunctionRefExprFD,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,FD))
end

function CreateFunctionRefExpr(C,FD::pcpp"clang::FunctionTemplateDecl")
    pcpp"clang::Expr"(ccall((:CreateFunctionRefExprFDTemplate,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,FD))
end

LANG_C   = 0x2
LANG_CXX = 0x4

function CreateLinkageSpec(C,DC::pcpp"clang::DeclContext",kind)
    pcpp"clang::DeclContext"(ccall((:CreateLinkageSpec,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid},Cuint),C,DC,kind))
end

getName(x::pcpp"llvm::Function") = unsafe_string(ccall((:getLLVMValueName,libcxxffi),Ptr{UInt8},(Ptr{Cvoid},),x))
getName(ND::pcpp"clang::NamedDecl") = unsafe_string(ccall((:getNDName,libcxxffi),Ptr{UInt8},(Ptr{Cvoid},),ND))
getName(ND::pcpp"clang::ParmVarDecl") = getName(pcpp"clang::NamedDecl"(convert(Ptr{Cvoid}, ND)))

getParmVarDecl(x::pcpp"clang::FunctionDecl",i) = pcpp"clang::ParmVarDecl"(ccall((:getParmVarDecl,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},Cuint),x,i))

SetDeclUsed(C,FD) = ccall((:SetDeclUsed, libcxxffi),Cvoid,(Ref{ClangCompiler},Ptr{Cvoid}),C,FD)
IsDeclUsed(D) = ccall((:IsDeclUsed, libcxxffi), Cint, (Ptr{Cvoid},), D) != 0

emitDestroyCXXObject(C, x, T) = ccall((:emitDestroyCXXObject, libcxxffi), Cvoid, (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid}),C,x,T)

hasTrivialDestructor(C, D::pcpp"clang::CXXRecordDecl") =
  ccall((:hasTrivialDestructor, libcxxffi), Bool, (Ref{ClangCompiler}, Ptr{Cvoid},), C, D)

setPersonality(F, PersonalityF::pcpp"llvm::Function") = @ccall libcxxffi.setPersonality(F::LLVMValueRef, PersonalityF::Ptr{Cvoid})::Cvoid

getFunction(C, name) =
    pcpp"llvm::Function"(ccall((:getFunction, libcxxffi), Ptr{Cvoid}, (Ref{ClangCompiler}, Ptr{UInt8}, Csize_t), C, name, endof(name)))

getTypeName(C, T) = ccall((:getTypeName, libcxxffi), Any, (Ref{ClangCompiler}, Ptr{Cvoid}), C, T)

GetAddrOfFunction(C, FD) = pcpp"llvm::Constant"(ccall((:GetAddrOfFunction,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,FD))

getPointerElementType(T::pcpp"llvm::Type") = pcpp"llvm::Type"(ccall((:getPointerElementType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),T))

hasFDBody(FD::pcpp"clang::FunctionDecl") = ccall((:hasFDBody,libcxxffi),Cint,(Ptr{Cvoid},),FD) != 0

getOrCreateTemplateSpecialization(C,FTD,Ts::Vector{pcpp"clang::Type"}) =
    pcpp"clang::FunctionDecl"(ccall((:getOrCreateTemplateSpecialization,libcxxffi),Ptr{Cvoid},
      (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid},Csize_t),C,FTD,Ts,endof(Ts)))

CreateIntegerLiteral(C, val::UInt64, T) =
    pcpp"clang::IntegerLiteral"(ccall((:CreateIntegerLiteral, libcxxffi), Ptr{Cvoid}, (Ref{ClangCompiler}, UInt64, Ptr{Cvoid}), C, val, T))

ActOnFinishFunctionBody(C, FD, Stmt) =
    ccall((:ActOnFinishFunctionBody,libcxxffi),Cvoid,(Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid}),
        C, FD, Stmt)

EnterParserScope(C) = ccall((:EnterParserScope,libcxxffi),Cvoid,(Ref{ClangCompiler},),C)
ExitParserScope(C) = ccall((:ExitParserScope,libcxxffi),Cvoid,(Ref{ClangCompiler},),C)
ActOnTypeParameterParserScope(C, Name, pos) =
    pcpp"clang::Decl"(ccall((:ActOnTypeParameterParserScope,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{UInt8},Cint),C,Name,pos))

getUnderlyingTemplateDecl(TST) =
    pcpp"clang::TemplateDecl"(ccall((:getUnderlyingTemplateDecl,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),TST))

desugar(T::pcpp"clang::ElaboratedType") = QualType(ccall((:desugarElaboratedType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),T))
function desugar(T::QualType)
    T′ = extractTypePtr(T)
    @assert isElaboratedType(T′)
    QualType(ccall((:desugarElaboratedType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),T′))
end

getTTPTIndex(T::pcpp"clang::TemplateTypeParmType") = ccall((:getTTPTIndex, libcxxffi), Cuint, (Ptr{Cvoid},), T)

getTparam(T::pcpp"clang::TemplateDecl", i) = pcpp"clang::NamedDecl"(ccall((:getTDParamAtIdx, libcxxffi), Ptr{Cvoid}, (Ptr{Cvoid}, Cint), T, i))

getTemplatedDecl(T::pcpp"clang::TemplateDecl") = pcpp"clang::NamedDecl"(ccall((:getTemplatedDecl, libcxxffi), Ptr{Cvoid}, (Ptr{Cvoid},), T))

getArrayElementType(T::pcpp"clang::Type") = QualType(ccall((:getArrayElementType, libcxxffi), Ptr{Cvoid}, (Ptr{Cvoid},), T))

getIncompleteArrayType(C, T) = QualType(ccall((:getIncompleteArrayType,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,T))

getFunctionTypeReturnType(T::pcpp"clang::Type") = QualType(ccall((:getFunctionTypeReturnType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),T))

ParseDeclaration(C,scope=pcpp"clang::DeclContext"(C_NULL)) = pcpp"clang::NamedDecl"(ccall((:ParseDeclaration,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,scope))

getOriginalType(PVD::pcpp"clang::ParmVarDecl") = QualType(ccall((:getOriginalType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),PVD))

getParent(CxxMD::pcpp"clang::CXXMethodDecl") = pcpp"clang::CXXRecordDecl"(ccall((:getCxxMDParent,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),CxxMD))

function decouple_pch(C)
    size = ccall((:getPCHSize,libcxxffi),Csize_t,(Ref{ClangCompiler},),C)
    data = Array{UInt8}(undef, size)
    ccall((:decouple_pch,libcxxffi),Cvoid,(Ref{ClangCompiler},Ptr{UInt8}),C,data)
    data
end

function ParseParameterList(C,nparams)
    params = Array{Ptr{Cvoid}}(nparams)
    ccall((:ParseParameterList,libcxxffi),Cvoid,
        (Ref{ClangCompiler},Ptr{Cvoid},Csize_t),C,params,length(params))
    [pcpp"clang::ParmVarDecl"(p) for p in params]
end

isDCComplete(DC::pcpp"clang::DeclContext") = ccall((:isDCComplete,libcxxffi),Bool,(Ptr{Cvoid},),DC)

function CreateAnonymousClass(C, Scope::pcpp"clang::Decl")
    pcpp"clang::CXXRecordDecl"(ccall((:CreateAnonymousClass, libcxxffi), Ptr{Cvoid},
        (Ref{ClangCompiler}, Ptr{Cvoid}), C, Scope))
end

function AddCallOpToClass(Class::pcpp"clang::CXXRecordDecl", Method::pcpp"clang::CXXMethodDecl")
    pcpp"clang::CXXMethodDecl"(ccall((:AddCallOpToClass, libcxxffi), Ptr{Cvoid},
        (Ptr{Cvoid}, Ptr{Cvoid}), Class, Method))
end

function FinalizeAnonClass(C, Class::pcpp"clang::CXXRecordDecl")
    ccall((:FinalizeAnonClass, libcxxffi), Cvoid, (Ref{ClangCompiler}, Ptr{Cvoid}), C, Class)
end

getEmptyStructType() = pcpp"llvm::Type"(ccall((:getEmptyStructType, libcxxffi), Ptr{Cvoid}, ()))

function CreateCxxCallMethodDecl(C, Class::pcpp"clang::CXXRecordDecl", MethodType::QualType)
    pcpp"clang::CXXMethodDecl"(ccall((:CreateCxxCallMethodDecl, libcxxffi), Ptr{Cvoid},
        (Ref{ClangCompiler}, Ptr{Cvoid}, Ptr{Cvoid}), C, Class, MethodType))
end

function GetDescribedFunctionTemplate(FD)
    @assert FD != C_NULL
    pcpp"clang::FunctionTemplateDecl"(ccall((:GetDescribedFunctionTemplate, libcxxffi), Ptr{Cvoid},
        (Ptr{Cvoid},), FD))
end

function CreateThisExpr(C, QT::QualType)
    pcpp"clang::Expr"(ccall((:CreateThisExpr, libcxxffi), Ptr{Cvoid},
        (Ref{ClangCompiler}, Ptr{Cvoid}), C, QT))
end

function getUnderlyingTypeOfEnum(T::pcpp"clang::Type")
    QualType(ccall((:getUnderlyingTypeOfEnum, libcxxffi), Ptr{Cvoid},
        (Ptr{Cvoid},), T))
end

function InsertIntoShadowModule(C, llvmf::pcpp"llvm::Function")
    ccall((:InsertIntoShadowModule, libcxxffi), Cvoid, (Ref{ClangCompiler}, Ptr{Cvoid},), C, llvmf)
end

function SetVarDeclInit(D::pcpp"clang::VarDecl", init)
    ccall((:SetVarDeclInit, libcxxffi), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), D, init)
end

function SetConstexpr(VD::pcpp"clang::VarDecl")
    ccall((:SetConstexpr, libcxxffi), Cvoid, (Ptr{Cvoid},), VD)
end

function isCCompiler(C)
    ccall((:isCCompiler, libcxxffi), Cint, (Ref{ClangCompiler},), C) != 0
end

function AddTopLevelDecl(C, D)
    ccall((:AddTopLevelDecl, libcxxffi), Cvoid,
        (Ref{ClangCompiler}, Ptr{Cvoid}), C, D)
end

function DeleteUnusedArguments(F, todelete)
    pcpp"llvm::Function"(ccall((:DeleteUnusedArguments, libcxxffi), Ptr{Cvoid},
        (Ptr{Cvoid}, Ptr{UInt64}, Csize_t), F, todelete, length(todelete)))
end

function getTypeNameAsString(QT)
    ptr = ccall((:getTypeNameAsString, libcxxffi), Ptr{UInt8},
        (Ptr{Cvoid},), QT)
    str = unsafe_string(ptr)
    Libc.free(ptr)
    str
end

function set_access_control_enabled(C, enabled::Bool)
    ccall((:set_access_control_enabled, libcxxffi), Cint,
        (Ref{ClangCompiler}, Cint), C, enabled) != 0
end

function without_ac(f, C)
    old = set_access_control_enabled(C, false)
    ret = f()
    set_access_control_enabled(C, old)
    ret
end

getI8PtrTy() = pcpp"llvm::Type"(ccall((:getI8PtrTy,libcxxffi), Ptr{Cvoid}, ()))
getPRJLValueTy() = pcpp"llvm::Type"(ccall((:getPRJLValueTy,libcxxffi), Ptr{Cvoid}, ()))

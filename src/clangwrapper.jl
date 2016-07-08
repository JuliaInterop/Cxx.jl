# The julia-side interface to the clang wrappers defined in bootstrap.cpp
#
# Note that some of the functions declared in bootstrap.cpp are interfaced
# with elsewhere if more appropriate for a coherent organization. This file
# contains everything else that's just a thin wrapper of ccalls around the
# C++ routine

Base.convert(::Type{QualType},p::pcpp"clang::Type") = QualType(convert(Ptr{Void},p))
cppconvert(T::QualType) = vcpp"clang::QualType"{sizeof(Ptr{Void})}(tuple(reinterpret(UInt8, [T])...))

# Construct a QualType from a Type* pointer. This works, because the unused
# bits, when set to 0, indicate that none of the qualifier are set.
QualType(p::pcpp"clang::Type") = QualType(convert(Ptr{Void},p))

# For convenience, we also have a QualType constructor that does nothing when
# passed a QualType.
QualType(x::QualType) = x

function extractTypePtr(T::QualType)
    @assert T.ptr != C_NULL
    pcpp"clang::Type"(
    ccall((:extractTypePtr,libcxxffi),Ptr{Void},(Ptr{Void},),T))
end
function extractCVR(T::QualType)
    quals = ccall((:extractCVR,libcxxffi),Cuint,(Ptr{Void},),T)
    ((quals&0x1)!=0,(quals&0x2)!=0,(quals&0x4)!=0)
end
function constQualified(T::QualType)
    QualType(UInt(T.ptr) | 0x1)
end

# Pass a qual type via the opaque pointer
cconvert(::Type{Ptr{Void}},p::QualType) = p.ptr

# Bootstrap definitions
function pointerTo(C,t::QualType)
    QualType(ccall((:getPointerTo,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,t))
end
function referenceTo(C,t::QualType)
    QualType(ccall((:getReferenceTo,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,t))
end

function RValueRefernceTo(C,t::QualType)
    QualType(ccall((:getRvalueReferenceTo,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,t))
end


tovdecl(p::pcpp"clang::Decl") = pcpp"clang::ValueDecl"(ccall((:tovdecl,libcxxffi),Ptr{Void},(Ptr{Void},),p))
tovdecl(p::pcpp"clang::ParmVarDecl") = pcpp"clang::ValueDecl"(convert(Ptr{Void},p))
tovdecl(p::pcpp"clang::FunctionDecl") = pcpp"clang::ValueDecl"(convert(Ptr{Void},p))

# For typetranslation.jl
BuildNNS(C,cxxscope,part) = ccall((:BuildNNS,libcxxffi),Bool,(Ptr{ClangCompiler},Ptr{Void},Ptr{UInt8}),&C,cxxscope,part)

function _lookup_name(C,fname::AbstractString, ctx::pcpp"clang::DeclContext")
    @assert ctx != C_NULL
    #if !isDCComplete(ctx)
    #    dump(ctx)
    #    error("Tried to look up names in incomplete context")
    #end
    pcpp"clang::Decl"(
        ccall((:lookup_name,libcxxffi),Ptr{Void},
            (Ptr{ClangCompiler},Cstring,Ptr{Void}),&C,string(fname),ctx))
end
_lookup_name(C,fname::Symbol, ctx::pcpp"clang::DeclContext") = _lookup_name(C,string(fname),ctx)

translation_unit(C) = pcpp"clang::Decl"(ccall((:tu_decl,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},),&C))

function CreateDeclRefExpr(C,p::pcpp"clang::ValueDecl"; islvalue=true, cxxscope=C_NULL)
    @assert p != C_NULL
    pcpp"clang::Expr"(ccall((:CreateDeclRefExpr,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Void},Cint),&C,p,cxxscope,islvalue))
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
    pcpp"llvm::Value"(ccall((:EmitDeclRef, libcxxffi), Ptr{Void},
        (Ptr{ClangCompiler}, Ptr{Void}), &C, DRE))
end

cptrarr(a) = Ptr{Void}[convert(Ptr{Void}, x) for x in a]

function CreateParmVarDecl(C, p::QualType,name="dummy"; used = true)
    pcpp"clang::ParmVarDecl"(
        ccall((:CreateParmVarDecl,libcxxffi),Ptr{Void},
            (Ptr{ClangCompiler},Ptr{Void},Ptr{UInt8},Cint),&C,p,name,used))
end

function CreateVarDecl(C, DC::pcpp"clang::DeclContext",name,T::QualType)
    pcpp"clang::VarDecl"(ccall((:CreateVarDecl,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{UInt8},Ptr{Void}),&C,DC,name,T))
end

function CreateFunctionDecl(C,DC::pcpp"clang::DeclContext",name,T::QualType,isextern=true)
    pcpp"clang::FunctionDecl"(
        ccall((:CreateFunctionDecl,libcxxffi),Ptr{Void},
            (Ptr{ClangCompiler},Ptr{Void},Ptr{UInt8},Ptr{Void},Cint),&C,DC,name,T,isextern))
end

function CreateTypeDefDecl(C,DC::pcpp"clang::DeclContext",name,T::QualType)
    pcpp"clang::TypeDefDecl"(
        ccall((:CreateTypeDefDecl,libcxxffi),Ptr{Void},
            (Ptr{ClangCompiler},Ptr{Void},Ptr{UInt8},Ptr{Void}),&C,DC,name,T))
end

function BuildCallToMemberFunction(C, me::pcpp"clang::Expr", args::Vector{pcpp"clang::Expr"})
    ret = pcpp"clang::Expr"(ccall((:build_call_to_member,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        &C, me, cptrarr(args), length(args)))
    if ret == C_NULL
        error("Failed to call member")
    end
    ret
end

function BuildMemberReference(C, base, t, IsArrow, name)
    pcpp"clang::Expr"(ccall((:BuildMemberReference,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Void},Cint,Ptr{UInt8}), &C, base, t, IsArrow, name))
end

GetExprResultType(expr) = QualType(ccall((:DeduceReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),expr))
GetFunctionReturnType(FD::pcpp"clang::FunctionDecl") = QualType(ccall((:GetFunctionReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),FD))
function BuildDecltypeType(C,expr)
    QualType(ccall((:BuildDecltypeType,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,expr))
end

function CreateFunction(C,rt,argt)
    pcpp"llvm::Function"(ccall((:CreateFunction,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Ptr{Void}},Csize_t),&C,rt,cptrarr(argt),length(argt)))
end

function ExtractValue(C,v::pcpp"llvm::Value",idx)
    pcpp"llvm::Value"(ccall((:create_extract_value,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Csize_t),&C,v,idx))
end
InsertValue(builder, into::pcpp"llvm::Value", v::pcpp"llvm::Value", idx) =
    pcpp"llvm::Value"(ccall((:create_insert_value,libcxxffi),Ptr{Void},
        (Ptr{Void},Ptr{Void},Ptr{Void},Csize_t),builder,into,v,idx))

function IntToPtr(builder, from::pcpp"llvm::Value", to::pcpp"llvm::Type")
    pcpp"llvm::Value"(ccall((:CreateIntToPtr,libcxxffi),Ptr{Void},
        (Ptr{Void},Ptr{Void},Ptr{Void}), builder, from, to))
end

function PtrToInt(builder, from::pcpp"llvm::Value", to::pcpp"llvm::Type")
    pcpp"llvm::Value"(ccall((:CreatePtrToInt,libcxxffi),Ptr{Void},
        (Ptr{Void},Ptr{Void},Ptr{Void}), builder, from, to))
end


getTemplateArgs(tmplt::pcpp"clang::ClassTemplateSpecializationDecl") =
    rcpp"clang::TemplateArgumentList"(ccall((:getTemplateArgs,libcxxffi),Ptr{Void},(Ptr{Void},),tmplt))
getTemplateArgs(tmplt::pcpp"clang::TemplateSpecializationType") = tmplt

getTargsSize(targs::rcpp"clang::TemplateArgumentList") =
 ccall((:getTargsSize,libcxxffi),Csize_t,(Ptr{Void},),targs)

getTargsSize(targs::pcpp"clang::TemplateSpecializationType") =
    ccall((:getTSTTargsSize,libcxxffi),Csize_t,(Ptr{Void},),targs)

getNumParameters(targs::pcpp"clang::TemplateDecl") =
    ccall((:getTDNumParameters,libcxxffi),Csize_t,(Ptr{Void},),targs)

getTargType(targ) = QualType(ccall((:getTargType,libcxxffi),Ptr{Void},(Ptr{Void},),targ))

getTargTypeAtIdx(targs::Union{rcpp"clang::TemplateArgumentList",
                              pcpp"clang::TemplateArgumentList"}, i) =
    QualType(ccall((:getTargTypeAtIdx,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),targs,i))

getTargTypeAtIdx(targs::pcpp"clang::TemplateSpecializationType", i) =
    QualType(ccall((:getTSTTargTypeAtIdx,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),targs,i))

getTargKindAtIdx(targs::pcpp"clang::TemplateSpecializationType", i) =
    ccall((:getTSTTargKindAtIdx,libcxxffi), Cint, (Ptr{Void},Csize_t), targs, i)

getTargKindAtIdx(targs, i) =
    ccall((:getTargKindAtIdx,libcxxffi), Cint, (Ptr{Void}, Csize_t), targs, i)

getTargKind(targ) =
    ccall((:getTargKind,libcxxffi),Cint,(Ptr{Void},),targ)

getTargAsIntegralAtIdx(targs::rcpp"clang::TemplateArgumentList", i) =
    ccall((:getTargAsIntegralAtIdx,libcxxffi),Int64,(Ptr{Void},Csize_t),targs,i)

getTargIntegralTypeAtIdx(targs, i) =
    QualType(ccall((:getTargIntegralTypeAtIdx,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),targs,i))

getTargPackAtIdxSize(targs, i) =
    ccall((:getTargPackAtIdxSize, libcxxffi), Csize_t, (Ptr{Void}, Csize_t), targs, i)

getTargPackAtIdxTargAtIdx(targs, i, j) =
    pcpp"clang::TemplateArgument"(ccall((:getTargPackAtIdxTargAtIdx, libcxxffi), Ptr{Void}, (Ptr{Void}, Csize_t, Csize_t), targs, i, j))

getUndefValue(t::pcpp"llvm::Type") =
    pcpp"llvm::Value"(ccall((:getUndefValue,libcxxffi),Ptr{Void},(Ptr{Void},),t))

getStructElementType(t::pcpp"llvm::Type",i) =
    pcpp"llvm::Type"(ccall((:getStructElementType,libcxxffi),Ptr{Void},(Ptr{Void},UInt32),t,i))

CreateRet(builder,val::pcpp"llvm::Value") =
    pcpp"llvm::Value"(ccall((:CreateRet,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),builder,val))

CreateRetVoid(builder) =
    pcpp"llvm::Value"(ccall((:CreateRetVoid,libcxxffi),Ptr{Void},(Ptr{Void},),builder))

CreateBitCast(builder,val,ty) =
    pcpp"llvm::Value"(ccall((:CreateBitCast,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Ptr{Void}),builder,val,ty))

CreateZext(builder,val,ty) =
    pcpp"llvm::Value"(ccall((:CreateZext,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Ptr{Void}),builder,val,ty))

CreateTrunc(builder,val,ty) =
    pcpp"llvm::Value"(ccall((:CreateTrunc,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Ptr{Void}),builder,val,ty))

getConstantIntToPtr(C::pcpp"llvm::Constant", ty) =
    pcpp"llvm::Constant"(ccall((:getConstantIntToPtr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),C,ty))

function BuildCXXTypeConstructExpr(C,t::QualType, exprs::Vector{pcpp"clang::Expr"})
    p = Ptr{Void}[0]
    r = Bool(ccall((:typeconstruct,libcxxffi),Cint,
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Ptr{Void}},Csize_t,Ptr{Ptr{Void}}),
        &C,t,cptrarr(exprs),length(exprs),p))
    r || error("Type construction failed")
    pcpp"clang::Expr"(p[1])
end

BuildCXXNewExpr(C, T::QualType,exprs::Vector{pcpp"clang::Expr"}) =
    pcpp"clang::Expr"(ccall((:BuildCXXNewExpr,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        &C,T,cptrarr(exprs),length(exprs)))

EmitCXXNewExpr(C,E::pcpp"clang::Expr") = pcpp"llvm::Value"(
    ccall((:EmitCXXNewExpr,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void},),&C,E))
function EmitAnyExpr(C,E::pcpp"clang::Expr")
    pcpp"llvm::Value"(ccall((:EmitAnyExpr,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,E))
end

function EmitAnyExprToMem(C,expr,mem,isInit)
    ccall((:emitexprtomem,libcxxffi),Void,
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Void},Cint),&C,expr,mem,isInit)
end

function EmitCallExpr(C,ce,rslot)
    pcpp"llvm::Value"(ccall((:emitcallexpr,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Void}),&C,ce,rslot))
end

function cxxsizeof(C,t::pcpp"clang::CXXRecordDecl")
    ccall((:cxxsizeof,libcxxffi),Csize_t,(Ptr{ClangCompiler},Ptr{Void}),&C,t)
end
function cxxsizeof(C,t::QualType)
    ccall((:cxxsizeofType,libcxxffi),Csize_t,(Ptr{ClangCompiler},Ptr{Void}),&C,t)
end

function createDerefExpr(C,e::pcpp"clang::Expr")
    pcpp"clang::Expr"(ccall((:createDerefExpr,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,e))
end

function CreateAddrOfExpr(C,e::pcpp"clang::Expr")
    pcpp"clang::Expr"(ccall((:createAddrOfExpr,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,e))
end

function MarkDeclarationsReferencedInExpr(C,e)
    ccall((:MarkDeclarationsReferencedInExpr,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void}),&C,e)
end
getType(v::pcpp"llvm::Value") = pcpp"llvm::Type"(ccall((:getValueType,libcxxffi),Ptr{Void},(Ptr{Void},),v))

isPointerType(t::pcpp"llvm::Type") = ccall((:isLLVMPointerType,libcxxffi),Cint,(Ptr{Void},),t) > 0

CreateConstGEP1_32(builder,x,idx) = pcpp"llvm::Value"(ccall((:CreateConstGEP1_32,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},UInt32),builder,x,idx))

function getPointerTo(t::pcpp"llvm::Type")
    pcpp"llvm::Type"(ccall((:getLLVMPointerTo,libcxxffi),Ptr{Void},(Ptr{Void},),t))
end

CreateLoad(builder,val::pcpp"llvm::Value") = pcpp"llvm::Value"(ccall((:createLoad,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),builder,val))

function BuildDeclarationNameExpr(C,name, ctx::pcpp"clang::DeclContext")
    pcpp"clang::Expr"(ccall((:BuildDeclarationNameExpr,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{UInt8},Ptr{Void}),&C,name,ctx))
end

getContext(decl::pcpp"clang::Decl") = pcpp"clang::DeclContext"(ccall((:getContext,libcxxffi),Ptr{Void},(Ptr{Void},),decl))

getParentContext(DC::pcpp"clang::DeclContext") = pcpp"clang::DeclContext"(ccall((:getParentContext,libcxxffi),Ptr{Void},(Ptr{Void},),DC))

declKind(DC::pcpp"clang::DeclContext") = ccall((:getDCDeclKind,libcxxffi),UInt64,(Ptr{Void},),DC)

CreateCallExpr(C,Fn::pcpp"clang::Expr",args::Vector{pcpp"clang::Expr"}) = pcpp"clang::Expr"(
    ccall((:CreateCallExpr,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        &C,Fn,cptrarr(args),length(args)))

function toLLVM(C,t::QualType)
    pcpp"llvm::Type"(ccall((:ConvertTypeForMem,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void}),&C,t))
end

function newCXXScopeSpec(C)
    pcpp"clang::CXXScopeSpec"(ccall((:newCXXScopeSpec,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},),&C))
end
deleteCXXScopeSpec(b::pcpp"clang::CXXScopeSpec") = ccall((:deleteCXXScopeSpec,libcxxffi),Void,(Ptr{Void},),b)

function AssociateValue(C,d::pcpp"clang::ParmVarDecl", ty::QualType, V::pcpp"llvm::Value")
    ccall((:AssociateValue,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void},Ptr{Void},Ptr{Void}),&C,d,ty,V)
end

ExtendNNS(C,b::pcpp"clang::NestedNameSpecifierLocBuilder", ns::pcpp"clang::NamespaceDecl") =
    ccall((:ExtendNNS,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void},Ptr{Void}),&C,b,ns)

ExtendNNSType(C,b::pcpp"clang::NestedNameSpecifierLocBuilder", t::QualType) =
    ccall((:ExtendNNSType,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void},Ptr{Void}),&C,b,t)

ExtendNNSIdentifier(C,b::pcpp"clang::NestedNameSpecifierLocBuilder", name) =
    ccall((:ExtendNNSIdentifier,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void},Ptr{UInt8}),&C,b,name)

function makeFunctionType(C,rt::QualType, args::Vector{QualType})
    QualType(ccall((:makeFunctionType,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        &C,rt,cptrarr(args),length(args)))
end

makeMemberFunctionType(C,FT::QualType, class::pcpp"clang::Type") =
    QualType(ccall((:makeMemberFunctionType, libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void},Ptr{Void}),&C,FT,class))

getMemberPointerClass(mptr::pcpp"clang::Type") =
    pcpp"clang::Type"(ccall((:getMemberPointerClass, libcxxffi),Ptr{Void},(Ptr{Void},),mptr))

getMemberPointerPointee(mptr::pcpp"clang::Type") =
    QualType(ccall((:getMemberPointerPointee, libcxxffi),Ptr{Void},(Ptr{Void},),mptr))

getReturnType(ft::pcpp"clang::FunctionProtoType") =
    QualType(ccall((:getFPTReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),ft))
getReturnType(FD::pcpp"clang::FunctionDecl") =
    QualType(ccall((:getFDReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),FD))
getNumParams(ft::pcpp"clang::FunctionProtoType") =
    ccall((:getFPTNumParams,libcxxffi),Csize_t,(Ptr{Void},),ft)
getNumParams(FD::pcpp"clang::FunctionDecl") =
    ccall((:getFDNumParams,libcxxffi),Csize_t,(Ptr{Void},),FD)
getParam(ft::pcpp"clang::FunctionProtoType", idx) =
    QualType(ccall((:getFPTParam,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),ft,idx))

getLLVMStructType(argts::Vector{pcpp"llvm::Type"}) =
    pcpp"llvm::Type"(ccall((:getLLVMStructType,libcxxffi), Ptr{Void}, (Ptr{Ptr{Void}},Csize_t), cptrarr(argts), length(argts)))

getConstantFloat(llvmt::pcpp"llvm::Type",x::Float64) = pcpp"llvm::Constant"(ccall((:getConstantFloat,libcxxffi),Ptr{Void},(Ptr{Void},Float64),llvmt,x))
getConstantInt(llvmt::pcpp"llvm::Type",x::UInt64) = pcpp"llvm::Constant"(ccall((:getConstantInt,libcxxffi),Ptr{Void},(Ptr{Void},UInt64),llvmt,x))
getConstantStruct(llvmt::pcpp"llvm::Type",x::Vector{pcpp"llvm::Constant"}) = pcpp"llvm::Constant"(ccall((:getConstantStruct,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),llvmt,x,length(x)))

getDirectCallee(t::pcpp"clang::CallExpr") = pcpp"clang::FunctionDecl"(ccall((:getDirectCallee,libcxxffi),Ptr{Void},(Ptr{Void},),t))
getCalleeReturnType(t::pcpp"clang::CallExpr") = QualType(ccall((:getCalleeReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),t))

isIncompleteType(t::pcpp"clang::Type") = pcpp"clang::NamedDecl"(ccall((:isIncompleteType,libcxxffi),Ptr{Void},(Ptr{Void},),t))

function createNamespace(C,name::AbstractString)
    pcpp"clang::NamespaceDecl"(
        ccall((:createNamespace,libcxxffi),Ptr{Void},
            (Ptr{ClangCompiler},Ptr{UInt8}),&C,string(name)))
end

function PerformMoveOrCopyInitialization(C,rt,expr)
    pcpp"clang::Expr"(ccall((:PerformMoveOrCopyInitialization,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Void}),&C,rt,expr))
end

AddDeclToDeclCtx(DC::pcpp"clang::DeclContext",D::pcpp"clang::Decl") =
    ccall((:AddDeclToDeclCtx,libcxxffi),Void,(Ptr{Void},Ptr{Void}),DC,D)

function ReplaceFunctionForDecl(C,sv::pcpp"clang::FunctionDecl",f::pcpp"llvm::Function";
        DoInline = true, specsig = false, FirstIsEnv = false, NeedsBoxed = C_NULL, jts = C_NULL)
    @assert sv != C_NULL
    ccall((:ReplaceFunctionForDecl,libcxxffi),Void,
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Void},Bool,Bool,Bool,Ptr{Bool},Ptr{Void}),
        &C,sv,f,DoInline,specsig,FirstIsEnv,NeedsBoxed,jts)
end

function ReplaceFunctionForDecl(C,sv::pcpp"clang::CXXMethodDecl",f::pcpp"llvm::Function"; kwargs...)
    ReplaceFunctionForDecl(C,pcpp"clang::FunctionDecl"(convert(Ptr{Void}, sv)),f; kwargs...)
end

isDeclInvalid(D::pcpp"clang::Decl") = Bool(ccall((:isDeclInvalid,libcxxffi),Cint,(Ptr{Void},),D))

builtinKind(t::pcpp"clang::Type") = ccall((:builtinKind,libcxxffi),Cint,(Ptr{Void},),t)

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
    pcpp"clang::Expr"(ccall((:createCast,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Void},Cint),&C,arg,t,kind))
end

function CreateBinOp(C,scope,opc,lhs,rhs)
    pcpp"clang::Expr"(ccall((:CreateBinOp,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Cint,Ptr{Void},Ptr{Void}),
        &C,scope,opc,lhs,rhs))
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
    @eval $(isas)(t::$(argt)) = ccall(($(quot(isas)),libcxxffi),Cint,(Ptr{Void},),t) != 0
    @eval $(ds)(t::$(argt)) = ($rt)(ccall(($(quot(ds)),libcxxffi),Ptr{Void},(Ptr{Void},),t))
end

# Clang Type* Bootstrap

for s in (:isVoidType,:isBooleanType,:isPointerType,:isReferenceType,
    :isCharType, :isIntegerType, :isFunctionPointerType, :isMemberFunctionPointerType,
    :isFunctionType, :isFunctionProtoType, :isEnumeralType, :isFloatingType,
    :isElaboratedType, :isTemplateSpecializationType, :isDependentType,
    :isTemplateTypeParmType, :isArrayType)

    @eval ($s)(t::QualType) = ($s)(extractTypePtr(t))
    @eval ($s)(t::pcpp"clang::Type") = ccall(($(quot(s)),libcxxffi),Cint,(Ptr{Void},),t) != 0
end

for (r,s) in ((pcpp"clang::CXXRecordDecl",:getPointeeCXXRecordDecl),
              (pcpp"clang::CXXRecordDecl",:getAsCXXRecordDecl))
                  @eval ($s)(t::pcpp"clang::Type") = ($(quot(r)))(ccall(($(quot(s)),libcxxffi),Ptr{Void},(Ptr{Void},),t))
end

getAsCXXRecordDecl(t::QualType) = getAsCXXRecordDecl(extractTypePtr(t))
getAsCXXRecordDecl(d::pcpp"clang::TemplateDecl") = getAsCXXRecordDecl(getTemplatedDecl(d))
getAsCXXRecordDecl(d::pcpp"clang::NamedDecl") = dcastCXXRecordDecl(pcpp"clang::Decl"(convert(Ptr{Void},d)))

# Access to clang decls

primary_ctx(p::pcpp"clang::DeclContext") =
    pcpp"clang::DeclContext"(p == C_NULL ? C_NULL : ccall((:get_primary_dc,libcxxffi),Ptr{Void},(Ptr{Void},),p))

toctx(p::pcpp"clang::Decl") =
    pcpp"clang::DeclContext"(p == C_NULL ? C_NULL : ccall((:decl_context,libcxxffi),Ptr{Void},(Ptr{Void},),p))

toctx(p::pcpp"clang::FunctionDecl") = toctx(pcpp"clang::Decl"(convert(Ptr{Void},p)))

toctx(p::pcpp"clang::CXXRecordDecl") = toctx(pcpp"clang::Decl"(convert(Ptr{Void},p)))
toctx(p::pcpp"clang::ClassTemplateSpecializationDecl") = toctx(pcpp"clang::Decl"(convert(Ptr{Void},p)))

isVoidTy(p::pcpp"llvm::Type") = ccall((:isVoidTy,libcxxffi),Cint,(Ptr{Void},),p) != 0

to_decl(p::pcpp"clang::DeclContext") =
    pcpp"clang::Decl"(p == C_NULL ? C_NULL : ccall((:to_decl,libcxxffi),Ptr{Void},(Ptr{Void},),p))

isaNamespaceDecl(d::pcpp"clang::CXXRecordDecl") = false

ActOnTypeParameter(C, Name, pos) =
    pcpp"clang::Decl"(ccall((:ActOnTypeParameter,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{UInt8},Cuint),&C,Name,pos))

CreateTemplateParameterList(C, decls) =
    pcpp"clang::TemplateParameterList"(ccall((:CreateTemplateParameterList,libcxxffi),
        Ptr{Void},(Ptr{ClangCompiler},Ptr{Ptr{Void}},Csize_t),&C,decls,length(decls)))

CreateFunctionTemplateDecl(C, DC::pcpp"clang::DeclContext", Params, FD) =
    pcpp"clang::FunctionTemplateDecl"(ccall((:CreateFunctionTemplateDecl,libcxxffi),
        Ptr{Void},(Ptr{ClangCompiler},Ptr{Void},Ptr{Void},Ptr{Void}), &C, DC, Params, FD))

function getSpecializations(FTD::pcpp"clang::FunctionTemplateDecl")
    v = ccall((:newFDVector,libcxxffi),Ptr{Void},())
    ccall((:getSpecializations,libcxxffi),Void,(Ptr{Void},Ptr{Void}),FTD,v)
    ret = Array(pcpp"clang::FunctionDecl",ccall((:getFDVectorSize,libcxxffi),Csize_t,(Ptr{Void},),v))
    ccall((:copyFDVector,libcxxffi),Void,(Ptr{Void},Ptr{Void}),ret,v);
    ccall((:deleteFDVector,libcxxffi),Void,(Ptr{Void},),v)
    ret
end

function getMangledFunctionName(C, FD)
    bytestring(ccall((:getMangledFunctionName,libcxxffi),Ptr{UInt8},(Ptr{ClangCompiler},Ptr{Void}),&C,FD))
end

function templateParameters(FD)
    pcpp"clang::TemplateArgumentList"(ccall((:getTemplateSpecializationArgs,libcxxffi),Ptr{Void},(Ptr{Void},),FD))
end

getTargsPointer(ctargs) = Ptr{vcpp"clang::TemplateArgument"}(ccall((:getTargsPointer,libcxxffi),Ptr{Void},(Ptr{Void},),ctargs))
getTargsSize(ctargs) = ccall((:getTargsSize,libcxxffi),Csize_t,(Ptr{Void},),ctargs)

function getLambdaCallOperator(R::pcpp"clang::CXXRecordDecl")
    pcpp"clang::CXXMethodDecl"(ccall((:getLambdaCallOperator,libcxxffi),Ptr{Void},(Ptr{Void},),R))
end

function getCallOperator(C, R::pcpp"clang::CXXRecordDecl")
    pcpp"clang::CXXMethodDecl"(ccall((:getCallOperator,libcxxffi),
        Ptr{Void}, (Ptr{ClangCompiler}, Ptr{Void}), &C, R))
end

function isLambda(R::pcpp"clang::CXXRecordDecl")
    ccall((:isCxxDLambda,libcxxffi),Bool,(Ptr{Void},),R)
end

function CreateCxxOperatorCallCall(C,meth,args)
    @assert meth != C_NULL
    pcpp"clang::CXXOperatorCall"(ccall((:CreateCxxOperatorCallCall,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Void},Csize_t),&C,meth,args,endof(args)))
end

function CreateCStyleCast(C,E,T)
    pcpp"clang::Expr"(ccall((:CreateCStyleCast,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Void},Ptr{Void}),&C,E,T))
end

function CreateReturnStmt(C, E)
    pcpp"clang::Stmt"(ccall((:CreateReturnStmt,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,E))
end

function SetFDBody(FD,body)
    ccall((:SetFDBody,libcxxffi),Void,(Ptr{Void},Ptr{Void}),FD,body)
end

SetFDParams(FD::pcpp"clang::FunctionDecl",params::Vector{pcpp"clang::ParmVarDecl"}) =
    ccall((:SetFDParams,libcxxffi),Void,(Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        FD,[convert(Ptr{Void},p) for p in params],length(params))

SetFDParams(FD::pcpp"clang::CXXMethodDecl",params::Vector{pcpp"clang::ParmVarDecl"}) =
    SetFDParams(pcpp"clang::FunctionDecl"(convert(Ptr{Void}, FD)), params)

function CreateFunctionRefExpr(C,FD::pcpp"clang::FunctionDecl")
    pcpp"clang::Expr"(ccall((:CreateFunctionRefExprFD,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,FD))
end

function CreateFunctionRefExpr(C,FD::pcpp"clang::FunctionTemplateDecl")
    pcpp"clang::Expr"(ccall((:CreateFunctionRefExprFDTemplate,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,FD))
end

LANG_C   = 0x2
LANG_CXX = 0x4

function CreateLinkageSpec(C,DC::pcpp"clang::DeclContext",kind)
    pcpp"clang::DeclContext"(ccall((:CreateLinkageSpec,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void},Cuint),&C,DC,kind))
end

getName(x::pcpp"llvm::Function") = unsafe_string(ccall((:getLLVMValueName,libcxxffi),Ptr{UInt8},(Ptr{Void},),x))
getName(ND::pcpp"clang::NamedDecl") = unsafe_string(ccall((:getNDName,libcxxffi),Ptr{UInt8},(Ptr{Void},),ND))
getName(ND::pcpp"clang::ParmVarDecl") = getName(pcpp"clang::NamedDecl"(convert(Ptr{Void}, ND)))

getParmVarDecl(x::pcpp"clang::FunctionDecl",i) = pcpp"clang::ParmVarDecl"(ccall((:getParmVarDecl,libcxxffi),Ptr{Void},(Ptr{Void},Cuint),x,i))

SetDeclUsed(C,FD) = ccall((:SetDeclUsed, libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void}),&C,FD)
IsDeclUsed(D) = ccall((:IsDeclUsed, libcxxffi), Cint, (Ptr{Void},), D) != 0

emitDestroyCXXObject(C, x, T) = ccall((:emitDestroyCXXObject, libcxxffi), Void, (Ptr{ClangCompiler},Ptr{Void},Ptr{Void}),&C,x,T)

hasTrivialDestructor(C, D::pcpp"clang::CXXRecordDecl") =
  ccall((:hasTrivialDestructor, libcxxffi), Bool, (Ptr{ClangCompiler}, Ptr{Void},), &C, D)

setPersonality(F::pcpp"llvm::Function", PersonalityF::pcpp"llvm::Function") =
    ccall((:setPersonality, libcxxffi), Void, (Ptr{Void}, Ptr{Void}), F, PersonalityF)

getFunction(C, name) =
    pcpp"llvm::Function"(ccall((:getFunction, libcxxffi), Ptr{Void}, (Ptr{ClangCompiler}, Ptr{UInt8}, Csize_t), &C, name, endof(name)))

getTypeName(C, T) = ccall((:getTypeName, libcxxffi), Any, (Ptr{ClangCompiler}, Ptr{Void}), &C, T)

GetAddrOfFunction(C, FD) = pcpp"llvm::Constant"(ccall((:GetAddrOfFunction,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,FD))

RegisterType(C, RD, ST) = ccall((:RegisterType,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void},Ptr{Void}), &C, RD, ST)

getPointerElementType(T::pcpp"llvm::Type") = pcpp"llvm::Type"(ccall((:getPointerElementType,libcxxffi),Ptr{Void},(Ptr{Void},),T))

hasFDBody(FD::pcpp"clang::FunctionDecl") = ccall((:hasFDBody,libcxxffi),Cint,(Ptr{Void},),FD) != 0

getOrCreateTemplateSpecialization(C,FTD,Ts::Vector{pcpp"clang::Type"}) =
    pcpp"clang::FunctionDecl"(ccall((:getOrCreateTemplateSpecialization,libcxxffi),Ptr{Void},
      (Ptr{ClangCompiler},Ptr{Void},Ptr{Void},Csize_t),&C,FTD,Ts,endof(Ts)))

CreateIntegerLiteral(C, val::UInt64, T) =
    pcpp"clang::IntegerLiteral"(ccall((:CreateIntegerLiteral, libcxxffi), Ptr{Void}, (Ptr{ClangCompiler}, UInt64, Ptr{Void}), &C, val, T))

ActOnFinishFunctionBody(C, FD, Stmt) =
    ccall((:ActOnFinishFunctionBody,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void},Ptr{Void}),
        &C, FD, Stmt)

EnterParserScope(C) = ccall((:EnterParserScope,libcxxffi),Void,(Ptr{ClangCompiler},),&C)
ExitParserScope(C) = ccall((:ExitParserScope,libcxxffi),Void,(Ptr{ClangCompiler},),&C)
ActOnTypeParameterParserScope(C, Name, pos) =
    pcpp"clang::Decl"(ccall((:ActOnTypeParameterParserScope,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{UInt8},Cint),&C,Name,pos))

getUnderlyingTemplateDecl(TST) =
    pcpp"clang::TemplateDecl"(ccall((:getUnderlyingTemplateDecl,libcxxffi),Ptr{Void},(Ptr{Void},),TST))

desugar(T::pcpp"clang::ElaboratedType") = QualType(ccall((:desugarElaboratedType,libcxxffi),Ptr{Void},(Ptr{Void},),T))

getTTPTIndex(T::pcpp"clang::TemplateTypeParmType") = ccall((:getTTPTIndex, libcxxffi), Cuint, (Ptr{Void},), T)

getTparam(T::pcpp"clang::TemplateDecl", i) = pcpp"clang::NamedDecl"(ccall((:getTDParamAtIdx, libcxxffi), Ptr{Void}, (Ptr{Void}, Cint), T, i))

getTemplatedDecl(T::pcpp"clang::TemplateDecl") = pcpp"clang::NamedDecl"(ccall((:getTemplatedDecl, libcxxffi), Ptr{Void}, (Ptr{Void},), T))

getArrayElementType(T::pcpp"clang::Type") = QualType(ccall((:getArrayElementType, libcxxffi), Ptr{Void}, (Ptr{Void},), T))

getIncompleteArrayType(C, T) = QualType(ccall((:getIncompleteArrayType,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,T))

getFunctionTypeReturnType(T::pcpp"clang::Type") = QualType(ccall((:getFunctionTypeReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),T))

ParseDeclaration(C,scope=pcpp"clang::DeclContext"(C_NULL)) = pcpp"clang::NamedDecl"(ccall((:ParseDeclaration,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,scope))

getOriginalType(PVD::pcpp"clang::ParmVarDecl") = QualType(ccall((:getOriginalType,libcxxffi),Ptr{Void},(Ptr{Void},),PVD))

getParent(CxxMD::pcpp"clang::CXXMethodDecl") = pcpp"clang::CXXRecordDecl"(ccall((:getCxxMDParent,libcxxffi),Ptr{Void},(Ptr{Void},),CxxMD))

decouple_pch(C) = ccall((:decouple_pch,libcxxffi),Void,(Ptr{ClangCompiler},),&C)

function ParseParameterList(C,nparams)
    params = Array(Ptr{Void},nparams)
    ccall((:ParseParameterList,Cxx.libcxxffi),Void,
        (Ptr{Cxx.ClangCompiler},Ptr{Void},Csize_t),&C,params,length(params))
    [pcpp"clang::ParmVarDecl"(p) for p in params]
end

isDCComplete(DC::pcpp"clang::DeclContext") = ccall((:isDCComplete,libcxxffi),Bool,(Ptr{Void},),DC)

function CreateAnonymousClass(C, Scope::pcpp"clang::Decl")
    pcpp"clang::CXXRecordDecl"(ccall((:CreateAnonymousClass, libcxxffi), Ptr{Void},
        (Ptr{ClangCompiler}, Ptr{Void}), &C, Scope))
end

function AddCallOpToClass(Class::pcpp"clang::CXXRecordDecl", Method::pcpp"clang::CXXMethodDecl")
    pcpp"clang::CXXMethodDecl"(ccall((:AddCallOpToClass, libcxxffi), Ptr{Void},
        (Ptr{Void}, Ptr{Void}), Class, Method))
end

function FinalizeAnonClass(C, Class::pcpp"clang::CXXRecordDecl")
    ccall((:FinalizeAnonClass, libcxxffi), Void, (Ptr{ClangCompiler}, Ptr{Void}), &C, Class)
end

getEmptyStructType() = pcpp"llvm::Type"(ccall((:getEmptyStructType, libcxxffi), Ptr{Void}, ()))

function CreateCxxCallMethodDecl(C, Class::pcpp"clang::CXXRecordDecl", MethodType::QualType)
    pcpp"clang::CXXMethodDecl"(ccall((:CreateCxxCallMethodDecl, libcxxffi), Ptr{Void},
        (Ptr{ClangCompiler}, Ptr{Void}, Ptr{Void}), &C, Class, MethodType))
end

function GetDescribedFunctionTemplate(FD)
    @assert FD != C_NULL
    pcpp"clang::FunctionTemplateDecl"(ccall((:GetDescribedFunctionTemplate, libcxxffi), Ptr{Void},
        (Ptr{Void},), FD))
end

function CreateThisExpr(C, QT::QualType)
    pcpp"clang::Expr"(ccall((:CreateThisExpr, libcxxffi), Ptr{Void},
        (Ptr{ClangCompiler}, Ptr{Void}), &C, QT))
end

function getUnderlyingTypeOfEnum(T::pcpp"clang::Type")
    QualType(ccall((:getUnderlyingTypeOfEnum, libcxxffi), Ptr{Void},
        (Ptr{Void},), T))
end

function InsertIntoShadowModule(C, llvmf::pcpp"llvm::Function")
    ccall((:InsertIntoShadowModule, libcxxffi), Void, (Ptr{ClangCompiler}, Ptr{Void},), &C, llvmf)
end

function SetVarDeclInit(D::pcpp"clang::VarDecl", init)
    ccall((:SetVarDeclInit, libcxxffi), Void, (Ptr{Void}, Ptr{Void}), D, init)
end

function SetConstexpr(VD::pcpp"clang::VarDecl")
    ccall((:SetVarDeclInit, libcxxffi), Void, (Ptr{Void},), VD)
end

function isCCompiler(C)
    ccall((:isCCompiler, libcxxffi), Cint, (Ptr{ClangCompiler},), &C) != 0
end

function AddTopLevelDecl(C, D)
    ccall((:AddTopLevelDecl, libcxxffi), Void,
        (Ptr{ClangCompiler}, Ptr{Void}), &C, D)
end

function DeleteUnusedArguments(F, todelete)
    pcpp"llvm::Function"(ccall((:DeleteUnusedArguments, libcxxffi), Ptr{Void},
        (Ptr{Void}, Ptr{UInt64}, Csize_t), F, todelete, length(todelete)))
end

function getTypeNameAsString(QT)
    ptr = ccall((:getTypeNameAsString, libcxxffi), Ptr{UInt8},
        (Ptr{Void},), QT)
    str = unsafe_string(ptr)
    Libc.free(ptr)
    str
end

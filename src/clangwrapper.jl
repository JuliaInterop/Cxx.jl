# The julia-side interface to the clang wrappers defined in bootstrap.cpp
#
# Note thaat some of the functions declared in bootstrap.cpp are interfaced
# with elsewhere if more appropriate for a coherent organization. This file
# contains everything else that's just a thin wrapper of ccalls around the
# C++ routine


# Clang's QualType. A QualType is a pointer to a clang class object that
# contains the information about the actual type, as well as storing the CVR
# qualifiers in the unused bits of the pointer. Here we just treat QualType
# as an opaque struct with one pointer-sized member.
immutable QualType
    ptr::Ptr{Void}
end

# Construct a QualType from a Type* pointer. This works, because the unused
# bits, when set to 0, indicate that none of the qualifier are set.
QualType(p::pcpp"clang::Type") = QualType(p.ptr)

# For convenience, we also have a QualType constructor that does nothing when
# passed a QualType.
QualType(x::QualType) = x

extractTypePtr(T::QualType) = pcpp"clang::Type"(
    ccall((:extractTypePtr,libcxxffi),Ptr{Void},(Ptr{Void},),T))
function extractCVR(T::QualType)
    quals = ccall((:extractCVR,libcxxffi),Cuint,(Ptr{Void},),T)
    ((quals&0x1)!=0,(quals&0x2)!=0,(quals&0x4)!=0)
end

# Pass a qual type via the opaque pointer
cconvert(::Type{Ptr{Void}},p::QualType) = p.ptr

# Bootstrap definitions
pointerTo(t::QualType) = QualType(ccall((:getPointerTo,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))
referenceTo(t::QualType) = QualType(ccall((:getReferenceTo,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))

tovdecl(p::pcpp"clang::Decl") = pcpp"clang::ValueDecl"(ccall((:tovdecl,libcxxffi),Ptr{Void},(Ptr{Void},),p.ptr))
tovdecl(p::pcpp"clang::ParmVarDecl") = pcpp"clang::ValueDecl"(p.ptr)
tovdecl(p::pcpp"clang::FunctionDecl") = pcpp"clang::ValueDecl"(p.ptr)

function CreateDeclRefExpr(p::pcpp"clang::ValueDecl"; islvalue=true, cxxscope=C_NULL)
    @assert p != C_NULL
    pcpp"clang::Expr"(ccall((:CreateDeclRefExpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Cint),p.ptr,cxxscope,islvalue))
end

function CreateDeclRefExpr(p; cxxscope=C_NULL, islvalue=true)
    @assert p != C_NULL
    vd = tovdecl(p)
    if vd == C_NULL
        dump(p)
        error("CreateDeclRefExpr called with something other than a ValueDecl")
    end
    CreateDeclRefExpr(vd;islvalue=islvalue,cxxscope=cxxscope)
end

cptrarr(a) = [x.ptr for x in a]

CreateParmVarDecl(p::QualType,name="dummy") = pcpp"clang::ParmVarDecl"(ccall((:CreateParmVarDecl,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Uint8}),p.ptr,name))
CreateVarDecl(DC::pcpp"clang::DeclContext",name,T::QualType) = pcpp"clang::VarDecl"(ccall((:CreateVarDecl,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Uint8},Ptr{Void}),DC,name,T))
CreateFunctionDecl(DC::pcpp"clang::DeclContext",name,T::QualType,isextern=true) = pcpp"clang::FunctionDecl"(ccall((:CreateFunctionDecl,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Uint8},Ptr{Void},Cint),DC,name,T,isextern))

CreateTypeDefDecl(DC::pcpp"clang::DeclContext",name,T::QualType) = pcpp"clang::TypeDefDecl"(ccall((:CreateTypeDefDecl,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Uint8},Ptr{Void}),DC,name,T))

CreateMemberExpr(base::pcpp"clang::Expr",isarrow::Bool,member::pcpp"clang::ValueDecl") = pcpp"clang::Expr"(ccall((:CreateMemberExpr,libcxxffi),Ptr{Void},(Ptr{Void},Cint,Ptr{Void}),base.ptr,isarrow,member.ptr))
BuildCallToMemberFunction(me::pcpp"clang::Expr", args::Vector{pcpp"clang::Expr"}) = pcpp"clang::Expr"(ccall((:build_call_to_member,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        me.ptr,[arg.ptr for arg in args],length(args)))

BuildMemberReference(base, t, IsArrow, name) =
    pcpp"clang::Expr"(ccall((:BuildMemberReference,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Cint,Ptr{Uint8}),base, t, IsArrow, name))

GetExprResultType(expr) = QualType(ccall((:DeduceReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),expr))
GetFunctionReturnType(FD::pcpp"clang::FunctionDecl") = QualType(ccall((:GetFunctionReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),FD))
BuildDecltypeType(expr) = QualType(ccall((:BuildDecltypeType,libcxxffi),Ptr{Void},(Ptr{Void},),expr))

function CreateFunction(rt,argt)
    any(t->t == julia_to_llvm(Void),argt) && error("Test")
    pcpp"llvm::Function"(ccall((:CreateFunction,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),rt,cptrarr(argt),length(argt)))
end

ExtractValue(v::pcpp"llvm::Value",idx) = pcpp"llvm::Value"(ccall((:create_extract_value,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),v.ptr,idx))
InsertValue(builder, into::pcpp"llvm::Value", v::pcpp"llvm::Value", idx) =
    pcpp"llvm::Value"(ccall((:create_insert_value,libcxxffi),Ptr{Void},
        (Ptr{Void},Ptr{Void},Ptr{Void},Csize_t),builder,into,v,idx))

tollvmty(t::QualType) = pcpp"llvm::Type"(ccall((:tollvmty,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))

getTemplateArgs(tmplt::pcpp"clang::ClassTemplateSpecializationDecl") =
    rcpp"clang::TemplateArgumentList"(ccall((:getTemplateArgs,libcxxffi),Ptr{Void},(Ptr{Void},),tmplt))

getTargsSize(targs) =
 ccall((:getTargsSize,libcxxffi),Csize_t,(Ptr{Void},),targs)

getTargTypeAtIdx(targs, i) =
    QualType(ccall((:getTargTypeAtIdx,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),targs,i))

getTargKindAtIdx(targs, i) =
    ccall((:getTargKindAtIdx,libcxxffi),Cint,(Ptr{Void},Csize_t),targs,i)

getTargAsIntegralAtIdx(targs, i) =
    ccall((:getTargAsIntegralAtIdx,libcxxffi),Int64,(Ptr{Void},Csize_t),targs,i)

getTargIntegralTypeAtIdx(targs, i) =
    QualType(ccall((:getTargIntegralTypeAtIdx,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),targs,i))

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

function BuildCXXTypeConstructExpr(t::QualType, exprs::Vector{pcpp"clang::Expr"})
    p = Ptr{Void}[0]
    r = bool(ccall((:typeconstruct,libcxxffi),Cint,(Ptr{Void},Ptr{Ptr{Void}},Csize_t,Ptr{Ptr{Void}}),
        t,cptrarr(exprs),length(exprs),p))
    r || error("Type construction failed")
    pcpp"clang::Expr"(p[1])
end

#BuildCXXNewExpr(E::pcpp"clang::Expr") = pcpp"clang::Expr"(ccall((:BuildCXXNewExpr,libcxxffi),Ptr{Void},(Ptr{Void},),E))
BuildCXXNewExpr(T::QualType,exprs::Vector{pcpp"clang::Expr"}) =
    pcpp"clang::Expr"(ccall((:BuildCXXNewExpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        T,cptrarr(exprs),length(exprs)))

EmitCXXNewExpr(E::pcpp"clang::Expr") = pcpp"llvm::Value"(ccall((:EmitCXXNewExpr,libcxxffi),Ptr{Void},(Ptr{Void},),E))
EmitAnyExpr(E::pcpp"clang::Expr") = pcpp"llvm::Value"(ccall((:EmitAnyExpr,libcxxffi),Ptr{Void},(Ptr{Void},),E))

EmitAnyExprToMem(expr,mem,isInit) = ccall((:emitexprtomem,libcxxffi),Void,(Ptr{Void},Ptr{Void},Cint),expr,mem,isInit)

EmitCppMemberCallExpr(mce,rslot) = pcpp"llvm::Value"(ccall((:emitcppmembercallexpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),mce.ptr,rslot))

EmitCallExpr(ce,rslot) = pcpp"llvm::Value"(ccall((:emitcallexpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),ce.ptr,rslot))

cxxsizeof(t::pcpp"clang::CXXRecordDecl") = ccall((:cxxsizeof,libcxxffi),Csize_t,(Ptr{Void},),t)
cxxsizeof(t::QualType) = ccall((:cxxsizeofType,libcxxffi),Csize_t,(Ptr{Void},),t)

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

getParentContext(DC::pcpp"clang::DeclContext") = pcpp"clang::DeclContext"(ccall((:getParentContext,libcxxffi),Ptr{Void},(Ptr{Void},),DC))

declKind(DC::pcpp"clang::DeclContext") = ccall((:getDCDeclKind,libcxxffi),UInt64,(Ptr{Void},),DC)

CreateCallExpr(Fn::pcpp"clang::Expr",args::Vector{pcpp"clang::Expr"}) = pcpp"clang::Expr"(
    ccall((:CreateCallExpr,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        Fn,cptrarr(args),length(args)))

toLLVM(t::QualType) = pcpp"llvm::Type"(ccall((:ConvertTypeForMem,libcxxffi),Ptr{Void},(Ptr{Void},),t))

newNNSBuilder() = pcpp"clang::NestedNameSpecifierLocBuilder"(ccall((:newNNSBuilder,libcxxffi),Ptr{Void},()))
newCXXScopeSpec() = pcpp"clang::CXXScopeSpec"(ccall((:newCXXScopeSpec,libcxxffi),Ptr{Void},()))
deleteNNSBuilder(b::pcpp"clang::NestedNameSpecifierLocBuilder") = ccall((:deleteNNSBuilder,libcxxffi),Void,(Ptr{Void},),b)
deleteCXXScopeSpec(b::pcpp"clang::CXXScopeSpec") = ccall((:deleteCXXScopeSpec,libcxxffi),Void,(Ptr{Void},),b)

AssociateValue(d::pcpp"clang::ParmVarDecl", ty::QualType, V::pcpp"llvm::Value") = ccall((:AssociateValue,libcxxffi),Void,(Ptr{Void},Ptr{Void},Ptr{Void}),d,ty,V)

ExtendNNS(b::pcpp"clang::NestedNameSpecifierLocBuilder", ns::pcpp"clang::NamespaceDecl") =
    ccall((:ExtendNNS,libcxxffi),Void,(Ptr{Void},Ptr{Void}),b,ns)

ExtendNNSType(b::pcpp"clang::NestedNameSpecifierLocBuilder", t::QualType) =
    ccall((:ExtendNNSType,libcxxffi),Void,(Ptr{Void},Ptr{Void}),b,t)

ExtendNNSIdentifier(b::pcpp"clang::NestedNameSpecifierLocBuilder", name) =
    ccall((:ExtendNNSIdentifier,libcxxffi),Void,(Ptr{Void},Ptr{Uint8}),b,name)

makeFunctionType(rt::QualType, args::Vector{QualType}) =
    QualType(ccall((:makeFunctionType,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),rt,cptrarr(args),length(args)))

makeMemberFunctionType(FT::QualType, class::pcpp"clang::Type") =
    QualType(ccall((:makeMemberFunctionType, libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void}),FT,class))

getMemberPointerClass(mptr::pcpp"clang::Type") =
    pcpp"clang::Type"(ccall((:getMemberPointerClass, libcxxffi),Ptr{Void},(Ptr{Void},),mptr))

getMemberPointerPointee(mptr::pcpp"clang::Type") =
    QualType(ccall((:getMemberPointerPointee, libcxxffi),Ptr{Void},(Ptr{Void},),mptr))

getReturnType(ft::pcpp"clang::FunctionProtoType") =
    QualType(ccall((:getFPTReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),ft))
getNumParams(ft::pcpp"clang::FunctionProtoType") =
    ccall((:getFPTNumParams,libcxxffi),Csize_t,(Ptr{Void},),ft)
getParam(ft::pcpp"clang::FunctionProtoType", idx) =
    QualType(ccall((:getFPTParam,libcxxffi),Ptr{Void},(Ptr{Void},Csize_t),ft,idx))

getLLVMStructType(argts::Vector{pcpp"llvm::Type"}) =
    pcpp"llvm::Type"(ccall((:getLLVMStructType,libcxxffi), Ptr{Void}, (Ptr{Ptr{Void}},Csize_t), cptrarr(argts), length(argts)))

getConstantFloat(llvmt::pcpp"llvm::Type",x::Float64) = pcpp"llvm::Constant"(ccall((:getConstantFloat,libcxxffi),Ptr{Void},(Ptr{Void},Float64),llvmt,x))
getConstantInt(llvmt::pcpp"llvm::Type",x::Uint64) = pcpp"llvm::Constant"(ccall((:getConstantInt,libcxxffi),Ptr{Void},(Ptr{Void},Uint64),llvmt,x))
getConstantStruct(llvmt::pcpp"llvm::Type",x::Vector{pcpp"llvm::Constant"}) = pcpp"llvm::Constant"(ccall((:getConstantStruct,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),llvmt,x,length(x)))

getDirectCallee(t::pcpp"clang::CallExpr") = pcpp"clang::FunctionDecl"(ccall((:getDirectCallee,libcxxffi),Ptr{Void},(Ptr{Void},),t))
getCalleeReturnType(t::pcpp"clang::CallExpr") = QualType(ccall((:getCalleeReturnType,libcxxffi),Ptr{Void},(Ptr{Void},),t))

isIncompleteType(t::pcpp"clang::Type") = pcpp"clang::NamedDecl"(ccall((:isIncompleteType,libcxxffi),Ptr{Void},(Ptr{Void},),t))

createNamespace(name) = pcpp"clang::NamespaceDecl"(ccall((:createNamespace,libcxxffi),Ptr{Void},(Ptr{Uint8},),bytestring(name)))

AddDeclToDeclCtx(DC::pcpp"clang::DeclContext",D::pcpp"clang::Decl") =
    ccall((:AddDeclToDeclCtx,libcxxffi),Void,(Ptr{Void},Ptr{Void}),DC,D)

ReplaceFunctionForDecl(sv::pcpp"clang::FunctionDecl",f::pcpp"llvm::Function") =
    ccall((:ReplaceFunctionForDecl,libcxxffi),Void,(Ptr{Void},Ptr{Void}),sv,f)

isDeclInvalid(D::pcpp"clang::Decl") = bool(ccall((:isDeclInvalid,libcxxffi),Cint,(Ptr{Void},),D.ptr))

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

createCast(arg,t,kind) = pcpp"clang::Expr"(ccall((:createCast,libcxxffi),Ptr{Void},(Ptr{Void},Ptr{Void},Cint),arg,t,kind))

# CXX Level Casting

for (rt,argt) in ((pcpp"clang::ClassTemplateSpecializationDecl",pcpp"clang::Decl"),
                  (pcpp"clang::CXXRecordDecl",pcpp"clang::Decl"),
                  (pcpp"clang::NamespaceDecl",pcpp"clang::Decl"),
                  (pcpp"clang::VarDecl",pcpp"clang::Decl"),
                  (pcpp"clang::ValueDecl",pcpp"clang::Decl"),
                  (pcpp"clang::FunctionDecl",pcpp"clang::Decl"),
                  (pcpp"clang::TypeDecl",pcpp"clang::Decl"),
                  (pcpp"clang::CXXMethodDecl",pcpp"clang::Decl"))
    s = split(string(rt.parameters[1].parameters[1].parameters[1]),"::")[end]
    isas = symbol(string("isa",s))
    ds = symbol(string("dcast",s))
    # @cxx llvm::isa{$rt}(t)
    @eval $(isas)(t::$(argt)) = ccall(($(quot(isas)),libcxxffi),Int,(Ptr{Void},),t) != 0
    @eval $(ds)(t::$(argt)) = ($rt)(ccall(($(quot(ds)),libcxxffi),Ptr{Void},(Ptr{Void},),t))
end

# Clang Type* Bootstrap

for s in (:isVoidType,:isBooleanType,:isPointerType,:isReferenceType,
    :isCharType, :isIntegerType, :isFunctionPointerType, :isMemberFunctionPointerType,
    :isFunctionType, :isFunctionProtoType, :isEnumeralType, :isFloatingType)

    @eval ($s)(t::QualType) = ($s)(extractTypePtr(t))
    @eval ($s)(t::pcpp"clang::Type") = ccall(($(quot(s)),libcxxffi),Int,(Ptr{Void},),t) != 0
end

for (r,s) in ((pcpp"clang::CXXRecordDecl",:getPointeeCXXRecordDecl),
              (pcpp"clang::CXXRecordDecl",:getAsCXXRecordDecl))
                  @eval ($s)(t::pcpp"clang::Type") = ($(quot(r)))(ccall(($(quot(s)),libcxxffi),Ptr{Void},(Ptr{Void},),t))
end

# Access to clang decls

translation_unit() = pcpp"clang::Decl"(ccall((:tu_decl,libcxxffi),Ptr{Void},()))

primary_ctx(p::pcpp"clang::DeclContext") =
    pcpp"clang::DeclContext"(p == C_NULL ? C_NULL : ccall((:get_primary_dc,libcxxffi),Ptr{Void},(Ptr{Void},),p))

toctx(p::pcpp"clang::Decl") =
    pcpp"clang::DeclContext"(p == C_NULL ? C_NULL : ccall((:decl_context,libcxxffi),Ptr{Void},(Ptr{Void},),p))

toctx(p::pcpp"clang::CXXRecordDecl") = toctx(pcpp"clang::Decl"(p.ptr))
toctx(p::pcpp"clang::ClassTemplateSpecializationDecl") = toctx(pcpp"clang::Decl"(p.ptr))

function _lookup_name(fname, ctx::pcpp"clang::DeclContext")
    @assert ctx != C_NULL
    pcpp"clang::Decl"(
        ccall((:lookup_name,libcxxffi),Ptr{Void},(Ptr{Uint8},Ptr{Void}),bytestring(fname),ctx))
end
_lookup_name(fname::Symbol, ctx::pcpp"clang::DeclContext") = _lookup_name(string(fname),ctx)

to_decl(p::pcpp"clang::DeclContext") =
    pcpp"clang::Decl"(p == C_NULL ? C_NULL : ccall((:to_decl,libcxxffi),Ptr{Void},(Ptr{Void},),p))

isaNamespaceDecl(d::pcpp"clang::CXXRecordDecl") = false

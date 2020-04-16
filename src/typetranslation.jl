# Translating between clang and julia types

import Base: unsafe_string

# # # # Section 1: Mapping Julia types to clang types
#
# The main function defined by this section is cpptype(T), which for a given
# julia type `T` will return a QualType, representing clang's interpretation
# of this type

# # # Built-in clang types
chartype(C) = QualType(pcpp"clang::Type"(ccall((:cT_cchar,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},),C)))
winttype(C) = QualType(pcpp"clang::Type"(ccall((:cT_wint,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},),C)))
cpptype(C,::Type{UInt8}) = chartype(C)

# Mapping some basic julia bitstypes to C's intrinsic types
# We could use Cint, etc. here, but we actually already do that
# in the C++ side, which makes this easy:
for (jlt, sym) in
    ((Cvoid, :cT_void),
     (Int8, :cT_int8),
     (Int16, :cT_int16),
     (UInt16, :cT_uint16),
     (UInt32, :cT_uint32),
     (Int32, :cT_int32),
     (UInt64, :cT_uint64),
     (Int64, :cT_int64),
     (Bool, :cT_int1),
     (Float32, :cT_float32),
     (Float64, :cT_float64))

    # For each type, do the mapping by loading the appropriate global
    @eval cpptype(C::ClangCompiler,::Type{$jlt}) = QualType(pcpp"clang::Type"(
        ccall(($(quot(sym)), libcxxffi),
            Ptr{Cvoid},(Ref{ClangCompiler},),C )))

end

# Intended for end users to extend if they wrap a C++ type in a julia type, but
# want to have it automatically converted to a C++ compatible type
cppconvert(x) = x

# # # Mapping the C++ object hierarchy types back to clang types
#
# This is more complicated than simply mapping builtin types and proceeds in
# stages.
#
# 1. Perform the name lookup of the inner most declaration (cppdecl)
#   - While doing this we also need to perform template instantiation
# 2. Resolve pointer/reference types in clang/land
# 3. Add CVR qualifiers
#
# Steps 2/3 are performed in the actual definition of cpptype at the end of
# this subsection. But first, we need utilities for name lookup, templates, etc.
#

# # Name Lookup

#
# Name lookup was rather frustrating to figure out and I'm sure this is still
# not the ideal way to do this. The main entry points to this section are
# lookup_name and lookup_ctx.
#
# lookup_name takes a list of parts, where each part is the name of the next
# Decl to lookup, e.g. foo::bar would be looked up as ("foo","bar").
# However, this isn't necessarily enough as some other parts of the clang API
# require not only the looked up type, but also how it was qualified, e.g.
# to differentiate
#
# ```
#   using namespace foo;
#   bar
# ```
#
# from `foo::bar`
#
# This is achieved using the CxxScopeSpec type. Where required, a CxxScopeSpec
# can be allocated using newCXXScopeSpec (and deleted using deleteCXXScopeSpec)
# and passed in as the `cxxscope` argument to lookup_name, which will be
# automatically built up as expressions are looked up.
#
# Note however, that e.g. in `foo::bar::baz`, the CxxScopeSpec only covers
# `foo::bar`, but not the actual decl `baz`. To this end, lookup_name does
# not add the last part to the CxxScopeSpec by default. This behavior can be
# overriden using the `addlast` parameter, which is useful when looking up a
# prefix to a decl context, rather than a Decl itself.
#
# TODO: Figure out what we need to do if there's a template in the NNS.
# Originally there was code to handle this, but it was incorrect and apparently
# never triggered in my original tests. Better to address that point when
# we have a failing test case to verify we did it correctly.
#

#
# Extend the CxxScopeSpec * by the type or namespace with the name of `part`.
# E.g. if the CxxScopeSpec already contains ::foo, it could be extended to
# ::foo::bar by calling nnsexpend(S,"bar")
#
function nnsextend(C,cxxscope,part)
    if cxxscope != C_NULL
        errorOccured = BuildNNS(C,cxxscope,part)
        if errorOccured
            error("Failed to extend NNS with part $part")
        end
    end
end

function lookup_name(C::ClangCompiler,parts, cxxscope = C_NULL, start=translation_unit(C), addlast=false)
    cur = start
    for (i,fpart) in enumerate(parts)
        lastcur = cur
        (addlast || (i != length(parts))) && nnsextend(C,cxxscope,fpart)
        cur = _lookup_name(C,fpart,primary_ctx(toctx(cur)))
        if cur == C_NULL
            if lastcur == translation_unit(C)
                error("Could not find `$fpart` in translation unit")
            else
                error("Could not find `$fpart` in context $(_decl_name(lastcur))")
            end
        end
    end
    cur
end

# Convenience method for splitting a qualified name into actual parts
function lookup_ctx(C, fname::AbstractString;
    cxxscope=C_NULL, cur=translation_unit(C), addlast = false)
    lookup_name(C, split(fname,"::"),cxxscope,cur, addlast)
end
lookup_ctx(C, fname::Symbol; kwargs...) = lookup_ctx(C, string(fname); kwargs...)

# # Template instantiations for decl lookups

# Specialize a ClassTemplateDecl cxxt with a list of template arguments given
# by `targs`
function specialize_template(C,cxxt::pcpp"clang::ClassTemplateDecl",targs)
    @assert cxxt != C_NULL
    nparams = length(targs.parameters)
    integralValues = zeros(UInt64,nparams)
    integralValuesPresent = zeros(UInt8,nparams)
    bitwidths = zeros(UInt32,nparams)
    ts = Vector{QualType}(undef, nparams)
    for (i,t) in enumerate(targs.parameters)
        (t <: Val) && (t = t.parameters[1])
        if isa(t,Type)
            ts[i] = cpptype(C,t)
        elseif isa(t,Integer) || isa(t,CppEnum)
            ts[i] = cpptype(C,typeof(t))
            integralValues[i] = unsigned(isa(t,CppEnum) ? t.val : t)
            integralValuesPresent[i] = 1
            bitwidths[i] = isa(t,Bool) ? 8 : sizeof(typeof(t))
        else
            error("Unhandled template parameter type ($t)")
        end
    end
    d = pcpp"clang::ClassTemplateSpecializationDecl"(ccall((:SpecializeClass,libcxxffi),Ptr{Cvoid},
            (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Ptr{Cvoid}},Ptr{UInt64},Ptr{Int8},Csize_t),
            C,convert(Ptr{Cvoid},cxxt),[convert(Ptr{Cvoid},p) for p in ts],
            integralValues,integralValuesPresent,length(ts)))
    d
end

function specialize_template_clang(C,cxxt::pcpp"clang::ClassTemplateDecl",targs)
    @assert cxxt != C_NULL
    integralValues = zeros(UInt64,length(targs))
    integralValuesPresent = zeros(UInt8,length(targs))
    bitwidths = zeros(UInt32,length(targs))
    ts = Vector{QualType}(undef, length(targs))
    for (i,t) in enumerate(targs)
        if isa(t,pcpp"clang::Type") || isa(t,QualType)
            ts[i] = QualType(t)
        elseif isa(t,Integer) || isa(t,CppEnum)
            ts[i] = cpptype(C, typeof(t))
            integralValues[i] = unsigned(isa(t,CppEnum) ? t.val : t)
            integralValuesPresent[i] = 1
            bitwidths[i] = isa(t,Bool) ? 8 : sizeof(typeof(t))
        else
            error("Unhandled template parameter type ($t)")
        end
    end
    d = pcpp"clang::ClassTemplateSpecializationDecl"(ccall((:SpecializeClass,libcxxffi),Ptr{Cvoid},
            (Ref{ClangCompiler},Ptr{Cvoid},Ptr{Cvoid},Ptr{UInt64},Ptr{Int8},Csize_t),C,
            convert(Ptr{Cvoid},cxxt),[convert(Ptr{Cvoid},p) for p in ts],
            integralValues,integralValuesPresent,length(ts)))
    d
end

# # The actual decl lookup
# since we split out all the actual meat above, this is now simple

function cppdecl(C,T::Type{CppBaseType{fname}}) where fname
    # Let's get a clang level representation of this type
    lookup_ctx(C,fname)
end
cppdecl(C,p::Type{T}) where {T<:CppEnum} = lookup_ctx(C,p.parameters[1])

function cppdecl(C,TT::Type{CppTemplate{T,targs}}) where {T,targs}
    ctx = cppdecl(C,T)

    # Do the acutal template resolution
    cxxt = cxxtmplt(ctx)
    @assert cxxt != C_NULL
    deduced_class = specialize_template(C,cxxt,targs)
    ctx = deduced_class

    ctx
end

# For getting the decl ignore the CVR qualifiers, pointer qualification, etc.
# and just do the lookup on the base decl
function cppdecl(C,::Union{
    Type{CppPtr{T,CVR}}, Type{CxxQualType{T,CVR}}, Type{CppRef{T,CVR}}}) where {T,CVR}
    cppdecl(C,T)
end

# Get a clang Type * for the decl we have looked up.
# @cxx (@cxx dyn_cast{vcpp"clang::TypeDecl"}(d))->getTypeForDecl()
function typeForDecl(d::Union{
        # Luckily Decl is the first base for these, so we can get away
        # with only one function on the C++ side that takes a Decl*
        pcpp"clang::Decl",pcpp"clang::CXXRecordDecl",
        pcpp"clang::ClassTemplateSpecializationDecl"})
    @assert d != C_NULL
    pcpp"clang::Type"(ccall((:typeForDecl,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),d))
end

for sym in (:withConst, :withVolatile, :withRestrict)
    @eval ($sym)(T::QualType) =
        QualType(ccall(($(quot(sym)),libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),T))
end

function addQualifiers(clangT::QualType,CVR)
    C,V,R = CVR
    if C
        clangT = withConst(clangT)
    end
    if V
        clangT = withVolatile(clangT)
    end
    if R
        clangT = withRestrict(clangT)
    end
    clangT
end
addQualifiers(clangT::pcpp"clang::Type",CVR) = addQualifiers(QualType(clangT),CVR)

# And finally the actual definition of cpptype

cpptype(C,::Type{T}) where {T<:CppTemplate} = QualType(typeForDecl(cppdecl(C,T)))
cpptype(C,p::Type{T}) where {T<:CppEnum} = QualType(typeForDecl(cppdecl(C,p)))
cpptype(C,p::Type{CxxArrayType{T}}) where {T} = getIncompleteArrayType(C,cpptype(C,T))
function cpptype(C,p::Type{CppPtr{T,CVR}}) where {T,CVR}
    addQualifiers(pointerTo(C,cpptype(C,T)),CVR)
end
function cpptype(C,p::Type{CxxQualType{T,CVR}}) where {T,CVR}
    addQualifiers(typeForDecl(cppdecl(C,T)),CVR)
end
# This is a hack, we should find a better way to do this
function cpptype(C,p::Type{CxxQualType{T,CVR}}) where {T<:CppLambda,CVR}
    addQualifiers(typeForLambda(T),CVR)
end
cpptype(C,p::Type{CppValue{T,N}}) where {T,N} = cpptype(C,T)
cpptype(C,p::Type{CppValue{T}}) where {T} = cpptype(C,T)
cpptype(C,p::Type{CppBaseType{s}}) where {s} = QualType(typeForDecl(cppdecl(C,p)))
function cpptype(C,p::Type{CppRef{T,CVR}}) where {T,CVR}
    referenceTo(C,addQualifiers(cpptype(C,T),CVR))
end

cpptype(C,::Type{T}) where {T<:Ref} = referenceTo(C,cpptype(C,eltype(T)))
cpptype(C,p::Type{Ptr{T}}) where {T} = pointerTo(C,cpptype(C,T))

function cpptype(C,p::Type{CppMFptr{base,fptr}}) where {base,fptr}
    makeMemberFunctionType(C, cpptype(C,base), cpptype(C,fptr))
end
function cpptype(C,p::Type{CppFunc{rt,args}}) where {rt, args}
    makeFunctionType(C, cpptype(C,rt),QualType[cpptype(C,arg) for arg in args.parameters])
end
cpptype(C,p::Type{CppFptr{f}}) where {f} = pointerTo(C,cpptype(C,f))

# # # # Exposing julia types to C++

const MappedTypes = Dict{Type, QualType}()
const InverseMappedTypes = Dict{QualType, Type}()
isbits_spec(T, allow_singleton = true) = isbitstype(T) && isconcretetype(T) &&
    (allow_singleton || (sizeof(T) > 0 || fieldcount(T) > 0))
function cpptype(C,::Type{T}) where T
    (!(T === Union) && !T.abstract) || error("Cannot create C++ equivalent for abstract types")
    try
    if !haskey(MappedTypes, T)
        AnonClass = CreateAnonymousClass(C, translation_unit(C))
        MappedTypes[T] = typeForDecl(AnonClass)
        InverseMappedTypes[MappedTypes[T]] = T
        # For callable julia types, also add an operator() method to the anonymous
        # class
        if !isempty(T.name.mt)
            linfo = T.name.mt.defs.func
            sig = T.name.mt.defs.sig
            nargt = length(sig.parameters)-1
            tt = Tuple{T, (Any for _ in 1:nargt)...}
            retty = latest_world_return_type(tt)
            if isa(retty,Union) || isabstracttype(retty) || retty === Union{}
              error("Inferred Union or abstract type $retty for return value of lambda")
            end
            # Ok, now we need to figure out what arguments we need to declare to C++. For that purpose,
            # go through the list of defined arguments. Any type that's concrete will be declared as such
            # to C++, anything else will get a template parameter.
            tparamnum = 1
            TPs = Any[]
            argtQTs = QualType[]
            for argt in sig.parameters[2:end]
                if argt.abstract
                    TP = ActOnTypeParameter(C,string("param",tparamnum),tparamnum-1)
                    push!(argtQTs,RValueRefernceTo(C,QualType(typeForDecl(TP))))
                    push!(TPs, TP)
                    tparamnum += 1
                else
                    push!(argtQTs, cpptype(C, argt))
                end
            end
            if isempty(TPs)
                Method = CreateCxxCallMethodDecl(C, AnonClass, makeFunctionType(C, cpptype(C, retty), argtQTs))
                AddCallOpToClass(AnonClass, Method)
                f = get_llvmf_decl(tt)
                @assert f != C_NULL
                FinalizeAnonClass(C, AnonClass)
                ReplaceFunctionForDecl(C, Method,f, DoInline = false, specsig =
                    isbits_spec(T, false) || isbits_spec(retty, false),
                    NeedsBoxed = [false], FirstIsEnv = true, retty = retty, jts = Any[T])
            else
                Params = CreateTemplateParameterList(C,TPs)
                Method = CreateCxxCallMethodDecl(C, AnonClass, makeFunctionType(C, cpptype(C, retty), argtQTs))
                params = pcpp"clang::ParmVarDecl"[
                    CreateParmVarDecl(C, argt,string("__juliavar",i)) for (i,argt) in enumerate(argtQTs)]
                SetFDParams(Method,params)
                D = CreateFunctionTemplateDecl(C,toctx(AnonClass),Params,Method)
                AddDeclToDeclCtx(toctx(AnonClass),pcpp"clang::Decl"(convert(Ptr{Cvoid}, D)))
                FinalizeAnonClass(C, AnonClass)
            end
        end

        # Anything that you want C++ to be able to do with a julia object
        # needs to be declared here.
    end
    catch err
        delete!(MappedTypes,T)
        rethrow(err)
    end
    referenceTo(C, MappedTypes[T])
end

# # # # Section 2: Mapping C++ types into the julia hierarchy
#
# Somewhat simpler than the above, because we simply need to call the
# appropriate Type * methods and marshal everything into the Julia-side
# hierarchy
#

function __decl_name(d)
    @assert d != C_NULL
    ccall((:decl_name,libcxxffi),Ptr{UInt8},(Ptr{Cvoid},),d)
end

function _decl_name(d)
    s = __decl_name(d)
    ret = unsafe_string(s)
    Libc.free(s)
    ret
end

function simple_decl_name(d)
    s = ccall((:simple_decl_name,libcxxffi),Ptr{UInt8},(Ptr{Cvoid},),d)
    ret = unsafe_string(s)
    Libc.free(s)
    ret
end

get_pointee_name(t) = _decl_name(getPointeeCXXRecordDecl(t))

function _get_name(t)
    d = getAsCXXRecordDecl(t)
    if d != C_NULL
        s = __decl_name(d)
    else
        d = isIncompleteType(t)
        @assert d != C_NULL
        s = __decl_name(d)
    end
    s
end

function get_name(t)
    s = _get_name(t)
    ret = unsafe_string(s)
    Libc.free(s)
    ret
end

isAnonymous(t) = (s = _get_name(t); ret = (s == C_NULL); !ret && Libc.free(s); ret)

const KindNull              = 0
const KindType              = 1
const KindDeclaration       = 2
const KindNullPtr           = 3
const KindIntegral          = 4
const KindTemplate          = 5
const KindTemplateExpansion = 6
const KindExpression        = 7
const KindPack              = 8

function getTemplateParameters(cxxd,quoted = false,typeargs = Dict{Int64,Cvoid}())
    targt = Tuple{}
    if isa(cxxd, pcpp"clang::TemplateSpecializationType")
        tmplt = cxxd
    elseif isaClassTemplateSpecializationDecl(pcpp"clang::Decl"(convert(Ptr{Cvoid},cxxd)))
        tmplt = dcastClassTemplateSpecializationDecl(pcpp"clang::Decl"(convert(Ptr{Cvoid},cxxd)))
    elseif isa(cxxd, pcpp"clang::CXXRecordDecl")
        return Tuple{}
    else
        tmplt = cxxd
    end
    targs = getTemplateArgs(tmplt)
    args = Any[]
    for i = 0:(getTargsSize(targs)-1)
        kind = getTargKindAtIdx(targs,i)
        if kind == KindType
            T = juliatype(getTargTypeAtIdx(targs,i),quoted,typeargs; wrapvalue = false)
            push!(args,T)
        elseif kind == KindIntegral
            val = getTargAsIntegralAtIdx(targs,i)
            t = getTargIntegralTypeAtIdx(targs,i)
            push!(args,Val{reinterpret(juliatype(t,quoted,typeargs),[val])[1]})
        else
            error("Unhandled template argument kind ($kind)")
        end
    end
    return quoted ? Expr(:curly,:Tuple,args...) : Tuple{args...}
end

include(joinpath(@__DIR__, "..", "deps", "usr", "clang_constants.jl"))

# TODO: Autogenerate this from the appropriate header
# Decl::Kind
const LinkageSpec = 10


getPointeeType(t::pcpp"clang::Type") = QualType(ccall((:getPointeeType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),t))
getPointeeType(t::QualType) = getPointeeType(extractTypePtr(t))
canonicalType(t::pcpp"clang::Type") = pcpp"clang::Type"(ccall((:canonicalType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),t))

function toBaseType(t::pcpp"clang::Type")
    T = CppBaseType{Symbol(get_name(t))}
    rd = getAsCXXRecordDecl(t)
    if rd != C_NULL
        targs = getTemplateParameters(rd)
        @assert isa(targs, Type)
        if targs != Tuple{}
            T = CppTemplate{T,targs}
        end
    end
    T
end

function isCxxEquivalentType(t)
    (t <: CppPtr) || (t <: CppRef) || (t <: CppValue) || (t <: CppCast) ||
        (t <: CppFptr) || (t <: CppMFptr) || (t <: CppEnum) ||
        (t <: CppDeref) || (t <: CppAddr) || (t <: Ptr) ||
        (t <: Ref) || (t <: JLCppCast)
end

extract_T(::Type{S}) where {T,S<:CppValue{T,N} where N} = T

function juliatype(t::QualType, quoted = false, typeargs = Dict{Int,Cvoid}();
        wrapvalue = true, valuecvr = true)
    CVR = extractCVR(t)
    t = extractTypePtr(t)
    t = canonicalType(t)
    local T::Type
    if isVoidType(t)
        T = Cvoid
    elseif isBooleanType(t)
        T = Bool
    elseif isPointerType(t)
        pt = getPointeeType(t)
        tt = juliatype(pt,quoted,typeargs)
        if isa(tt,Expr) ? tt.args[1] == :CppFunc : tt <: CppFunc
            return quoted ? :(CppFptr{$tt}) : CppFptr{tt}
        elseif CVR != NullCVR || (isa(tt,Expr) ?
            (tt.args[1] == :CppValue || tt.args[1] == :CppPtr || tt.args[1] == :CppRef) :
            (tt <: CppValue || tt <: CppPtr || tt <: CppRef))
            if isa(tt,Expr) ? tt.args[1] == :CppValue : tt <: CppValue
                tt = isa(tt,Expr) ? tt.args[2] : extract_T(tt)
            end
            xT = quoted ? :(CppPtr{$tt,$CVR}) : CppPtr{tt, CVR}
            # As a special case, if we're returning a jl_value_t *, interpret it
            # as a julia type.
            if !quoted && xT == pcpp"jl_value_t"
                return quoted ? :(Any) : Any
            end
            return xT
        else
            return quoted ? :(Ptr{$tt}) : Ptr{tt}
        end
    elseif isFunctionPointerType(t)
        error("Is Function Pointer")
    elseif isFunctionType(t)
        @assert !quoted
        if isFunctionProtoType(t)
            t = pcpp"clang::FunctionProtoType"(convert(Ptr{Cvoid},t))
            rt = getReturnType(t)
            args = QualType[]
            for i = 0:(getNumParams(t)-1)
                push!(args,getParam(t,i))
            end
            f = CppFunc{juliatype(rt,quoted,typeargs), Tuple{map(x->juliatype(x,quoted,typeargs),args)...}}
            return f
        else
            error("Function has no proto type")
        end
    elseif isMemberFunctionPointerType(t)
        @assert !quoted
        cxxd = QualType(getMemberPointerClass(t))
        pointee = getMemberPointerPointee(t)
        return CppMFptr{juliatype(cxxd,quoted,typeargs),juliatype(pointee,quoted,typeargs)}
    elseif isReferenceType(t)
        t = getPointeeType(t)
        pointeeT = juliatype(t,quoted,typeargs; wrapvalue = false, valuecvr = false)
        if !isa(pointeeT, Type) || !haskey(MappedTypes, pointeeT)
            return quoted ? :( CppRef{$pointeeT,$CVR} ) : CppRef{pointeeT,CVR}
        else
            return quoted ? :( $pointeeT ) : pointeeT
        end
    elseif isCharType(t)
        T = UInt8
    elseif isEnumeralType(t)
        T = juliatype(getUnderlyingTypeOfEnum(t))
        if !isAnonymous(t)
            T = CppEnum{Symbol(get_name(t)),T}
        end
    elseif isIntegerType(t)
        kind = builtinKind(t) - 12
        if kind == cLong || kind == cLongLong
            T = Int64
        elseif kind == cULong || kind == cULongLong
            T = UInt64
        elseif kind == cUInt
            T = UInt32
        elseif kind == cInt
            T = Int32
        elseif kind == cUShort
            T = UInt16
        elseif kind == cShort
            T = Int16
        elseif kind == cChar_U || kind == cChar_S
            T = UInt8
        elseif kind == cSChar
            T = Int8
        else
            ccall(:jl_,Cvoid,(Any,),kind)
            dump(t)
            error("Unrecognized Integer type")
        end
    elseif isFloatingType(t)
        kind = builtinKind(t)
        if kind == cHalf
            T = Float16
        elseif kind == cFloat
            T = Float32
        elseif kind == cDouble
            T = Float64
        else
            error("Unrecognized floating point type")
        end
    elseif isArrayType(t)
        @assert !quoted
        return CxxArrayType{juliatype(getArrayElementType(t),quoted,typeargs)}
    # If this is not dependent, the generic logic handles it fine
    elseif isElaboratedType(t) && isDependentType(t)
        return juliatype(desugar(pcpp"clang::ElaboratedType"(convert(Ptr{Cvoid},t))), quoted, typeargs)
    elseif isTemplateTypeParmType(t)
        t = pcpp"clang::TemplateTypeParmType"(convert(Ptr{Cvoid},t))
        idx = getTTPTIndex(t)
        if !haskey(typeargs, idx)
            error("No translation for typearg")
        end
        return typeargs[idx]
    elseif isTemplateSpecializationType(t) && isDependentType(t)
        t = pcpp"clang::TemplateSpecializationType"(convert(Ptr{Cvoid},t))
        TD = getUnderlyingTemplateDecl(t)
        TDargs = getTemplateParameters(t,quoted,typeargs)
        T = CppBaseType{Symbol(get_name(TD))}
        if quoted
            exprT = :(CppTemplate{$T,$TDargs})
            valuecvr && (exprT = :(CxxQualType{$exprT,$CVR}))
            wrapvalue && (exprT = :(CppValue{$exprT}))
            return exprT
        else
            r = length(TDargs.parameters):(getNumParameters(TD)-1)
            @assert isempty(r)
            T = CppTemplate{T,Tuple{TDargs.parameters...}}
            if valuecvr
                T = CxxQualType{T,CVR}
            end
            if wrapvalue
                T = CppValue{T}
            end
            return T
        end
    else
        cxxd = getAsCXXRecordDecl(t)
        if cxxd != C_NULL && isLambda(cxxd)
            if haskey(InverseMappedTypes, QualType(t))
                T = InverseMappedTypes[QualType(t)]
            else
                T = lambdaForType(QualType(t))
            end
        else
            T = toBaseType(t)
        end
        if valuecvr
            T = CxxQualType{T,CVR}
        end
        if wrapvalue
            T = CppValue{T}
        end
        return T
    end
    quoted ? :($T) : T
end

# Some other utilities (some of which are used externally)

function getFTyReturnType(T::QualType)
    @assert isFunctionType(T)
    getFunctionTypeReturnType(extractTypePtr(T))
end

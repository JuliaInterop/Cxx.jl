# Translating between clang and julia types

# # # # Section 1: Mapping Julia types to clang types
#
# The main function defined by this section is cpptype(T), which for a given
# julia type `T` will return a QualType, representing clang's interpretation
# of this type

# # # Built-in clang types
chartype(C) = QualType(pcpp"clang::Type"(ccall((:cT_cchar,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},),&C)))
winttype(C) = QualType(pcpp"clang::Type"(ccall((:cT_wint,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},),&C)))
cpptype(C,::Type{UInt8}) = chartype(C)

# Mapping some basic julia bitstypes to C's intrinsic types
# We could use Cint, etc. here, but we actually already do that
# in the C++ side, which makes this easy:
for (jlt, sym) in
    ((Void, :cT_void),
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
            Ptr{Void},(Ptr{ClangCompiler},),&C )))

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
                error("Could not find $fpart in translation unit")
            else
                error("Could not find $fpart in context $(_decl_name(lastcur))")
            end
        end
    end
    cur
end

# Convenience method for splitting a qualified name into actual parts
function lookup_ctx(C, fname::String;
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
    ts = Array(QualType,nparams)
    for (i,t) in enumerate(targs.parameters)
        if isa(t,Type)
            ts[i] = cpptype(C,t)
        elseif isa(t,Integer) || isa(t,CppEnum)
            ts[i] = cpptype(C,typeof(t))
            integralValues[i] = convert(UInt64,isa(t,CppEnum) ? t.val : t)
            integralValuesPresent[i] = 1
            bitwidths[i] = isa(t,Bool) ? 8 : sizeof(typeof(t))
        else
            error("Unhandled template parameter type ($t)")
        end
    end
    d = pcpp"clang::ClassTemplateSpecializationDecl"(ccall((:SpecializeClass,libcxxffi),Ptr{Void},
            (Ptr{ClangCompiler},Ptr{Void},Ptr{Ptr{Void}},Ptr{UInt64},Ptr{UInt8},UInt32),
            &C,cxxt.ptr,[p.ptr for p in ts],integralValues,integralValuesPresent,length(ts)))
    d
end

function specialize_template_clang(C,cxxt::pcpp"clang::ClassTemplateDecl",targs)
    @assert cxxt != C_NULL
    integralValues = zeros(UInt64,length(targs))
    integralValuesPresent = zeros(UInt8,length(targs))
    bitwidths = zeros(UInt32,length(targs))
    ts = Array(QualType,length(targs))
    for (i,t) in enumerate(targs)
        if isa(t,pcpp"clang::Type") || isa(t,QualType)
            ts[i] = QualType(t)
        elseif isa(t,Integer) || isa(t,CppEnum)
            ts[i] = cpptype(C, typeof(t))
            integralValues[i] = convert(UInt64,isa(t,CppEnum) ? t.val : t)
            integralValuesPresent[i] = 1
            bitwidths[i] = isa(t,Bool) ? 8 : sizeof(typeof(t))
        else
            error("Unhandled template parameter type ($t)")
        end
    end
    d = pcpp"clang::ClassTemplateSpecializationDecl"(ccall((:SpecializeClass,libcxxffi),Ptr{Void},
            (Ptr{ClangCompiler},Ptr{Void},Ptr{Void},Ptr{UInt64},Ptr{UInt8},UInt32),&C,
            cxxt.ptr,[p.ptr for p in ts],integralValues,integralValuesPresent,length(ts)))
    d
end

# # The actual decl lookup
# since we split out all the actual meat above, this is now simple

function cppdecl{fname}(C,T::Type{CppBaseType{fname}})
    # Let's get a clang level representation of this type
    lookup_ctx(C,fname)
end
cppdecl{s}(C,::Type{CppEnum{s}}) = lookup_ctx(C,s)

function cppdecl{T,targs}(C,TT::Type{CppTemplate{T,targs}})
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
function cppdecl{T,CVR}(C,::Union(
    Type{CppPtr{T,CVR}}, Type{CxxQualType{T,CVR}}, Type{CppRef{T,CVR}}))
    cppdecl(C,T)
end

# Get a clang Type * for the decl we have looked up.
# @cxx (@cxx dyn_cast{vcpp"clang::TypeDecl"}(d))->getTypeForDecl()
function typeForDecl(d::Union(
        # Luckily Decl is the first base for these, so we can get away
        # with only one function on the C++ side that takes a Decl*
        pcpp"clang::Decl",pcpp"clang::CXXRecordDecl",
        pcpp"clang::ClassTemplateSpecializationDecl"))
    @assert d != C_NULL
    pcpp"clang::Type"(ccall((:typeForDecl,libcxxffi),Ptr{Void},(Ptr{Void},),d))
end

for sym in (:withConst, :withVolatile, :withRestrict)
    @eval ($sym)(T::QualType) =
        QualType(ccall(($(quot(sym)),libcxxffi),Ptr{Void},(Ptr{Void},),T))
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
addQualifiers(clangT::pcpp"clang::Type",CVR) = addQualifiers(QualType(clangT.ptr),CVR)

# And finally the actual definition of cpptype

cpptype{s}(C,p::Type{CppEnum{s}}) = QualType(typeForDecl(cppdecl(C,p)))
cpptype{T}(C,p::Type{CxxArrayType{T}}) = getIncompleteArrayType(C,cpptype(C,T))
function cpptype{T,CVR}(C,p::Type{CppPtr{T,CVR}})
    addQualifiers(pointerTo(C,cpptype(C,T)),CVR)
end
function cpptype{T,CVR}(C,p::Type{CxxQualType{T,CVR}})
    addQualifiers(typeForDecl(cppdecl(C,T)),CVR)
end
cpptype{T,N}(C,p::Type{CppValue{T,N}}) = cpptype(C,T)
cpptype{T}(C,p::Type{CppValue{T}}) = cpptype(C,T)
cpptype{s}(C,p::Type{CppBaseType{s}}) = QualType(typeForDecl(cppdecl(C,p)))
function cpptype{T,CVR}(C,p::Type{CppRef{T,CVR}})
    referenceTo(C,addQualifiers(typeForDecl(cppdecl(C,T)),CVR))
end

cpptype{T}(C,p::Type{Ptr{T}}) = pointerTo(C,cpptype(C,T))

function cpptype{base,fptr}(C,p::Type{CppMFptr{base,fptr}})
    makeMemberFunctionType(C, cpptype(C,base), cpptype(C,fptr))
end
function cpptype{rt, args}(C,p::Type{CppFunc{rt,args}})
    makeFunctionType(C, cpptype(C,rt),QualType[cpptype(C,arg) for arg in args])
end
cpptype{f}(C,p::Type{CppFptr{f}}) = pointerTo(C,cpptype(C,f))

cpptype(C,F::Type{Function}) = cpptype(C,pcpp"jl_function_t")

# # # # Section 2: Mapping Julia types to clang types
#
# Somewhat simpler than the above, because we simply need to call the
# appropriate Type * methods and marshal everything into the Julia-side
# hierarchy
#

function __decl_name(d)
    @assert d != C_NULL
    ccall((:decl_name,libcxxffi),Ptr{UInt8},(Ptr{Void},),d)
end

function _decl_name(d)
    s = __decl_name(d)
    ret = bytestring(s)
    Libc.free(s)
    ret
end

function simple_decl_name(d)
    s = ccall((:simple_decl_name,libcxxffi),Ptr{UInt8},(Ptr{Void},),d)
    ret = bytestring(s)
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
    ret = bytestring(s)
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

function getTemplateParameters(cxxd,typeargs = Dict{Int64,Void}())
    targt = Tuple{}
    if isaClassTemplateSpecializationDecl(pcpp"clang::Decl"(cxxd.ptr))
        tmplt = dcastClassTemplateSpecializationDecl(pcpp"clang::Decl"(cxxd.ptr))
    elseif isa(cxxd,pcpp"clang::CXXRecordDecl")
        return Tuple{}
    else
        tmplt = cxxd
    end
    targs = getTemplateArgs(tmplt)
    args = Any[]
    for i = 0:(getTargsSize(targs)-1)
        kind = getTargKindAtIdx(targs,i)
        if kind == KindType
            T = juliatype(getTargTypeAtIdx(targs,i),typeargs)
            if T <: CppValue
                T = T.parameters[1]
            end
            push!(args,T)
        elseif kind == KindIntegral
            val = getTargAsIntegralAtIdx(targs,i)
            t = getTargIntegralTypeAtIdx(targs,i)
            push!(args,convert(juliatype(t,typeargs),val))
        else
            error("Unhandled template argument kind ($kind)")
        end
    end
    targt = Tuple{args...}
end

# TODO: Autogenerate this from the appropriate header
const cVoid      = 0
const cBool      = 1
const cChar_U    = 2
const cUChar     = 3
const cWChar_U   = 4
const cChar16    = 5
const cChar32    = 6
const cUShort    = 7
const cUInt      = 8
const cULong     = 9
const cULongLong = 10
const CUInt128   = 11
const cChar_S    = 12
const cSChar     = 13
const cWChar_S   = 14
const cShort     = 15
const cInt       = 16
const cLong      = 17
const cLongLong  = 18
const cInt128    = 19
const cHalf      = 20
const cFloat     = 21
const cDouble    = 22

# Decl::Kind
const LinkageSpec = 10


getPointeeType(t::pcpp"clang::Type") = QualType(ccall((:getPointeeType,libcxxffi),Ptr{Void},(Ptr{Void},),t.ptr))
getPointeeType(t::QualType) = getPointeeType(extractTypePtr(t))
canonicalType(t::pcpp"clang::Type") = pcpp"clang::Type"(ccall((:canonicalType,libcxxffi),Ptr{Void},(Ptr{Void},),t))

function toBaseType(t::pcpp"clang::Type")
    T = CppBaseType{symbol(get_name(t))}
    rd = getAsCXXRecordDecl(t)
    if rd.ptr != C_NULL
        targs = getTemplateParameters(rd)
        @assert isa(targs, Type)
        if targs != Tuple{}
            T = CppTemplate{T,targs}
        end
    end
    T
end

function juliatype(t::QualType, typeargs = Dict{Int,Void}())
    CVR = extractCVR(t)
    t = extractTypePtr(t)
    t = canonicalType(t)
    if isVoidType(t)
        return Void
    elseif isBooleanType(t)
        return Bool
    elseif isPointerType(t)
        pt = getPointeeType(t)
        tt = juliatype(pt)
        if tt <: CppFunc
            return CppFptr{tt}
        elseif CVR != NullCVR || tt <: CppValue || tt <: CppPtr || tt <: CppRef
            if tt <: CppValue
                tt = tt.parameters[1]
            end
            T = CppPtr{tt,CVR}
            # As a special case, if we're returning a jl_value_t *, interpret it
            # as a julia type.
            if T == pcpp"jl_value_t"
                return Any
            end
            return T
        else
            return Ptr{tt}
        end
    elseif isFunctionPointerType(t)
        error("Is Function Pointer")
    elseif isFunctionType(t)
        if isFunctionProtoType(t)
            t = pcpp"clang::FunctionProtoType"(t.ptr)
            rt = getReturnType(t)
            args = QualType[]
            for i = 0:(getNumParams(t)-1)
                push!(args,getParam(t,i))
            end
            f = CppFunc{juliatype(rt), Tuple{map(juliatype,args)...}}
            return f
        else
            error("Function has no proto type")
        end
    elseif isMemberFunctionPointerType(t)
        cxxd = QualType(getMemberPointerClass(t))
        pointee = getMemberPointerPointee(t)
        return CppMFptr{juliatype(cxxd),juliatype(pointee)}
    elseif isReferenceType(t)
        t = getPointeeType(t)
        jt = juliatype(t)
        if jt <: CppValue
            return CppRef{toBaseType(extractTypePtr(t)),CVR}
        else
            return CppRef{jt,CVR}
        end
    elseif isCharType(t)
        return UInt8
    elseif isEnumeralType(t)
        if isAnonymous(t)
            return Int32
        else
            return CppEnum{symbol(get_name(t))}
        end
    elseif isIntegerType(t)
        kind = builtinKind(t)
        if kind == cLong || kind == cLongLong
            return Int64
        elseif kind == cULong || kind == cULongLong
            return UInt64
        elseif kind == cUInt
            return UInt32
        elseif kind == cInt
            return Int32
        elseif kind == cChar_U || kind == cChar_S
            return UInt8
        elseif kind == cSChar
            return Int8
        end
        dump(t)
        error("Unrecognized Integer type")
    elseif isFloatingType(t)
        kind = builtinKind(t)
        if kind == cHalf
            return Float16
        elseif kind == cFloat
            return Float32
        elseif kind == cDouble
            return Float64
        end
        error("Unrecognized floating point type")
    elseif isArrayType(t)
        return CxxArrayType{juliatype(getArrayElementType(t))}
    # If this is not dependent, the generic logic handles it fine
    elseif isElaboratedType(t) && isDependentType(t)
        return juliatype(desugar(pcpp"clang::ElaboratedType"(t.ptr)), typeargs)
    elseif isTemplateTypeParmType(t)
        t = pcpp"clang::TemplateTypeParmType"(t.ptr)
        idx = getTTPTIndex(t)
        if !haskey(typeargs, idx)
            error("No translation for typearg")
        end
        return typeargs[idx]
    elseif isTemplateSpecializationType(t) && isDependentType(t)
        t = pcpp"clang::TemplateSpecializationType"(t.ptr)
        TD = getUnderlyingTemplateDecl(t)
        TDargs = getTemplateParameters(t,typeargs)
        r = length(TDargs.parameters):(getNumParameters(TD)-1)
        @assert isempty(r)
        T = CppBaseType{symbol(get_name(TD))}
        return CppValue{CxxQualType{CppTemplate{T,Tuple{TDargs.parameters...}},CVR}}
    else
        return CppValue{CxxQualType{toBaseType(t),CVR}}
    end
    return Ptr{Void}
end

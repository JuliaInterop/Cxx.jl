# Translating between clang and julia types
#
# Section 1: Mapping Julia types to clang types
#
# The main function defined by this section is cpptype(T), which for a given
# julia type `T` will return a QualType, representing clang's interpretation
# of this type.

# Mapping some basic julia bitstypes to C's intrinsic types
function cpptype(::Type{T}, cc::CxxCompiler) where {T<:CxxBuiltinTs}
    ctx = get_ast_context(get_compiler_instance(cc))
    return jlty_to_clty(T, ctx)
end

# Intended for end users to extend if they wrap a C++ type in a julia type, but
# want to have it automatically converted to a C++ compatible type
cppconvert(x) = x

# Mapping the C++ object hierarchy types back to clang types
#
# This is more complicated than simply mapping builtin types and proceeds in stages.
#
# 1. Perform the name lookup of the inner most declaration (cppdecl)
#   - While doing this we also need to perform template instantiation
# 2. Resolve pointer/reference types in clang/land
# 3. Add CVR qualifiers
#

function lookup(s::Symbol, cc::CxxCompiler)
    qualname = string(s)
    # std::vector<int>
    #            ↑ (suffix_idx)
    # is_void<char>::value
    #        ↑ (suffix_idx)
    suffix_idx = findnext(x->x ∈ ('<', '(', '[', '*', '&'), qualname, 1)
    suffix_idx = isnothing(suffix_idx) ? 0 : suffix_idx

    # std::vector<int>
    #     ↑ (last_colon_idx)
    last_coloncolon_idx = findlast("::", qualname)
    last_colon_idx = isnothing(last_coloncolon_idx) ? 0 : last(last_coloncolon_idx)
    if last_colon_idx ≥ suffix_idx
        #       is_void<char>::value
        # (suffix_idx) ↑      ↑ (last_colon_idx)
        decl_name = qualname[last_colon_idx+1:end]
    else
        decl_name = qualname[last_colon_idx+1:suffix_idx-1]
    end

    result = cc.lookup(cc.irgen, decl_name, qualname)
    !result && error("failed to lookup decl: $s (target: $decl_name, scope: $qualname)")

    return get_decl(cc.lookup)
end

cppdecl(x::Type{CxxBaseType{S}}, cc::CxxCompiler) where {S} = lookup(S, cc)
cppdecl(x::Type{CxxEnum{S,T}}, cc::CxxCompiler) where {S,T} = lookup(S, cc)

function cppdecl(x::Type{CxxTemplate{T,TARGS}}, cc::CxxCompiler) where {T,TARGS}
    template_decl = ClassTemplateDecl(cppdecl(T, cc))
    @assert template_decl.ptr != C_NULL "can not cast the decl to a `ClassTemplateDecl`."
    targs = []
    for targ in TARGS.parameters
        if targ isa Type
            push!(targs, cpptype(targ, cc))
        elseif targ isa Integer
            push!(targs, targ)
        elseif targ isa CxxEnum
            push!(targs, unsigned(targ.val))
        else
            error("Unhandled template parameter type: $targ")
        end
    end
    ctx = get_ast_context(get_compiler_instance(cc))
    llvm_ctx = get_llvm_context(cc)
    return specialize(llvm_ctx, ctx, template_decl, targs...)
end

# For getting the decl ignore the CVR qualifiers, pointer qualification, etc.
# and just do the lookup on the base decl
cppdecl(::Type{CxxPtr{T,CVR}}, cc::CxxCompiler) where {T,CVR} = cppdecl(T, cc)
cppdecl(::Type{CxxRef{T,CVR}}, cc::CxxCompiler) where {T,CVR} = cppdecl(T, cc)

# the actual definition of cpptype
cpptype(x::Type{CxxBaseType{S}}, cc::CxxCompiler) where {S} = get_type_for_decl(cppdecl(x, cc))
cpptype(::Type{T}, cc::CxxCompiler) where {T<:CxxTemplate} = get_type_for_decl(cppdecl(T, cc))
cpptype(::Type{T}, cc::CxxCompiler) where {T<:CxxEnum} = get_type_for_decl(cppdecl(T, cc))

cpptype(::Type{CxxValue{T,N}}, cc::CxxCompiler) where {T,N} = cpptype(C,T)
cpptype(::Type{CxxValue{T}}, cc::CxxCompiler) where {T} = cpptype(C,T)

# use getConstantArrayType or even Sema::BuildArrayType?
# cpptype(::Type{CxxArrayType{T}}, cc::CxxCompiler) where {T} = getIncompleteArrayType(C, cpptype(T, cc))

function add_qualifiers(ty::QualType, (C, V, R))
    C && (ty = with_const(ty);)
    R && (ty = with_restrict(ty);)
    V && (ty = with_volatile(ty);)
    return ty
end

function cpptype(::Type{CxxQualType{T,CVR}}, cc::CxxCompiler) where {T,CVR}
    return add_qualifiers(cpptype(T, cc), CVR)
end

function cpptype(::Type{CxxPtr{T,CVR}}, cc::CxxCompiler) where {T,CVR}
    ctx = get_ast_context(get_compiler_instance(cc))
    return add_qualifiers(get_pointer_type(ctx, cpptype(T, cc)), CVR)
end

function cpptype(::Type{Ptr{T}}, cc::CxxCompiler) where {T}
    ctx = get_ast_context(get_compiler_instance(cc))
    return get_pointer_type(ctx, cpptype(T, cc))
end

function cpptype(::Type{CxxRef{T,CVR}}, cc::CxxCompiler) where {T,CVR}
    ctx = get_ast_context(get_compiler_instance(cc))
    return get_lvalue_reference_type(ctx, add_qualifiers(cpptype(T, cc), CVR))
end

function cpptype(::Type{Ref{T}}, cc::CxxCompiler) where {T}
    ctx = get_ast_context(get_compiler_instance(cc))
    return get_lvalue_reference_type(ctx, cpptype(T, cc))
end

# # This is a hack, we should find a better way to do this
# function cpptype(C,p::Type{CxxQualType{T,CVR}}) where {T<:CxxLambda,CVR}
#     add_qualifiers(type_for_lambda(T),CVR)
# end

# use Sema::BuildFunctionType?
# function cpptype(C,p::Type{CxxFunc{rt,args}}) where {rt, args}
#     makeFunctionType(C, cpptype(C,rt),QualType[cpptype(C,arg) for arg in args.parameters])
# end

function cpptype(::Type{CxxFptr{F}}, cc::CxxCompiler) where {F}
    ctx = get_ast_context(get_compiler_instance(cc))
    get_pointer_type(ctx, cpptype(F, cc))
end

function cpptype(::Type{CxxMFptr{BASE,FPTR}}, cc::CxxCompiler) where {BASE,FPTR}
    ctx = get_ast_context(get_compiler_instance(cc))
    get_member_pointer_type(ctx, cpptype(BASE, cc), cpptype(FPTR, cc))
end
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

getPointeeType(t::pcpp"clang::Type") = QualType(ccall((:getPointeeType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),t))
getPointeeType(t::QualType) = getPointeeType(extractTypePtr(t))
canonicalType(t::pcpp"clang::Type") = pcpp"clang::Type"(ccall((:canonicalType,libcxxffi),Ptr{Cvoid},(Ptr{Cvoid},),t))

function toBaseType(t::pcpp"clang::Type")
    T = CxxBaseType{Symbol(get_name(t))}
    rd = getAsCXXRecordDecl(t)
    if rd != C_NULL
        targs = getTemplateParameters(rd)
        @assert isa(targs, Type)
        if targs != Tuple{}
            T = CxxTemplate{T,targs}
        end
    end
    T
end

function isCxxEquivalentType(t)
    (t <: CxxPtr) || (t <: CxxRef) || (t <: CxxValue) || (t <: CppCast) ||
        (t <: CxxFptr) || (t <: CxxMFptr) || (t <: CxxEnum) ||
        (t <: CppDeref) || (t <: CppAddr) || (t <: Ptr) ||
        (t <: Ref) || (t <: JLCppCast)
end

extract_T(::Type{S}) where {T,S<:CxxValue{T,N} where N} = T

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
        if isa(tt,Expr) ? tt.args[1] == :CxxFunc : tt <: CxxFunc
            return quoted ? :(CxxFptr{$tt}) : CxxFptr{tt}
        elseif CVR != NullCVR || (isa(tt,Expr) ?
            (tt.args[1] == :CxxValue || tt.args[1] == :CxxPtr || tt.args[1] == :CxxRef) :
            (tt <: CxxValue || tt <: CxxPtr || tt <: CxxRef))
            if isa(tt,Expr) ? tt.args[1] == :CxxValue : tt <: CxxValue
                tt = isa(tt,Expr) ? tt.args[2] : extract_T(tt)
            end
            xT = quoted ? :(CxxPtr{$tt,$CVR}) : CxxPtr{tt, CVR}
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
            f = CxxFunc{juliatype(rt,quoted,typeargs), Tuple{map(x->juliatype(x,quoted,typeargs),args)...}}
            return f
        else
            error("Function has no proto type")
        end
    elseif isMemberFunctionPointerType(t)
        @assert !quoted
        cxxd = QualType(getMemberPointerClass(t))
        pointee = getMemberPointerPointee(t)
        return CxxMFptr{juliatype(cxxd,quoted,typeargs),juliatype(pointee,quoted,typeargs)}
    elseif isReferenceType(t)
        t = getPointeeType(t)
        pointeeT = juliatype(t,quoted,typeargs; wrapvalue = false, valuecvr = false)
        if !isa(pointeeT, Type) || !haskey(MappedTypes, pointeeT)
            return quoted ? :( CxxRef{$pointeeT,$CVR} ) : CxxRef{pointeeT,CVR}
        else
            return quoted ? :( $pointeeT ) : pointeeT
        end
    elseif isCharType(t)
        T = UInt8
    elseif isEnumeralType(t)
        T = juliatype(getUnderlyingTypeOfEnum(t))
        if !isAnonymous(t)
            T = CxxEnum{Symbol(get_name(t)),T}
        end
    elseif isIntegerType(t)
        kind = builtinKind(t)
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
        T = CxxBaseType{Symbol(get_name(TD))}
        if quoted
            exprT = :(CxxTemplate{$T,$TDargs})
            valuecvr && (exprT = :(CxxQualType{$exprT,$CVR}))
            wrapvalue && (exprT = :(CxxValue{$exprT}))
            return exprT
        else
            r = length(TDargs.parameters):(getNumParameters(TD)-1)
            @assert isempty(r)
            T = CxxTemplate{T,Tuple{TDargs.parameters...}}
            if valuecvr
                T = CxxQualType{T,CVR}
            end
            if wrapvalue
                T = CxxValue{T}
            end
            return T
        end
    else
        cxxd = getAsCXXRecordDecl(t)
        if cxxd != C_NULL && isLambda(cxxd)
            if haskey(InverseMappedTypes, QualType(t))
                T = InverseMappedTypes[QualType(t)]
            else
                T = lambda_for_type(QualType(t))
            end
        else
            T = toBaseType(t)
        end
        if valuecvr
            T = CxxQualType{T,CVR}
        end
        if wrapvalue
            T = CxxValue{T}
        end
        return T
    end
    quoted ? :($T) : T
end

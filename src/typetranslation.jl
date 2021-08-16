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
    @assert template_decl.ptr != C_NULL "can not dyn_cast the decl to a `ClassTemplateDecl`."
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

get_type(decl, cc::CxxCompiler) = get_decl_type(get_ast_context(get_compiler_instance(cc)), decl)

# the actual definition of cpptype
cpptype(x::Type{CxxBaseType{S}}, cc::CxxCompiler) where {S} = get_type(cppdecl(x, cc), cc)
cpptype(::Type{T}, cc::CxxCompiler) where {T<:CxxTemplate} = get_type(cppdecl(T, cc), cc)
cpptype(::Type{T}, cc::CxxCompiler) where {T<:CxxEnum} = get_type(cppdecl(T, cc), cc)

cpptype(::Type{CxxValue{T,N}}, cc::CxxCompiler) where {T,N} = cpptype(C,T)
cpptype(::Type{CxxValue{T}}, cc::CxxCompiler) where {T} = cpptype(C,T)

# use getConstantArrayType or even Sema::BuildArrayType?
# cpptype(::Type{CxxArrayType{T}}, cc::CxxCompiler) where {T} = getIncompleteArrayType(C, cpptype(T, cc))

function add_qualifiers(ty::QualType, (C, V, R))
    C && (ty = add_const(ty);)
    V && (ty = add_volatile(ty);)
    R && (ty = add_restrict(ty);)
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
    return add_qualifiers(get_lvalue_reference_type(ctx, cpptype(T, cc)), CVR)
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
    # get_member_pointer_type(ctx, cpptype(FPTR, cc), cpptype(BASE, cc)) # ?
end

# Section 2: Mapping C++ types into the julia hierarchy
#
# Somewhat simpler than the above, because we simply need to call the
# appropriate Type * methods and marshal everything into the Julia-side
# hierarchy.
#

function juliatype(x::T) where {T<:AbstractBuiltinType}
    cvr = get_qualifiers(x)
    t = clty_to_jlty(x)
    if cvr == NullCVR
        return t
    else
        return CxxQualType{t, cvr}
    end
end

juliatype(x::QualType) = juliatype(typeclass(x))

# get_cxx_value_type(::Type{S}) where {S} = S
# get_cxx_value_type(::Type{S}) where S<:CxxValue{T,N} where {T,N} = T

get_qualifiers(ty::AbstractQualType) = is_const(ty), is_volatile(ty), is_restrict(ty)

function juliatype(x::PointerType)
    cvr = get_qualifiers(x)
    ptree_clty = get_pointee_type(x)
    ptree_jlty = juliatype(ptree_clty)
    if ptree_jlty <: CxxFunc
        return CxxFptr{ptree_jlty}
    elseif ptree_jlty == pcpp"jl_value_t"
        # As a special case, if we're returning a jl_value_t *, interpret it as a julia type.
        return Any
    elseif cvr == NullCVR
        return Ptr{ptree_jlty}
    else
        return CxxPtr{ptree_jlty, cvr}
    end
end

function juliatype(x::AbstractReferenceType)
    ptree = juliatype(get_pointee_type(x))
    cvr = get_qualifiers(x)
    return CxxRef{ptree, cvr}
end

juliatype(x::TagType) = juliatype(typeclass(x))

function juliatype(x::EnumType)
    t = juliatype(get_integer_type(x))
    n = name(x)
    sym = isempty(n) ? gensym() : Symbol(n)
    return CxxEnum{sym, t}
end

function juliatype(x::RecordType)
    n = name(x)
    sym = isempty(n) ? gensym() : Symbol(n)
    cvr = get_qualifiers(x)
    if cvr == NullCVR
       return CxxBaseType{Symbol(n)}
    else
       return CxxQualType{CxxBaseType{Symbol(n)}, cvr}
    end
end

juliatype(x::FunctionNoProtoType) = CxxFunc{juliatype(get_return_type(x))}

function juliatype(x::FunctionProtoType)
    rt = juliatype(get_return_type(x))
    argts = juliatype.(get_params(x))
    return CxxFunc{rt, Tuple{argts...}}
end

juliatype(x::TypedefType) = juliatype(desugar(x))
juliatype(x::ElaboratedType) = juliatype(desugar(x))

function juliatype(x::MemberPointerType)
    class = juliatype(get_class(x))
    ptree = juliatype(get_pointee_type(x))
    return CxxMFptr{class, ptree}
end

function juliatype(x::TemplateSpecializationType)
    base_ty = CxxBaseType{Symbol(name(x))}
    args = get_template_args(x)
    argts = []
    for arg in args
        k = get_kind(arg)
        if k == CXTemplateArgument_ArgKind_Integral
            int_ty = juliatype(get_integral_type(x))
            int_val = get_as_integral(x)
            push!(argts, Base.convert(int_ty, int_val))
            dispose(int_val)
        elseif k == CXTemplateArgument_ArgKind_Type
            push!(argts, juliatype(get_as_type(arg)))
        else
            error("Unhandled template argument kind: $k")
        end
    end
    cvr = get_qualifiers(x)
    return CxxQualType{CxxTemplate{base_ty, Tuple{argts...}}, cvr}
end

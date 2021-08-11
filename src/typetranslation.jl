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
    if last_colon_idx > suffix_idx
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
    @show targs
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
    C && (ty = add_const(x);)
    R && (ty = add_restrict(x);)
    V && (ty = add_volatile(x);)
    return ty
end

function cpptype(::Type{CxxQualType{T,CVR}}, cc::CxxCompiler) where {T,CVR}
    add_qualifiers(cpptype(T, cc), CVR)
end

function cpptype(::Type{CxxPtr{T,CVR}}, cc::CxxCompiler) where {T,CVR}
    ctx = get_ast_context(get_compiler_instance(cc))
    add_qualifiers(get_pointer_type(ctx, cpptype(T, cc)), CVR)
end

function cpptype(::Type{Ptr{T}}, cc::CxxCompiler) where {T}
    ctx = get_ast_context(get_compiler_instance(cc))
    get_pointer_type(ctx, cpptype(T, cc))
end

function cpptype(::Type{CxxRef{T,CVR}}, cc::CxxCompiler) where {T,CVR}
    ctx = get_ast_context(get_compiler_instance(cc))
    get_lvalue_reference_type(ctx, add_qualifiers(cpptype(T, cc), CVR))
end

function cpptype(::Type{Ref{T}}, cc::CxxCompiler) where {T}
    ctx = get_ast_context(get_compiler_instance(cc))
    get_lvalue_reference_type(ctx, cpptype(T, cc))
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

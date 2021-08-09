# Translating between clang and julia types

# Section 1: Mapping Julia types to clang types
#
# The main function defined by this section is cpptype(T), which for a given
# julia type `T` will return a QualType, representing clang's interpretation
# of this type.

# Mapping some basic julia bitstypes to C's intrinsic types
cpptype(::Type{T}, ctx::ClangCompiler.ASTContext) where {T<:CxxBuiltinTs} = jlty_to_clty(T, ctx)

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
    last_coloncolon_idx = findlast("::", qualname)
    last_colon_idx = isnothing(last_coloncolon_idx) ? 0 : last_coloncolon_idx[end]
    suffix_idx = findnext(x->x ∈ ('<', '(', '[', '*', '&'), qualname, 1)
    if isnothing(suffix_idx)
        decl_name = qualname[last_colon_idx+1:end]
    else
        decl_name = qualname[last_colon_idx+1:suffix_idx-1]
    end
    result = cc.lookup(cc.irgen, decl_name, qualname)
    !result && error("failed to lookup decl: $s")
    return get_decl(cc.lookup)
end

cppdecl(x::Type{CxxBaseType{S}}, cc::CxxCompiler) where {S} = lookup(S, cc)
cppdecl(x::Type{CxxEnum{S,T}}, cc::CxxCompiler) where {S,T} = lookup(S, cc)

function cppdecl(x::Type{CxxTemplate{T,TARGS}}, cc::CxxCompiler) where {T,TARGS}
    template_decl = ClassTemplateDecl(cppdecl(T, cc))
    specialize_template(C,cxxt,targs)
end

# For getting the decl ignore the CVR qualifiers, pointer qualification, etc.
# and just do the lookup on the base decl
cppdecl(::Type{CxxPtr{T,CVR}}, cc::CxxCompiler) where {T,CVR} = cppdecl(T, cc)
cppdecl(::Type{CxxRef{T,CVR}}, cc::CxxCompiler) where {T,CVR} = cppdecl(T, cc)

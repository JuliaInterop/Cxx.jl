module Cxx

using ClangCompiler
using ClangCompiler.LLVM
using ClangCompiler: QualType, add_const, add_restrict, add_volatile,
                     ClassTemplateDecl,
                     get_ast_context, get_pointer_type, get_type_for_decl,
                     get_lvalue_reference_type


include("clanginstances.jl")
include("cxxtypes.jl")
include("typetranslation.jl")

end

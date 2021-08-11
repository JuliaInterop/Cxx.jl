module Cxx

using ClangCompiler
using ClangCompiler.LLVM
using ClangCompiler: QualType, with_const, with_restrict, with_volatile,
                     ClassTemplateDecl,
                     get_ast_context, get_pointer_type, get_type_for_decl,
                     get_lvalue_reference_type
import ClangCompiler: dispose

include("clanginstances.jl")
export CxxCompiler, dispose

include("cxxtypes.jl")
include("typetranslation.jl")

end

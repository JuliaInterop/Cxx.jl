module Cxx

using ClangCompiler
using ClangCompiler.LLVM
using ClangCompiler: QualType, add_const, add_restrict, add_volatile
using ClangCompiler: is_const, is_volatile, is_restrict, typeclass
using ClangCompiler: TypedefType, get_canonical_type
using ClangCompiler: ClassTemplateDecl
using ClangCompiler: get_ast_context, get_pointer_type, get_decl_type, get_lvalue_reference_type
using ClangCompiler: PointerType, get_pointee_type
using ClangCompiler: MemberPointerType, get_class
using ClangCompiler: AbstractReferenceType
using ClangCompiler: TagType, EnumType, get_integer_type, RecordType
using ClangCompiler: FunctionProtoType, FunctionNoProtoType, get_return_type, get_params
using ClangCompiler: ElaboratedType, desugar
using ClangCompiler: TemplateSpecializationType, get_name
using ClangCompiler: CXTemplateArgument_ArgKind_Integral, CXTemplateArgument_ArgKind_Type
using ClangCompiler: get_kind, get_as_type
using ClangCompiler: getASTContext

import ClangCompiler: dispose

name(x) = get_name(x)

include("clanginstances.jl")
export CxxCompiler, dispose

include("cxxtypes.jl")
export @pcpp_str, @cpcpp_str, @rcpp_str, @vcpp_str

include("typetranslation.jl")

end

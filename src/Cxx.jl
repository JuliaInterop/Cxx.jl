module Cxx

using ClangCompiler
using ClangCompiler.LLVM
import ClangCompiler: QualType

include("clanginstances.jl")
include("cxxtypes.jl")
include("typetranslation.jl")

end

# LLVM Headers

addHeaderDir(joinpath(JULIA_HOME,"../include"))
addHeaderDir(joinpath(Cxx.basepath,"deps-svn/llvm-svn/tools/clang/"))
addHeaderDir(joinpath(Cxx.basepath,"deps-svn/llvm-svn/tools/clang/include/"))


# Load LLVM and clang libraries

defineMacro("__STDC_LIMIT_MACROS")
defineMacro("__STDC_CONSTANT_MACROS")
cxxinclude("llvm/Support/MemoryBuffer.h")
cxxinclude("llvm/Bitcode/ReaderWriter.h")
cxxinclude("llvm/IR/Module.h")
cxxinclude("llvm/IR/IRBuilder.h")
cxxinclude("llvm/IR/Constants.h")
cxxinclude("llvm/IR/CFG.h")
cxxinclude("llvm/Support/GraphWriter.h")
cxxinclude("llvm/ExecutionEngine/ExecutionEngine.h")
cxxinclude("lib/CodeGen/CGValue.h")
cxxinclude("lib/CodeGen/CodeGenTypes.h")
cxxinclude("clang/AST/DeclBase.h")
cxxinclude("clang/AST/Type.h")
cxxinclude("clang/Basic/SourceLocation.h")
cxxinclude("clang/Frontend/CompilerInstance.h")
cxxinclude("clang/AST/DeclTemplate.h")
cxxinclude("llvm/ADT/ArrayRef.h")
cxxinclude("llvm/Analysis/CallGraph.h")

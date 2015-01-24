function addLLVMIncludes(C)

    # LLVM Headers

    addHeaderDir(C,joinpath(JULIA_HOME,"../include"))
    addHeaderDir(C,joinpath(Cxx.depspath,"llvm-svn/tools/clang/"))
    addHeaderDir(C,joinpath(Cxx.depspath,"llvm-svn/tools/clang/include/"))


    # Load LLVM and clang libraries

    defineMacro(C,"__STDC_LIMIT_MACROS")
    defineMacro(C,"__STDC_CONSTANT_MACROS")
    cxxinclude(C,"llvm/Support/MemoryBuffer.h")
    cxxinclude(C,"llvm/Bitcode/ReaderWriter.h")
    cxxinclude(C,"llvm/IR/Module.h")
    cxxinclude(C,"llvm/IR/IRBuilder.h")
    cxxinclude(C,"llvm/IR/Constants.h")
    cxxinclude(C,"llvm/IR/CFG.h")
    cxxinclude(C,"llvm/Support/GraphWriter.h")
    cxxinclude(C,"llvm/ExecutionEngine/ExecutionEngine.h")
    cxxinclude(C,"lib/CodeGen/CGValue.h")
    cxxinclude(C,"lib/CodeGen/CodeGenTypes.h")
    cxxinclude(C,"clang/AST/DeclBase.h")
    cxxinclude(C,"clang/AST/Type.h")
    cxxinclude(C,"clang/Basic/SourceLocation.h")
    cxxinclude(C,"clang/Frontend/CompilerInstance.h")
    cxxinclude(C,"clang/AST/DeclTemplate.h")
    cxxinclude(C,"llvm/ADT/ArrayRef.h")
    cxxinclude(C,"llvm/Analysis/CallGraph.h")

end
addLLVMIncludes(Cxx.__default_compiler__)

include("../deps/path.jl")
const basever = Base.libllvm_version
function addLLVMIncludes(C, clangheaders = true, juliainclude = joinpath(BASE_JULIA_HOME,"../include"),
    llvmdir = joinpath(Cxx.depspath,contains(basever,"svn") ? "llvm-svn" : "llvm-$ver"), ver = VersionNumber(basever))

    # LLVM Headers

    addHeaderDir(C,juliainclude)
    if clangheaders
        addHeaderDir(C,joinpath(llvmdir,"tools/clang/"))
        addHeaderDir(C,joinpath(llvmdir,"tools/clang/lib"))
        addHeaderDir(C,joinpath(llvmdir,"tools/clang/include/"))
    end

    # Load LLVM and clang libraries

    defineMacro(C,"__STDC_LIMIT_MACROS")
    defineMacro(C,"__STDC_CONSTANT_MACROS")
    cxxinclude(C,"llvm/Support/MemoryBuffer.h")
    cxxinclude(C,"llvm/Bitcode/ReaderWriter.h")
    cxxinclude(C,"llvm/IR/Module.h")
    cxxinclude(C,"llvm/IR/IRBuilder.h")
    cxxinclude(C,"llvm/IR/Constants.h")
    cxxinclude(C,"llvm/IR/Value.h")
    if ver > v"3.5"
        cxxinclude(C,"llvm/IR/CFG.h")
    end
    cxxinclude(C,"llvm/Support/GraphWriter.h")
    cxxinclude(C,"llvm/ExecutionEngine/ExecutionEngine.h")
    cxxinclude(C,"llvm/ADT/ArrayRef.h")
    cxxinclude(C,"llvm/Analysis/CallGraph.h")
    if clangheaders
        cxxinclude(C,"lib/CodeGen/CGValue.h")
        cxxinclude(C,"lib/CodeGen/CodeGenTypes.h")
        cxxinclude(C,"lib/CodeGen/CodeGenModule.h")
        cxxinclude(C,"lib/CodeGen/CGBuilder.h")
        cxxinclude(C,"lib/Parse/RAIIObjectsForParser.h")
        cxxinclude(C,"clang/AST/DeclBase.h")
        cxxinclude(C,"clang/AST/Type.h")
        cxxinclude(C,"clang/Basic/SourceLocation.h")
        cxxinclude(C,"clang/Frontend/CompilerInstance.h")
        cxxinclude(C,"clang/AST/DeclTemplate.h")
    end
end
addLLVMIncludes(Cxx.__default_compiler__)

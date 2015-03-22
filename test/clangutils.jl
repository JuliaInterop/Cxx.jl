include("llvmincludes.jl")

cxx"""
#include <iostream>
#include "llvm/Support/raw_os_ostream.h"
#include "llvm/ExecutionEngine/RTDyldMemoryManager.h"
#include "clang/Sema/Sema.h"
using namespace llvm;
"""

function dumpLayout(d)
    ctx = pcpp"clang::ASTContext"(
        ccall((:getASTContext,libcxxffi),Ptr{Void},()))
    icxx"""
        raw_os_ostream OS(std::cout);
        $ctx->DumpRecordLayout(
            dyn_cast<clang::RecordDecl>($d),
            OS,
            false);
        OS.flush();
        (void) (std::cout << std::endl);
    """
end

clangmod = pcpp"llvm::Module"(unsafe_load(cglobal(
        (:clang_shadow_module,libcxxffi),Ptr{Void})))

EE = pcpp"llvm::ExecutionEngine"(unsafe_load(cglobal(
        :jl_ExecutionEngine,Ptr{Void})))

mcjmm = pcpp"llvm::RTDyldMemoryManager"(unsafe_load(cglobal(
        :jl_mcjmm,Ptr{Void})))

cc = pcpp"clang::CompilerInstance"(unsafe_load(cglobal(
    (:clang_compiler,libcxxffi),Ptr{Void})))

pass_llvm_command_line(str) =
    @cxx llvm::cl::ParseCommandLineOptions(1+length(str),pointer([pointer("julia"),[pointer(s) for s in str],convert(Ptr{UInt8},C_NULL)]))
pass_llvm_command_line(str::String) = pass_llvm_command_line([str])

cxx"""
#include <iostream>
#include "llvm/Support/raw_os_ostream.h"
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

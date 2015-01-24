import Base: dump

dump(d::pcpp"clang::Decl") = ccall((:cdump,libcxxffi),Void,(Ptr{Void},),d)
dump(d::pcpp"clang::FunctionDecl") = ccall((:cdump,libcxxffi),Void,(Ptr{Void},),d)
dump(expr::pcpp"clang::Expr") = ccall((:exprdump,libcxxffi),Void,(Ptr{Void},),expr)
dump(t::pcpp"clang::Type") = ccall((:typedump,libcxxffi),Void,(Ptr{Void},),t)
dump(t::pcpp"llvm::Value") = ccall((:llvmdump,libcxxffi),Void,(Ptr{Void},),t)
dump(t::pcpp"llvm::Type") = ccall((:llvmtdump,libcxxffi),Void,(Ptr{Void},),t)

parser(C) = pcpp"clang::Parser"(
    ccall((:clang_parser,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},),&C))
compiler(C) = pcpp"clang::CompilerInstance"(
    ccall((:clang_compiler,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},),&C))
shadow(C) = pcpp"llvm::Module"(
    ccall((:clang_shadow_module,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},),&C)
    )
parser(C::CxxInstance) = parser(instance(C))
compiler(C::CxxInstance) = compiler(instance(C))
shadow(C::CxxInstance) = shadow(instance(C))

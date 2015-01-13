# Main implementation.
# The two staged functions cppcall and cppcall_member below just change
# the thiscall flag depending on which ones is called.

dump(d::pcpp"clang::Decl") = ccall((:cdump,libcxxffi),Void,(Ptr{Void},),d)
dump(d::pcpp"clang::FunctionDecl") = ccall((:cdump,libcxxffi),Void,(Ptr{Void},),d)
dump(expr::pcpp"clang::Expr") = ccall((:exprdump,libcxxffi),Void,(Ptr{Void},),expr)
dump(t::pcpp"clang::Type") = ccall((:typedump,libcxxffi),Void,(Ptr{Void},),t)
dump(t::pcpp"llvm::Value") = ccall((:llvmdump,libcxxffi),Void,(Ptr{Void},),t)
dump(t::pcpp"llvm::Type") = ccall((:llvmtdump,libcxxffi),Void,(Ptr{Void},),t)


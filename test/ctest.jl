# Tests for specific issues when Cxx.jl is used in C compiler mode
using Cxx
using Cxx.CxxCore

CCompiler = new_clang_instance(false, true)
let __current_compiler__ = CCompiler
    cxx"""
        struct foo {
            int x;
        };
    """
    ptr = CppPtr{CxxQualType{
        CppBaseType{:foo},(false,false,false)},(false,false,false)}(C_NULL)
    @assert ptr == icxx"$ptr;";
    cxx"""
        struct foo *return_foo() {
            return $ptr;
        };
    """
    @assert ptr == icxx"return_foo();"
end

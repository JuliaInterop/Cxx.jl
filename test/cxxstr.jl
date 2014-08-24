using Cxx

cxx"""
uint64_t foo() {
    return $(1);
}
"""

x = @cxx foo()
@assert x == uint64(1)

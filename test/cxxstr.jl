using Cxx

cxx"""
uint64_t foo() {
    return $(1);
}
"""

@assert (@cxx foo()) = uint64(1)

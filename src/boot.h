/*
 * This header file is included by Cxx.jl upon starting up and provides some basic definitions
 * for functionality provided by Cxx, including interaction with julia functions and expressions.
 */
extern "C" {
    // Work around a bug in libstdc++
    extern char *gets (char *str);
}

// For old C libraries that still look at this in C++ mode
#define __STDC_LIMIT_MACROS
#define __STDC_CONSTANT_MACROS

#include <stdint.h>
#include <stddef.h>
#include <cstring>
#include <type_traits>

// More workarounds for old libstdc++
#if defined(__GLIBCXX__) && !defined(__cpp_lib_is_final)
 namespace std {
     /// is_final
     template<typename _Tp>
       struct is_final
       : public integral_constant<bool, __is_final(_Tp)>
       { };
 }
#endif

extern "C" {
    // Usually this is added by the linker, but we just do it ourselves, because we
    // never actually go to the linker.
    void __dso_handle() {}

    extern int __cxxjl_personality_v0();
}
void __hack() {
    (void)&__cxxjl_personality_v0;
}

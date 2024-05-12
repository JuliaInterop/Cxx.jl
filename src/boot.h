/*
 * This header file is included by Cxx.jl upon starting up and provides some basic definitions
 * for functionality provided by Cxx, including interaction with julia functions and expressions.
 */

extern "C" {
    // Usually this is added by the linker, but we just do it ourselves, because we
    // never actually go to the linker.
    void __dso_handle() {}

    int __cxxjl_personality_v0();

#ifdef _WIN32
    void __cxa_atexit() {}
#endif
}
void __hack() {
    (void)&__cxxjl_personality_v0;
}

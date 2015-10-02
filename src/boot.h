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

// Some bootstrap definitions to be able to call julia functions.
// However, these conflict with the real julia.h, so when that's present,
// don't define this. You'll need to delay loading this file until after
// julia.h is loaded.
#ifndef JULIA_H
    typedef struct _jl_value_t {
        struct _jl_value_t *fake;
    } jl_value_t;

    typedef struct {
        union {
            jl_value_t *type;
            uintptr_t type_bits;
            struct {
                uintptr_t gc_bits:2;
            };
        };
        jl_value_t value;
    } jl_taggedvalue_t;

    #define container_of(ptr, type, member) ((type *) ((char *)(ptr) - offsetof(type, member)))
    #define jl_astaggedvalue__MACRO(v) container_of((v),jl_taggedvalue_t,value)
    #define jl_typeof__MACRO(v) ((jl_value_t*)(jl_astaggedvalue__MACRO(v)->type_bits&~(size_t)3))
    #define jl_astaggedvalue jl_astaggedvalue__MACRO
    #define jl_typeof jl_typeof__MACRO
    //#define jl_set_typeof(v,t) (jl_astaggedvalue(v)->type = (jl_value_t*)(t))
    static inline void jl_set_typeof(void *v, void *t)
    {
        jl_taggedvalue_t *tag = jl_astaggedvalue(v);
        tag->type = (jl_value_t*)t;
    }

    typedef jl_value_t *(*jl_fptr_t)(jl_value_t*, jl_value_t**, uint32_t);
    struct _jl_function_t {
        jl_fptr_t fptr;
    };
    typedef struct _jl_function_t jl_function_t;

    static inline
    jl_value_t *jl_apply(jl_function_t *f, jl_value_t **args, uint32_t nargs)
    {
        return f->fptr((jl_value_t*)f, args, nargs);
    }

    static inline jl_value_t *jl_apply0(jl_function_t *f) {
        return jl_apply(f, NULL, 0);
    }

    // Useful parts of the julia API
    extern jl_value_t *jl_box_voidpointer(void *p);
    typedef struct _jl_gcframe_t {
        size_t nroots;
        struct _jl_gcframe_t *prev;
        // actual roots go here
    } jl_gcframe_t;

    // This is not the definition of this in C, but it is the definition that
    // julia exposes to LLVM, so we need to stick to it.
    extern jl_value_t **jl_pgcstack;
#endif

    extern int __cxxjl_personality_v0();
}
void *__hack() {
    return (void*)&__cxxjl_personality_v0;
}

#ifndef JULIA_H
#define JL_GC_PUSHARGS(rts_var,n)                                   \
  rts_var = ((jl_value_t**)__builtin_alloca(((n)+2)*sizeof(jl_value_t*)))+2;  \
  ((void**)rts_var)[-2] = (void*)(((size_t)n)<<1);                  \
  ((void**)rts_var)[-1] = jl_pgcstack;                              \
  memset((void*)rts_var, 0, (n)*sizeof(jl_value_t*));               \
  jl_pgcstack = (jl_value_t **)&(((void**)rts_var)[-2])
#define JL_GC_POP() (jl_pgcstack = (jl_value_t**)((jl_gcframe_t*)jl_pgcstack)->prev)
#endif

template <typename arg> struct lambda_type {
  static jl_value_t *type;
};

template <typename arg> void box_argument(jl_value_t **space, arg &x) {
    *space = jl_box_voidpointer((void*)&x);
    jl_set_typeof(*space,lambda_type<arg>::type);
}
template <typename arg, typename... Arguments> void box_argument(jl_value_t **space, arg &x, Arguments&&... args) {
    box_argument(space, x);
    box_argument(space + 1,args...);
}

extern "C" {
extern void jl_(void *jl_value);
};
template <typename... Arguments> jl_value_t* jl_calln(jl_function_t *f, Arguments&&... args) {
    jl_value_t **jlargs;
    JL_GC_PUSHARGS(jlargs, sizeof...(args));
    box_argument(jlargs, args...);
    jl_value_t *ret = jl_apply(f, jlargs, sizeof...(args));
    JL_GC_POP();
    return ret;
}

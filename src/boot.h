/*
 * This header file is included by Cxx.jl upon starting up and provides some basic definitions
 * for functionality provided by Cxx, including interaction with julia functions and expressions.
 */
#include <stdint.h>
#include <stddef.h>
extern "C" {
    // Usually this is added by the linker, but we just do it ourselves, because we
    // never actually go to the linker.
    void __dso_handle() {}

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
    extern void *memset (void *__s, int __c, size_t __n) __THROW __nonnull ((1));

    extern int __cxxjl_personality_v0();
}
void *__hack() {
    return (void*)&__cxxjl_personality_v0;
}

#define JL_GC_PUSHARGS(rts_var,n)                                   \
  rts_var = ((jl_value_t**)__builtin_alloca(((n)+2)*sizeof(jl_value_t*)))+2;  \
  ((void**)rts_var)[-2] = (void*)(((size_t)n)<<1);                  \
  ((void**)rts_var)[-1] = jl_pgcstack;                              \
  memset((void*)rts_var, 0, (n)*sizeof(jl_value_t*));               \
  jl_pgcstack = (jl_value_t **)&(((void**)rts_var)[-2])
#define JL_GC_POP() (jl_pgcstack = (jl_value_t**)((jl_gcframe_t*)jl_pgcstack)->prev)

template <typename arg> jl_value_t *lambda_type(arg x);
template <typename arg> void box_argument(jl_value_t **space, arg x) {
     *space = jl_box_voidpointer((void*)&x);
     jl_set_typeof(*space,lambda_type(x));
}
template <typename arg, typename... Arguments> void box_argument(jl_value_t **space, arg x, Arguments... args) {
    box_argument(space, x);
    box_argument(&space[1],args...);
}
template <typename... Arguments> jl_value_t* jl_calln(jl_function_t *f, Arguments... args) {
    jl_value_t **jlargs;
    JL_GC_PUSHARGS(jlargs, sizeof...(args));
    box_argument(jlargs, args...);
    jl_value_t *ret = jl_apply(f, jlargs, sizeof...(args));
    JL_GC_POP();
    return ret;
}

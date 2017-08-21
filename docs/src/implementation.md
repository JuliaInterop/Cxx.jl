# How it Works: A High Level Overview

The two primary Julia features that enable Cxx.jl to work are
`llvmcall` and staged functions.

## `llvmcall`

`llvmcall` allows the user to pass in an LLVM IR expression which
will then be embedded directly in the Julia expressions. This
functionality could be considered the "inline assembly" equivalent
for Julia. However, since all optimizations are run after `llvmcall` IR
has been inlined into the Julia IR, all LLVM optimizations such
as constant propagation, dead code elimination, etc. are applied
across both sources of IR, eliminating a common inefficiency of
using inline (machine code) assembly.

The primary `llvmcall` syntax is as follows (reminiscent of the
`ccall` syntax):

```
llvmcall("""%3 = add i32 %1, %0
             ret i32 %3         """, Int32, (Int32, Int32), x, y)

         \________________________/ \_____/ \____________/ \___/
              Input LLVM IR            |     Argument Tuple  |
                                   Return Type            Argument
```

Behind the scenes, LLVM will take the IR and wrap it in an LLVM function
with the given return type and argument types. To call this function,
Julia does the same argument translation it would for a `ccall` (e.g.
unboxing `x` and `y` if necessary). Afterwards, the resulting call instruction
is inlined.

In this package, however, we use the second form of `llvmcall`, which differs
from the first in that the IR argument is not a string, but a `Ptr{Void}`. In
this case, Julia will skip the wrapping and proceed straight to argument
translation and inlining.

The underlying idea is thus simple: have Clang generate some
LLVM IR in memory and then use the second form of LLVM IR to actually call it.

## The `@cxx` macro

The `@cxx` macro (see above for a description of its usage) thus needs to
analyze the expression passed to it and generate an equivalent representation
as a Clang AST, compile it, and splice the resulting function pointer into
`llvmcall`. In principle, this is quite straightforward. We simply need to
match on the appropriate Julia AST and call the appropriate methods in Clang's
Sema instance to generate the expression. And while it can be tricky to figure
out what method to call, the real problem with this approach is types. Since
C++ has compile time function overloading based on types, we need to know
the argument types to call the function with, so we may select the correct to
call. However, since `@cxx` is a macro, it operates on syntax only and,
in particular, does not know the types of the expressions that form the
parameters of the C++ function.

The solution to this is to, as always in computing, add an extra layer of
indirection.

## Staged functions

Staged functions, also known as generated functions, are similar to macros
in that they return expressions rather than values. For example,

```julia
@generated function staged_t1(a, b)
   if a == Int
       return :(a+b)
   else
       return :(a*b)
   end
end
@test staged_t1(1,2) == 3         # a is an Int
@test staged_t1(1.0,0.5) == 0.5   # a is a Float64 (i.e. not an Int)
@test staged_t1(1,0.5) == 1.5     # a is an Int
```

Though the example above could have of course been done using regular
dispatch, it does illustrate the usage of staged functions: Instead of
being passed the values, the staged function is first given the type of
the argument and, after some computation, returns an expression that
represents the actual body of the function to run.

An important feature of staged functions is that, though a staged function
may be called with abstract types, if the staged function throws an error
when passed abstract types, execution of the staged function is delayed until
all argument types are known.

## Implementation of the `@cxx` macro

We can thus see how macros and staged functions fit together. First, `@cxx`
does some syntax transformation to make sure all the required information
is available to the staged function, e.g.

```julia-repl
julia> macroexpand(:(@cxx foo(a, b)))
:(cppcall(CppNNS{(:foo,)}(), a, b))
```

Here `cppcall` is the staged function. Note that the name of the function to
call was wrapped as the type parameter to a `CppNNS` type. This is important,
because otherwise the staged function would not have access to the function
name (since it's a symbol rather than a value). With this, `cppcall` will get
the function name and the types of the two parameters, which is all it needs
to build up the Clang AST. The expression returned by the staged function
will then simply be the `llvmcall` with the appropriate generated LLVM
function, though in some cases we need to return some extra code.

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
from the first in that the IR argument is not a string, but a `Ptr{Cvoid}`. In
this case, Julia will skip the wrapping and proceed straight to argument
translation and inlining.

The underlying idea is thus simple: have Clang generate some
LLVM IR in memory and then use the second form of LLVM IR to actually call it.
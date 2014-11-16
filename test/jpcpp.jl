using Cxx

cxx"""class Bill {
         public:
            int64_t a;
            int64_t b;
       };"""

 type Bill
          a::Int
          b::Int
       end

s = Bill(1, 2)

cxx"""#include <stdio.h>"""

cxx"""void myfn(Bill * m) { printf("%ld, %ld\n", m->a, m->b);}"""

cxxptr = @cxxnew Bill()
@assert isa(cxxptr, CppPtr)
@cxx myfn(cxxptr)

@cxx myfn(jpcpp"Bill"(s))

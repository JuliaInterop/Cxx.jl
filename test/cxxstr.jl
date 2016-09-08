using Cxx
using Base.Test

cxx"""
#include <stdint.h>
"""

cxx"""
uint64_t foo2() {
    return $(1);
}
"""

x = @cxx foo2()
@test x === UInt64(1)

julia_global = 1

cxx"""
uint64_t bar() {
    return (uint64_t)$:(julia_global::Int64);
}
"""

bar() = @cxx bar()
@test bar() === UInt64(1)

julia_global = 2
@test bar() == UInt64(2)

julia_global = 1.0
@test_throws TypeError bar()

julia_global = 1
cxx"""
class PrintTest {
public:
    PrintTest() {
        abc = $:(julia_global::Int64);
    };
    int64_t abc;
};
"""

test = @cxxnew PrintTest()
@test (@cxx test->abc) == 1

julia_global = 2

test = @cxxnew PrintTest()
@test (@cxx test->abc) == 2

cxx"""
void printfoo() {
    for (int i = 0; i <= 10; ++i)
        $:(println("foo")::Void);
}
"""

# Issue #13
cxx"""
namespace foo13{
 class bar{
  public:
  enum baz{
   A,B,C
  };
 };
}
"""
@test (@cxx foo13::bar::A).val == 0

# Issue # 14
cxx"""
 class bar14 {
   public:
   double xxx() {
      return 5.0;
   };
 };
"""

b = @cxxnew bar14()

@test (@cxx b->xxx()) === Cdouble(5.0)

cxx"""
double f_double(double x) {
    return x+2.0;
}
"""

@test (@cxx f_double(3.0)) === Cdouble(5.0)

cxx"""
typedef struct _foobar {
   int a;
} foobar;

void modify_a(foobar &fb) {
   fb.a = fb.a+1;
}
"""

fb = icxx"_foobar{1};"
icxx"(void)++$fb.a;"
@test reinterpret(Int32, [fb.data...])[1] == 2

# Splicing at global scope
cxx"""const char *foostr = $(pointer("foo"));"""

#cxxt
@test cxxt"int" == Int32
cxx"""
template <typename T>
struct foo_cxxt {
  T x;
};
"""
@test cxxt"foo_cxxt<int>" <: Cxx.CppValue{Cxx.CxxQualType{Cxx.CppTemplate{Cxx.CppBaseType{:foo_cxxt},Tuple{Int32}},(false,false,false)}}


# #103

test103 = Int32[]
cxx"""
void foo103() {
int x = 5;
$:(push!(test103::Vector{Int32},icxx"return x;"); nothing);
}
"""
@cxx foo103()
@test test103 == [5]
@cxx foo103()
@test test103 == [5,5]

# The same thing with two arguments
test2_103 = Array(Tuple{Int32,Int32},0)
cxx"""
void foo2_103() {
int x = 5;
int y = 6;
$:(push!(test2_103,(icxx"return x;",icxx"return y;")); nothing);
}
"""
@cxx foo2_103()
@test test2_103 == [(5,6)]

# And with arguments being interpolated again form the julia level (aka L4 nesting)
global foo3_103_ok = false
cxx"""
bool foo3_103() {
$:(begin
  x = 5
  y = 6
  @assert !icxx"return $x == $y;"
  global foo3_103_ok = true
  nothing
end);
return true;
}
"""
@assert @cxx foo3_103();
@assert foo3_103_ok

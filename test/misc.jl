using Cxx
using Base.Test

# Issue 37 - Assertion failure when calling function declared `extern "C"`
cxx"""
extern "C" {
    void foo37() {
    }
}
"""
@cxx foo37()

# Constness in template arguments - issue #33
cxx"""
#include <map>
#include <string>

typedef std::map<std::string, std::string> Map;

Map getMap()
{
    return Map({ {"hello", "world"}, {"everything", "awesome"} });
}
int dumpMap(Map m)
{
    return 1;
}
"""
m = @cxx getMap()
@test (@cxx dumpMap(m)) == 1

# Reference return (#50)
cxx"""
int x50 = 6;
int &bar50(int *foo) {
    return *foo;
}
"""
@cxx bar50(@cxx &x50)

# Global Initializers (#53)
cxx"""
#include <vector>

std::vector<int> v(10);
"""
@test icxx"v.size();" == 10

# References to functions (#51)
cxx"""
void foo51() {}
"""

@test_throws ErrorException (@cxx foo51)
@test isa((@cxx &foo51),Cxx.CppFptr)

# References to member functions (#55)
cxx"""
class foo55 {
    foo55() {};
public:
    void bar() {};
};
"""
@test isa((@cxx &foo55::bar),Cxx.CppMFptr)

cxx"""
class bar55 {
    bar55() {};
public:
    double bar(int) { return 0.0; };
};
"""
@test isa((@cxx &bar55::bar),Cxx.CppMFptr)

# booleans as template arguments
cxx"""
template < bool T > class baz {
    baz() {};
public:
    void bar() {};
};
"""

@test isa((@cxx &baz{false}::bar),Cxx.CppMFptr)

# Includes relative to the source directory (#48)
macro test48_str(x,args...)
    return length(args) > 0
end
if test48" "
    cxx"""
    #include "./incpathtest.inc"
    """
    @test (@cxx incpathtest) == 1

    function foo48()
    icxx"""
    #include "./incpathtest.inc"
    return incpathtest;
    """
    end
    @test foo48() == 1
end

# Enum type translation
cxx"""
enum EnumTest {
    EnumA, EnumB, EnumC
};
bool enumfoo(EnumTest foo) {
    return foo == EnumB;
}
"""
@assert (@cxx enumfoo(@cxx EnumB))

# Members with non-trivial copy constructor
cxx"""
#include <vector>
class memreffoo {
public:
    memreffoo(int val) : bar(0) {
        bar.push_back(val);
    };
    std::vector<int> bar;
};
"""
memreffoo = @cxxnew memreffoo(5)
memrefbar = @cxx memreffoo->bar
@assert isa(memrefbar,Cxx.CppValue)
@assert (@cxx memrefbar->size()) == 1

# Anonymous structs are referenced by typedef if possible.
cxx"""
typedef struct {
    int foo;
} anonttest;
anonttest *anonttestf()
{
    return new anonttest{ .foo = 0};
}
"""

@assert typeof(@cxx anonttestf()) == pcpp"anonttest"

# Operator overloading (#102)
cxx"""
typedef struct {
    int x;
} foo102;

foo102 operator+ (const foo102& x, const foo102& y) {
    return { .x = x.x + y.x };
}
"""

x = icxx"foo102{ .x = 1 };"
y = icxx"foo102{ .x = 2 };"
z = @cxx x + y

@assert icxx" $z.x == 3; "

z = x + y
@assert icxx" $z.x == 3; "

# Anonymous enums (#118)
cxx""" enum { kFalse118 = 0, kTrue118 = 1 }; """
@assert icxx" kTrue118; " == 1

# UInt8 builtin (#119)
cxx""" void foo119(char value) {} """
@cxx foo119(UInt8(0))

# UInt16 builtin (#119)
cxx""" void foo119b(unsigned short value) {} """
@cxx foo119b(UInt16(0))

# Enums should be comparable with integers
cxx""" enum myCoolEnum { OneValue = 1 }; """
@assert icxx" OneValue; " == 1

# Exception handling
try
    icxx" throw 20; "
    @assert false
catch e
    buf = IOBuffer();
    showerror(buf,e)
    @assert takebuf_string(buf) == "20"
end

cxx"""
class test_exception : public std::exception
{
public:
    int x;
    test_exception(int x) : x(x) {};
};
"""

import Base: showerror
@exception function showerror(io::IO, e::rcpp"test_exception")
    print(io, icxx"$e.x;")
end

try
    icxx" throw test_exception(5); "
    @assert false
catch e
    buf = IOBuffer();
    showerror(buf,e)
    @assert takebuf_string(buf) == "5"
end


# Memory management
cxx"""
static int testDestructCounter = 0;
struct testDestruct {
    int x;
    testDestruct(int x) : x(x) {};
    ~testDestruct() { testDestructCounter += x; };
};
"""
X = icxx"return testDestruct{10};"
finalize(X)
@test icxx"testDestructCounter == 10;"

# Template dispatch
foo{T}(x::cxxt"std::vector<$T>") = icxx"$x.size();"
@test foo(icxx"std::vector<uint64_t>{0};") == 1
@test foo(icxx"std::vector<uint64_t>{};") == 0


# #141
@assert icxx"""
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winvalid-offsetof"
bool ok =(size_t)(&((clang::LangOptions*)0)->CurrentModule) == offsetof(clang::LangOptions,CurrentModule);
#pragma clang diagnostic pop
return ok;
"""

# #163
cxx"""
struct bar163 {
    int x;
};
"""
Base.convert(::Type{cxxt"bar163"},x::Int) = icxx"bar163{.x = 1};"
foo163() = convert(cxxt"bar163",1)
foo163(); foo163();

makeVector(T) = cxxt"std::vector<$T>"

@assert makeVector(UInt64) === cxxt"std::vector<uint64_t>"

# #169
cxx""" void inp169(int &x){ x += 1; };  """
x169 = Ref{Cint}(666)
icxx"inp169($x169);"
@assert x169[] == 667

# Implement C++ Functions in julia

@cxxm "int foofunc(int x)" begin
    x+1
end
@test icxx"foofunc(5);" == 6

cxx"""
struct foostruct {
    int x;
    int y;
    int Add1();
    struct foostruct Add(struct foostruct other);
    void *ReturnAPtr();
};
"""
@cxxm "int foostruct::Add1()" begin
    icxx"return $this->x;"+1
end

@test icxx"foostruct{1,0}.Add1();" == 2


@cxxm "struct foostruct foostruct::Add(struct foostruct other)" begin
    icxx"return foostruct{$this->x+$other.x,$this->y+$other.y};"
end

@test icxx"foostruct{1,2}.Add(foostruct{2,3}).Add1();" == 4

@cxxm "void *foostruct::ReturnAPtr()" begin
    reinterpret(Ptr{Void},0xdeadbeef%UInt)
end

@test icxx"foostruct{1,2}.ReturnAPtr();" == reinterpret(Ptr{Void},0xdeadbeef%UInt)


# Issue #95
@test icxx"""
    std::string{$("foo bar")} == "foo bar";
"""

# Negative and very large integer template parameters
cxx"""template <uint64_t T>
class testLargeValue
{
    public:
        testLargeValue(){}
        uint64_t getT();
};"""

cxx"""template <uint64_t T>
uint64_t testLargeValue<T>::getT()
{
    return T;
};"""

cxx"""template <int T>
class testNegativeValue
{
    public:
        testNegativeValue(){}
        int getT();
};"""

cxx"""template <int T>
int testNegativeValue<T>::getT()
{
    return T;
};"""

tmp = icxx"testLargeValue<0xffffffffffffffff>();"
@test icxx"$(tmp).getT();" == 0xffffffffffffffff

tmp = icxx"testNegativeValue<-1>();"
@test icxx"$(tmp).getT();" == -1

# Broken Testcase while porting to jb/functions
# The problematic case was both a Julia and a C++ side capture

function fooTheLambda()
    ret = Expr(:block)
    f = (arg1,)->begin
            @assert Cxx.lambdacall(Cxx.__default_compiler__,arg1) == 1
            @assert pointer_from_objref(ret) != C_NULL
            @assert ret.head == :block
        end
    icxx"""
        int x = 1;
        auto &f = $f;
        f([&](){ return x; });
        return;
    """
end
fooTheLambda()

# 217
T217 = Cdouble; arg217 = 1;
icxx"std::vector<$T217>($arg217);";

cxx"enum  X197:char {A197,B197};"
@assert icxx"A197;" == 0

# #232

cxx"""
struct PointXYZ232 {
   PointXYZ232(int x, int y, int z) : x_(x), y_(y), z_(z) {}
int x_,y_,z_;
};
""";
v232 = icxx"std::vector<PointXYZ232>();";
icxx"""$v232.push_back(PointXYZ232(0,0,0));""";
@assert typeof(icxx"$v232[0];") <: Cxx.CppRef

# #243
counter243 = 0
let body243 = i->(@assert 1 == unsafe_load(i); global counter243; counter243 += 1; nothing)
    icxx"int x = 1; $body243(x);"
    icxx"int x = 1; $body243(&x);"
end
@assert counter243 == 2
cxx"""
struct foo243 {
    int x;
};
"""
let body243b = i->(@assert 1 == icxx"$i->x;"; global counter243; counter243 += 1; nothing)
    icxx"foo243 x{1}; $body243b(&x);"
end
@assert counter243 == 3

# #246
cxx"""
template <int i> class Template246 {
public:
    int getI() { return i; }
};
"""
@assert icxx"Template246<$(Val{5})>().getI();" == 5
@assert icxx"Template246<$(Val{5}())>().getI();" == 5

# #256
typealias SVP{T} cxxt"std::vector<$T>*"
# This is a bug!
# @assert SVP{cxxt"std::string"} == cxxt"std::vector<std::string>*"

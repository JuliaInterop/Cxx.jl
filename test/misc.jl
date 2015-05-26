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

# Constnes in template arguments - issue #33
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


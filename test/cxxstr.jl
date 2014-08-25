using Cxx
using Base.Test

cxx"""
uint64_t foo() {
    return $(1);
}
"""

x = @cxx foo()
@test x == uint64(1)

julia_global = 1

cxx"""
uint64_t bar() {
    return (uint64_t)$:(julia_global::Int64);
}
"""

bar() = @cxx bar()
@test bar() == uint64(1)

julia_global = 2
@test bar() == uint64(2)

julia_global = 1.0
@test_throws TypeError bar()

julia_global = 1
cxx"""
class PrintTest {
public:
    PrintTest() {
        abc = $:(julia_global::Int64);
    }
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
        $:(println("foo")::Nothing);
}
"""

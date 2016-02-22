using Cxx

cxx"""
#include <memory>
#include <vector>
class X184 {
    public:
    std::unique_ptr<int> val;
};

enum X195 {x195, y195};
class Test195 {
    public:
    X195 x;
};
"""

sprint(show, icxx"std::unique_ptr<int>{nullptr};")
sprint(show, icxx"X184{};")
sprint(show, icxx"new X184{};")
sprint(show, icxx"Test195{};")

# 178
x=icxx"std::vector<int>();"
icxx"$x.push_back(0);"
sprint(show, icxx"$x[0];")

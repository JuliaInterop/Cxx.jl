using Cxx
cxx"""
#include <iostream>
"""
function foo()
    for i = 1:10
        icxx"""
            std::cout << "foo\n";
        """
    end
end
foo()

function bar()
    for i = 1:10
        icxx"""
           std::cout << $i << "\n";
        """
   end
end
bar()

function baz()
    for i = 1:10
        x = icxx" $i + 1;"
        @assert x == i + 1
    end
end
baz()

function foobar()
    for i = 1:10
        x = icxx"""
            if ($i > 5)
                return 2;
            else
                return 1;
        """
        @assert x == (i > 5 ? 2 : 1)
    end
end
foobar()

function inlineexpr()
    a = Int64[0]
    b = Int64[0]
    icxx"""
        for (int i = 0; i < 10; ++i) {
            if (i < 5)
                $:(a[1] += 1);
            else
                $:(b[1] += 1);
        }
    """
    @assert a[1] == 5
    @assert b[1] == 5
end
inlineexpr()

# #103 for icxx
function inlineicxx()
    icxx"""
       std::vector<uint64_t> ints;
       for (int i = 0; i < 10; ++i)
           $:(
               r = 10*icxx"return i;" + rand(1:10);
               icxx"ints.push_back($r);";
               nothing
           );
       ints;
    """
end
ints = inlineicxx()
Base.length(x::cxxt"std::vector<uint64_t>") = icxx"$ints.size();"
Base.getindex(x::cxxt"std::vector<uint64_t>",i) = icxx"auto x = $ints.at($i); return x;"
@assert length(ints) == 10
Cxx.@list cxxt"std::vector<uint64_t>"
for (i, x) in enumerate(ints)
    @assert 10*(i-1) < x <= 10*i
end

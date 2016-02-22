using Cxx
cxx"""
#include <iostream>
"""
function ifoo()
    for i = 1:10
        icxx"""
            std::cout << "foo\n";
        """
    end
end
ifoo()

function ibar()
    for i = 1:10
        icxx"""
           std::cout << $i << "\n";
        """
   end
end
ibar()

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
                $:(a[1] += 1; nothing);
            else
                $:(b[1] += 1; nothing);
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
    @assert 10*(i-1) < convert(UInt64,x) <= 10*i
end

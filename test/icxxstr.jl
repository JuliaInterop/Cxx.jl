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

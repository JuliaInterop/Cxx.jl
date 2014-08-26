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

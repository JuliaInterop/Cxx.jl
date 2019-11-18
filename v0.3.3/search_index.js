var documenterSearchIndex = {"docs": [

{
    "location": "#",
    "page": "Home",
    "title": "Home",
    "category": "page",
    "text": ""
},

{
    "location": "#Cxx.jl-The-Julia-C-FFI-1",
    "page": "Home",
    "title": "Cxx.jl - The Julia C++ FFI",
    "category": "section",
    "text": "Cxx.jl is a Julia package that provides a C++ interoperability interface for Julia. It also provides an experimental C++ REPL mode for the Julia REPL."
},

{
    "location": "#Functionality-1",
    "page": "Home",
    "title": "Functionality",
    "category": "section",
    "text": "There are two ways to access the main functionality provided by this package. The first is using the @cxx macro, which puns on Julia syntax to provide C++ compatibility. Additionally, this package provides the cxx\"\" and icxx\"\" custom string literals for inputting C++ syntax directly. The two string literals are distinguished by the C++ level scope they represent. See the API documentation for more details."
},

{
    "location": "#Installation-1",
    "page": "Home",
    "title": "Installation",
    "category": "section",
    "text": "Now, this package provides an out-of-box installation experience on all 64-bit \"Tier 1\" platforms for Julia 1.1.pkg> add CxxBuilding the C++ code requires the same system tools necessary for building Julia from source. Further, Debian/Ubuntu users should install libedit-dev and libncurses5-dev, and RedHat/CentOS users should install libedit-devel."
},

{
    "location": "#Contents-1",
    "page": "Home",
    "title": "Contents",
    "category": "section",
    "text": "Pages = [\n    \"api.md\",\n    \"examples.md\",\n    \"implementation.md\",\n    \"repl.md\",\n]\nDepth = 1"
},

{
    "location": "api/#",
    "page": "API",
    "title": "API",
    "category": "page",
    "text": ""
},

{
    "location": "api/#Cxx.CxxCore.@cxx",
    "page": "API",
    "title": "Cxx.CxxCore.@cxx",
    "category": "macro",
    "text": "@cxx expr\n\nEvaluate the given expression as C++ code, punning on Julia syntax to avoid needing to wrap the C++ code in a string, as in cxx\"\". The three basic features provided by @cxx are:\n\nStatic function calls: @cxx mynamespace::func(args...)\nMember calls: @cxx m->foo(args...), where m is a CppPtr, CppRef, or CppValue\nValue references: @cxx foo\n\nUnary * inside a call, e.g. @cxx foo(*(a)), is treated as a dereference of a on the C++ side. Further, prefixing any value by & takes the address of the given value.\n\nnote: Note\nIn @cxx foo(*(a)), the parentheses around a are necessary since Julia syntax does not allow * in the unary operator position otherwise.\n\n\n\n\n\n"
},

{
    "location": "api/#Cxx.CxxCore.@cxx_str",
    "page": "API",
    "title": "Cxx.CxxCore.@cxx_str",
    "category": "macro",
    "text": "cxx\"C++ code\"\n\nEvaluate the given C++ code in the global scope. This can be used for declaring namespaces, classes, functions, global variables, etc. Unlike @cxx, cxx\"\" does not require punning on Julia syntax, which means, e.g., that unary * for pointers does not require parentheses.\n\n\n\n\n\n"
},

{
    "location": "api/#Cxx.CxxCore.@icxx_str",
    "page": "API",
    "title": "Cxx.CxxCore.@icxx_str",
    "category": "macro",
    "text": "icxx\"C++ code\"\n\nEvaluate the given C++ code at the function scope. This should be used for calling C++ functions and performing computations.\n\n\n\n\n\n"
},

{
    "location": "api/#Cxx.CxxCore.cxxinclude",
    "page": "API",
    "title": "Cxx.CxxCore.cxxinclude",
    "category": "function",
    "text": "cxxinclude([C::CxxInstance,] fname; isAngled=false)\n\nInclude the C++ file specified by fname. This should be used when the path of the included file needs to be assembled programmatically as a Julia string. In all other situations, it is avisable to just use cxx\"#include ...\", which makes the intent clear and has the same directory resolution logic as C++.\n\n\n\n\n\n"
},

{
    "location": "api/#Cxx.CxxCore.addHeaderDir",
    "page": "API",
    "title": "Cxx.CxxCore.addHeaderDir",
    "category": "function",
    "text": "addHeaderDir([C::CxxInstance,] dirname; kind=C_User, isFramework=false)\n\nAdd a directory to the Clang #include path. The keyword argument kind specifies the kind of directory, and can be one of\n\nC_User (like passing -I when compiling)\nC_System (like -isystem)\nC_ExternCSystem (like -isystem, but wrap in extern \"C\")\n\nThe isFramework argument is the equivalent of passing the -F option to Clang.\n\n\n\n\n\n"
},

{
    "location": "api/#Cxx.CxxCore.defineMacro",
    "page": "API",
    "title": "Cxx.CxxCore.defineMacro",
    "category": "function",
    "text": "defineMacro([C::CxxInstance,] name)\n\nDefine a C++ macro. Equivalent to cxx\"#define $name\".\n\n\n\n\n\n"
},

{
    "location": "api/#Cxx.CxxCore.__current_compiler__",
    "page": "API",
    "title": "Cxx.CxxCore.__current_compiler__",
    "category": "constant",
    "text": "__current_compiler__\n\nAn instance of the Clang compiler current in use.\n\n\n\n\n\n"
},

{
    "location": "api/#API-1",
    "page": "API",
    "title": "API",
    "category": "section",
    "text": "Cxx.@cxx\nCxx.@cxx_str\nCxx.@icxx_str\nCxx.cxxinclude\nCxx.addHeaderDir\nCxx.defineMacro\nCxx.__current_compiler__"
},

{
    "location": "examples/#",
    "page": "Examples",
    "title": "Examples",
    "category": "page",
    "text": ""
},

{
    "location": "examples/#Examples-1",
    "page": "Examples",
    "title": "Examples",
    "category": "section",
    "text": ""
},

{
    "location": "examples/#Embedding-a-simple-C-function-in-Julia-1",
    "page": "Examples",
    "title": "Embedding a simple C++ function in Julia",
    "category": "section",
    "text": "julia> cxx\"#include <iostream>\"\ntrue\n\njulia> cxx\"\"\"\n           void mycppfunction() {\n               int z = 0;\n               int y = 5;\n               int x = 10;\n               z = x * y + 2;\n               std::cout << \"The number is \" << z << std::endl;\n           }\n       \"\"\"\ntrue\n\njulia> julia_function() = @cxx mycppfunction()\njulia_function (generic function with 1 method)\n\njulia> julia_function()\nThe number is 52"
},

{
    "location": "examples/#Passing-numeric-arguments-from-Julia-to-C-1",
    "page": "Examples",
    "title": "Passing numeric arguments from Julia to C++",
    "category": "section",
    "text": "julia> jnum = 10\n10\n\njulia> cxx\"\"\"\n           void printme(int x) {\n               std::cout << x << std::endl;\n           }\n       \"\"\"\ntrue\n\njulia> @cxx printme(jnum)\n10"
},

{
    "location": "examples/#Passing-strings-from-Julia-to-C-1",
    "page": "Examples",
    "title": "Passing strings from Julia to C++",
    "category": "section",
    "text": "julia> cxx\"\"\"\n           void printme(const char *name) {\n               // const char* => std::string\n               std::string sname = name;\n               // print it out\n               std::cout << sname << std::endl;\n           }\n       \"\"\"\ntrue\n\njulia> @cxx printme(pointer(\"John\"))\nJohn"
},

{
    "location": "examples/#Passing-a-Julia-expression-to-C-1",
    "page": "Examples",
    "title": "Passing a Julia expression to C++",
    "category": "section",
    "text": "julia> cxx\"\"\"\n           void test_print() {\n               $:(println(\"\\nTo end this test, press any key\")::Cvoid);\n           }\n       \"\"\"\ntrue\n\njulia> @cxx test_print()\n\nTo end this test, press any key"
},

{
    "location": "examples/#Embedding-C-code-inside-a-Julia-function-1",
    "page": "Examples",
    "title": "Embedding C++ code inside a Julia function",
    "category": "section",
    "text": "julia> function playing()\n           for i = 1:5\n               icxx\"\"\"\n                   int tellme;\n                   std::cout << \"Please enter a number: \" << std::endl;\n                   std::cin >> tellme;\n                   std::cout << \"\\nYour number is \" << tellme << \"\\n\" << std::endl;\n               \"\"\"\n           end\n       end\nplaying (generic function with 1 method)\n\njulia> playing()\nPlease enter a number:\n45\n\nYour number is 45"
},

{
    "location": "examples/#Using-C-enums-1",
    "page": "Examples",
    "title": "Using C++ enums",
    "category": "section",
    "text": "julia> cxx\"\"\"\n           class Klassy {\n               public:\n                   enum Foo { Bar, Baz };\n                   static Foo exec(Foo x) { return x; }\n           };\n       \"\"\"\ntrue\n\njulia> @cxx Klassy::Bar\nCxx.CppEnum{Symbol(\"Klassy::Foo\"),UInt32}(0x00000000)\n\njulia> @cxx Klassy::exec(@cxx Klassy::Baz)\nCxx.CppEnum{Symbol(\"Klassy::Foo\"),UInt32}(0x00000001)"
},

{
    "location": "examples/#C-classes-1",
    "page": "Examples",
    "title": "C++ classes",
    "category": "section",
    "text": "julia> cxx\"\"\"\n           #include <iostream>\n           class Hello {\n               public:\n                   void hello_world(const char *now) {\n                       std::string snow = now;\n                       std::cout << \"Hello, World! Now is \" << snow << std::endl;\n                   }\n           };\n       \"\"\"\ntrue\n\njulia> hello_class = @cxxnew Hello()\n(class Hello *) @0x00007f82dd7d19a0\n\n\njulia> tstamp = string(Dates.now())\n\"2017-08-21T13:53:27.85\"\n\njulia> @cxx hello_class->hello_world(pointer(tstamp))\nHello, World! Now is 2017-08-21T13:53:27.85"
},

{
    "location": "examples/#Using-C-with-shared-libraries-1",
    "page": "Examples",
    "title": "Using C++ with shared libraries",
    "category": "section",
    "text": "ArrayMaker.h#ifndef ARRAYMAKER_H\n#define ARRAYMAKER_H\n\nclass ArrayMaker {\n    private:\n        int inumber;\n        float fnumber;\n        float* farr;\n    public:\n        ArrayMaker(int, float);\n        float* fillarr();\n};\n\n#endifArrayMaker.cpp#include \"ArrayMaker.h\"\n#include <iostream>\n\nusing namespace std;\n\nArrayMaker::ArrayMaker(int inum, float fnum) {\n    cout << \"Got arguments: \" << inum << \" and \" << fnum << endl;\n    inumber = inum;\n    fnumber = fnum;\n    farr = new float[inumber];\n}\n\nfloat* ArrayMaker::fillarr() {\n    cout << \"Filling the array\" << endl;\n    for (int i = 0; i < inumber; i++) {\n        farr[i] = fnumber;\n        fnumber *= 2;\n    }\n    return farr;\n}Compile into a shared libraryg++ -shared -fPIC ArrayMaker.cpp -o libarraymaker.soUsing from Juliajulia> const path_to_lib = pwd();\n\njulia> addHeaderDir(path_to_lib, kind=C_System)\n\njulia> Libdl.dlopen(joinpath(path_to_lib, \"libarraymaker.so\"), Libdl.RTLD_GLOBAL)\nPtr{Nothing} @0x00007f9dd4556d60\n\njulia> cxxinclude(\"ArrayMaker.h\")\n\njulia> maker = @cxxnew ArrayMaker(5, 2.0)\nGot arguments: 5 and 2\n(class ArrayMaker *) @0x00007f9dd7e25f10\n\n\njulia> arr = @cxx maker->fillarr()\nFilling the array\nPtr{Float32} @0x00007f9dd7e21370\n\njulia> unsafe_wrap(Array, arr, 5)\n5-element Array{Float32,1}:\n  2.0\n  4.0\n  8.0\n 16.0\n 32.0"
},

{
    "location": "implementation/#",
    "page": "Implementation",
    "title": "Implementation",
    "category": "page",
    "text": ""
},

{
    "location": "implementation/#How-it-Works:-A-High-Level-Overview-1",
    "page": "Implementation",
    "title": "How it Works: A High Level Overview",
    "category": "section",
    "text": "The two primary Julia features that enable Cxx.jl to work are llvmcall and staged functions."
},

{
    "location": "implementation/#llvmcall-1",
    "page": "Implementation",
    "title": "llvmcall",
    "category": "section",
    "text": "llvmcall allows the user to pass in an LLVM IR expression which will then be embedded directly in the Julia expressions. This functionality could be considered the \"inline assembly\" equivalent for Julia. However, since all optimizations are run after llvmcall IR has been inlined into the Julia IR, all LLVM optimizations such as constant propagation, dead code elimination, etc. are applied across both sources of IR, eliminating a common inefficiency of using inline (machine code) assembly.The primary llvmcall syntax is as follows (reminiscent of the ccall syntax):llvmcall(\"\"\"%3 = add i32 %1, %0\n             ret i32 %3         \"\"\", Int32, (Int32, Int32), x, y)\n\n         \\________________________/ \\_____/ \\____________/ \\___/\n              Input LLVM IR            |     Argument Tuple  |\n                                   Return Type            ArgumentBehind the scenes, LLVM will take the IR and wrap it in an LLVM function with the given return type and argument types. To call this function, Julia does the same argument translation it would for a ccall (e.g. unboxing x and y if necessary). Afterwards, the resulting call instruction is inlined.In this package, however, we use the second form of llvmcall, which differs from the first in that the IR argument is not a string, but a Ptr{Cvoid}. In this case, Julia will skip the wrapping and proceed straight to argument translation and inlining.The underlying idea is thus simple: have Clang generate some LLVM IR in memory and then use the second form of LLVM IR to actually call it."
},

{
    "location": "implementation/#The-@cxx-macro-1",
    "page": "Implementation",
    "title": "The @cxx macro",
    "category": "section",
    "text": "The @cxx macro (see above for a description of its usage) thus needs to analyze the expression passed to it and generate an equivalent representation as a Clang AST, compile it, and splice the resulting function pointer into llvmcall. In principle, this is quite straightforward. We simply need to match on the appropriate Julia AST and call the appropriate methods in Clang\'s Sema instance to generate the expression. And while it can be tricky to figure out what method to call, the real problem with this approach is types. Since C++ has compile time function overloading based on types, we need to know the argument types to call the function with, so we may select the correct to call. However, since @cxx is a macro, it operates on syntax only and, in particular, does not know the types of the expressions that form the parameters of the C++ function.The solution to this is to, as always in computing, add an extra layer of indirection."
},

{
    "location": "implementation/#Staged-functions-1",
    "page": "Implementation",
    "title": "Staged functions",
    "category": "section",
    "text": "Staged functions, also known as generated functions, are similar to macros in that they return expressions rather than values. For example,@generated function staged_t1(a, b)\n   if a == Int\n       return :(a+b)\n   else\n       return :(a*b)\n   end\nend\n@test staged_t1(1,2) == 3         # a is an Int\n@test staged_t1(1.0,0.5) == 0.5   # a is a Float64 (i.e. not an Int)\n@test staged_t1(1,0.5) == 1.5     # a is an IntThough the example above could have of course been done using regular dispatch, it does illustrate the usage of staged functions: Instead of being passed the values, the staged function is first given the type of the argument and, after some computation, returns an expression that represents the actual body of the function to run.An important feature of staged functions is that, though a staged function may be called with abstract types, if the staged function throws an error when passed abstract types, execution of the staged function is delayed until all argument types are known."
},

{
    "location": "implementation/#Implementation-of-the-@cxx-macro-1",
    "page": "Implementation",
    "title": "Implementation of the @cxx macro",
    "category": "section",
    "text": "We can thus see how macros and staged functions fit together. First, @cxx does some syntax transformation to make sure all the required information is available to the staged function, e.g.julia> macroexpand(:(@cxx foo(a, b)))\n:(cppcall(CppNNS{(:foo,)}(), a, b))Here cppcall is the staged function. Note that the name of the function to call was wrapped as the type parameter to a CppNNS type. This is important, because otherwise the staged function would not have access to the function name (since it\'s a symbol rather than a value). With this, cppcall will get the function name and the types of the two parameters, which is all it needs to build up the Clang AST. The expression returned by the staged function will then simply be the llvmcall with the appropriate generated LLVM function, though in some cases we need to return some extra code."
},

{
    "location": "repl/#",
    "page": "C++ REPL",
    "title": "C++ REPL",
    "category": "page",
    "text": ""
},

{
    "location": "repl/#C-REPL-1",
    "page": "C++ REPL",
    "title": "C++ REPL",
    "category": "section",
    "text": "Cxx.jl provides an experimental C++ REPL, accessible from Julia\'s REPL. To enter C++ mode, press <, and to exit back to Julia mode, press backspace at the beginning of the line.Below is a screenshot of the REPL in action.(Image: REPL Screenshot)"
},

]}

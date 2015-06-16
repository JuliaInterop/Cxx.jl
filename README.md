##Cxx.jl

The Julia C++ Foreign Function Interface (FFI).


### Installation

You will need to install Julia v0.4-dev with some special options.

Cxx.jl requires "staged functions" amongst other things available only in v0.4. It also requires the development version of LLVM, which is currently targeting version 3.7.

#### Build requirements

In addition to the [system requirements](https://github.com/JuliaLang/julia#required-build-tools-and-external-libraries) to build julia itself, the following are required:

- *Debian/Ubuntu*: `libedit-dev`, `libncurses5-dev`
- *RedHat/CentOS*: `libedit-devel`

#### Building julia

Get the latest git checkout from https://github.com/JuliaLang/julia.git then add (or add to) a ```Make.user``` file at the top level with the following lines:
```sh
override LLDB_VER=master
override LLVM_VER=svn
override LLVM_ASSERTIONS=1
override BUILD_LLVM_CLANG=1
override BUILD_LLDB=1
override USE_LLVM_SHLIB=1
override LLDB_DISABLE_PYTHON=1
```

Then build simply with `make`. 

Test your build of julia with `make testall`.

Optionally, also build the debug build of julia with `make debug`. If available, this will be used in the next step.

#### Building Cxx

Launch the julia you just built, and in the terminal type
```julia
Pkg.clone("https://github.com/Keno/Cxx.jl.git")
Pkg.build("Cxx")   
```

### How it works

The main interface provided by Cxx.jl is the @cxx macro. It supports two main usages:

  - Static function call
      @cxx mynamespace::func(args...)
  - Membercall (where m is a CppPtr, CppRef or CppValue)
      @cxx m->foo(args...)
      
To embedd C++ functions in Julia, there are two main approaches:

```julia 
# Using @cxx (e.g.):   
cxx""" void cppfunction(args){ . . .} """ => @cxx cppfunction(args)

# Using icxx (e.g.):
julia_function (args) icxx""" *code here*  """ end
```    

### The C++ REPL

This package contains an experimental C++ REPL feature. Using the package
will automatically add a new pane to your REPL that is accessible by pressing the
`<` key.

### **Using Cxx.jl:** 

#### Example 1: Embedding a simple C++ function in Julia

```julia
# include headers
julia> using Cxx
julia> cxx""" #include<iostream> """  

# Declare the function
julia> cxx"""  
         void mycppfunction() {   
            int z = 0;
            int y = 5;
            int x = 10;
            z = x*y + 2;
            std::cout << "The number is " << z << std::endl;
         }
      """
# Convert C++ to Julia function
julia> julia_function() = @cxx mycppfunction()
julia_function (generic function with 1 method)
   
# Run the function
julia> julia_function()
The number is 52
```

#### Example 2: Pass numeric arguments from Julia to C++

```julia
julia> jnum = 10
10
    
julia> cxx"""
           void printme(int x) {
              std::cout << x << std::endl;
           }
       """
       
julia> @cxx printme(jnum)
10 
```

#### Example 3: Pass strings from Julia to C++
 ```julia
julia> cxx"""
          void printme(const char *name) {
             // const char* => std::string
             std::string sname = name;
             // print it out
             std::cout << sname << std::endl;
          }
      """

julia> @cxx printme(pointer("John"))
    John 
```

#### Example 4: Pass a Julia expression to C++

```julia
julia> cxx"""
          void testJuliaPrint() {
              $:(println("\nTo end this test, press any key")::Nothing);
          }
       """

julia> @cxx testJuliaPrint()
       To end this test, press any key
```

#### Example 5: Embedding C++ code inside a Julia function

```julia
function playing()
    for i = 1:5
        icxx"""
            int tellme;
            std::cout<< "Please enter a number: " << std::endl;
            std::cin >> tellme;
            std::cout<< "\nYour number is "<< tellme << "\n" <<std::endl;
        """
    end
end
playing();
```
#### Example 6: Using C++ enums

```julia
julia> cxx"""
       class Klassy {
           public:
               enum Foo { Bar, Baz };
               static Foo exec(Foo x) { return x; }
       };
       """
# Access enum
julia> @cxx Klassy::Bar
CppEnum{symbol("Klassy::Foo")}(0)

# Pass enum as an argument
julia> @cxx Klassy::exec(@cxx(Klassy::Baz))
CppEnum{symbol("Klassy::Foo")}(1)
```


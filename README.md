##Cxx.jl

The Julia C++ Foreign Function Interface (FFI).


### Installation

```sh
# You will need to install Julia v0.4-dev
# Cxx.jl requires "staged functions" available only in v0.4 
# After installing julia-v0.4-dev, build it:

$ make -C deps distclean-openblas distclean-arpack distclean-suitesparse && make cleanall 
$ make –j4
``` 

In the Julia terminal, type
```python
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

```python  
# Using @cxx (e.g.):   
cxx""" void cppfunction(args){ . . .} """ => @cxx cppfunction(args)

# Using icxx (e.g.):
julia_function (args) icxx""" *code here*  """ end
```    

### **Using Cxx.jl:** 

#### Example 1: Embedding a simple C++ function in Julia

```python
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
julia_to_llvm(Void) = CppPtr{symbol("llvm::Type"),()}(Ptr{Void}@0x00007fa87b0002c8)
argt = Any[]
The number is 52
```

#### Example 2: Pass numeric arguments from Julia to C++

```python
julia> jnum = 10
10
    
julia> cxx"""
           void printme(int x) {
              std::cout << x << std::endl;
           }
       """
       
julia> @cxx printme(jnum)
julia_to_llvm(Void) = CppPtr{symbol("llvm::Type"),()}(Ptr{Void} 
@0x00007fa87b0002c8)
argt = [CppPtr{symbol("llvm::Type"),()}(Ptr{Void} @0x00007fa87b000418)] 
10 
```

#### Example 3: Pass strings from Julia to C++
 ```python
julia> cxx"""
          void printme(const char *name) {
             // const char* => std::string
             std::string sname = name;
             // print it out
             std::cout << sname << std::endl;
          }
      """

julia> @cxx printme(pointer("John"))
    julia_to_llvm(Void) = CppPtr{symbol("llvm::Type"),()}(Ptr{Void}
    @0x00007fa87b0002c8)
    argt = [CppPtr{symbol("llvm::Type"),()}(Ptr{Void}@0x00007fa87b0a6e00)]
    John 
```

#### Example 4: Pass a Julia expression to C++

```python
julia> cxx"""
          void testJuliaPrint() {
              $:(println("\nTo end this test, press any key")::Nothing);
          }
       """

julia> @cxx testJuliaPrint()
       julia_to_llvm(Void) = CppPtr{symbol("llvm::Type"),()}(Ptr{Void}@0x00007fa87b0002c8)
       argt = Any[]

       To end this test, press any key
```

#### Example 5: Embedding C++ code inside a Julia function

```python
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


# Examples

## Embedding a simple C++ function in Julia

```julia-repl
julia> cxx"#include <iostream>"
true

julia> cxx"""
           void mycppfunction() {
               int z = 0;
               int y = 5;
               int x = 10;
               z = x * y + 2;
               std::cout << "The number is " << z << std::endl;
           }
       """
true

julia> julia_function() = @cxx mycppfunction()
julia_function (generic function with 1 method)

julia> julia_function()
The number is 52
```

## Passing numeric arguments from Julia to C++

```julia-repl
julia> jnum = 10
10

julia> cxx"""
           void printme(int x) {
               std::cout << x << std::endl;
           }
       """
true

julia> @cxx printme(jnum)
10
```

## Passing strings from Julia to C++

```julia-repl
julia> cxx"""
           void printme(const char *name) {
               // const char* => std::string
               std::string sname = name;
               // print it out
               std::cout << sname << std::endl;
           }
       """
true

julia> @cxx printme(pointer("John"))
John
```

## Passing a Julia expression to C++

```julia-repl
julia> cxx"""
           void test_print() {
               $:(println("\nTo end this test, press any key")::Void);
           }
       """
true

julia> @cxx test_print()

To end this test, press any key
```

## Embedding C++ code inside a Julia function

```julia-repl
julia> function playing()
           for i = 1:5
               icxx"""
                   int tellme;
                   std::cout << "Please enter a number: " << std::endl;
                   std::cin >> tellme;
                   std::cout << "\nYour number is " << tellme << "\n" << std::endl;
               """
           end
       end
playing (generic function with 1 method)

julia> playing()
Please enter a number:
45

Your number is 45
```

## Using C++ enums

```julia-repl
julia> cxx"""
           class Klassy {
               public:
                   enum Foo { Bar, Baz };
                   static Foo exec(Foo x) { return x; }
           };
       """
true

julia> @cxx Klassy::Bar
Cxx.CppEnum{Symbol("Klassy::Foo"),UInt32}(0x00000000)

julia> @cxx Klassy::exec(@cxx Klassy::Baz)
Cxx.CppEnum{Symbol("Klassy::Foo"),UInt32}(0x00000001)
```

## C++ classes

```julia-repl
julia> cxx"""
           #include <iostream>
           class Hello {
               public:
                   void hello_world(const char *now) {
                       std::string snow = now;
                       std::cout << "Hello, World! Now is " << snow << std::endl;
                   }
           };
       """
true

julia> hello_class = @cxxnew Hello()
(class Hello *) @0x00007f82dd7d19a0


julia> tstamp = string(Dates.now())
"2017-08-21T13:53:27.85"

julia> @cxx hello_class->hello_world(pointer(tstamp))
Hello, World! Now is 2017-08-21T13:53:27.85
```

## Using C++ with shared libraries

ArrayMaker.h

```c++
#ifndef ARRAYMAKER_H
#define ARRAYMAKER_H

class ArrayMaker {
    private:
        int inumber;
        float fnumber;
        float* farr;
    public:
        ArrayMaker(int, float);
        float* fillarr();
};

#endif
```

ArrayMaker.cpp

```c++
#include "ArrayMaker.h"
#include <iostream>

using namespace std;

ArrayMaker::ArrayMaker(int inum, float fnum) {
    cout << "Got arguments: " << inum << " and " << fnum << endl;
    inumber = inum;
    fnumber = fnum;
    farr = new float[inumber];
}

float* ArrayMaker::fillarr() {
    cout << "Filling the array" << endl;
    for (int i = 0; i < inumber; i++) {
        farr[i] = fnumber;
        fnumber *= 2;
    }
    return farr;
}
```

Compile into a shared library

```
g++ -shared -fPIC ArrayMaker.cpp -o libarraymaker.so
```

Using from Julia

```julia-repl
julia> const path_to_lib = pwd();

julia> addHeaderDir(path_to_lib, kind=C_System)

julia> Libdl.dlopen(joinpath(path_to_lib, "libarraymaker.so"), Libdl.RTLD_GLOBAL)
Ptr{Void} @0x00007f9dd4556d60

julia> cxxinclude("ArrayMaker.h")

julia> maker = @cxxnew ArrayMaker(5, 2.0)
Got arguments: 5 and 2
(class ArrayMaker *) @0x00007f9dd7e25f10


julia> arr = @cxx maker->fillarr()
Filling the array
Ptr{Float32} @0x00007f9dd7e21370

julia> unsafe_wrap(Array, arr, 5)
5-element Array{Float32,1}:
  2.0
  4.0
  8.0
 16.0
 32.0
```

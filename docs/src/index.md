# Cxx.jl - The Julia C++ FFI

Cxx.jl is a Julia package that provides a C++ interoperability
interface for Julia. It also provides an experimental C++ REPL
mode for the Julia REPL.

## Functionality

This package provides the `cxx""` and `icxx""` custom
string literals for inputting C++ syntax directly. The two string
literals are distinguished by the C++ level scope they represent.
See the API documentation for more details.

## Installation

```julia
pkg> add Cxx
```

## Contents

```@contents
Pages = [
    "api.md",
    "examples.md",
    "implementation.md",
    "repl.md",
]
Depth = 1
```

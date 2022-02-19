# Clang initialization and include management
#
# Most of the actual Clang initialization is done on the C++ side, but, e.g.
# adding header search directories is done in this file.

using Libdl
using Clang_jll

if haskey(ENV, "LIBCXXFFI_INSTALL_PREFIX") &&
   !isempty(get(ENV, "LIBCXXFFI_INSTALL_PREFIX", ""))
    # DevMode
    const __DLEXT = Base.BinaryPlatforms.platform_dlext()
    const __ARTIFACT_BINDIR = Sys.iswindows() ? "bin" : "lib"

    const libcxxffi = normpath(joinpath(ENV["LIBCXXFFI_INSTALL_PREFIX"], __ARTIFACT_BINDIR, "libcxxffi.$__DLEXT"))
else
    # JLLMode
    error("TODO")
end

const CLANG_BIN = joinpath(Clang_jll.artifact_dir, "bin", "clang")
const CLANG_INC = joinpath(Clang_jll.artifact_dir, "lib", "clang", string(Base.libllvm_version),
                           "include")

# Set up Clang's global data structures
function init_libcxxffi()
    # Force libcxxffi to be opened with RTLD_GLOBAL
    Libdl.dlopen(libcxxffi, Libdl.RTLD_GLOBAL)
end

function setup_instance(args::Vector{String}, PCHBuffer = []; PCHTime = Base.Libc.TmStruct())
    x = Ref{ClangCompiler}()
    EmitPCH = true
    PCHPtr = C_NULL
    PCHSize = 0
    if !isempty(PCHBuffer)
        PCHPtr = pointer(PCHBuffer)
        PCHSize = sizeof(PCHBuffer)
    end
    @ccall libcxxffi.init_clang_instance(x::Ptr{Cvoid}, args::Ptr{Ptr{UInt8}}, length(args)::Cint, EmitPCH::Bool, PCHPtr::Ptr{UInt8}, PCHSize::Csize_t, PCHTime::Ref{Base.Libc.TmStruct})::Cvoid
    x[]
end

# Running global constructors
#
# When declaring new global variables that are not POD types (i.e. have
# non-trivial constructors), we need to call the constructor ourselves in
# order to make sure the allocated global is actually initialized. In LLVM IR
# this is declared as @llvm.global_ctors, but here we just ask clang to give
# us a list of all global constructors declared so far that need to be run
# and put them in a single function. Calling this function, will then in turn
# call all the global constructors and initialize them as needed.
import Base: llvmcall, cglobal

CollectGlobalConstructors(C) = pcpp"llvm::Function"(
    ccall((:CollectGlobalConstructors, libcxxffi), Ptr{Cvoid}, (Ref{ClangCompiler},), C))

function RunGlobalConstructors(C)
    p = convert(Ptr{Cvoid}, CollectGlobalConstructors(C))
    # If p is NULL it means we have no constructors to run
    if p != C_NULL
        eval(:(
            let f() = llvmcall($p, Cvoid, Tuple{})
                f()
            end
        ))
    end
end

"""
    cxxinclude([C::CxxInstance,] fname; isAngled=false)

Include the C++ file specified by `fname`. This should be used when the path
of the included file needs to be assembled programmatically as a Julia string.
In all other situations, it is advisable to just use `cxx"#include ..."`, which
makes the intent clear and has the same directory resolution logic as C++.
"""
function cxxinclude(C, fname; isAngled = false)
    if ccall((:cxxinclude, libcxxffi), Cint, (Ref{ClangCompiler}, Ptr{UInt8}, Cint),
        C, fname, isAngled) == 0
        error("Could not include file $fname")
    end
    RunGlobalConstructors(C)
end
cxxinclude(C::CxxInstance, fname; isAngled = false) =
    cxxinclude(instance(C), fname; isAngled = isAngled)
cxxinclude(fname; isAngled = false) = cxxinclude(__default_compiler__, fname; isAngled = isAngled)

# Tell the clang preprocessor to enter a source buffer.
# The first method (EnterBuffer) creates the buffer as an anonymous source file.
# Note that this mode of operation isn't really common in clang and there may
# be differences in behavior when compared to regular source files. In
# particular, there is no way to specify what directory contains an anonymous
# buffer and hence relative includes do not work.
function EnterBuffer(C, buf)
    ccall((:EnterSourceFile, libcxxffi), Cvoid,
        (Ref{ClangCompiler}, Ptr{UInt8}, Csize_t), C, buf, sizeof(buf))
end

# Enter's the buffer, while pretending it's the contents of the file at path
# `file`. Note that if `file` actually exists and is included from somewhere
# else, `buf` will be included instead.
function EnterVirtualSource(C, buf, file::String)
    ccall((:EnterVirtualFile, libcxxffi), Cvoid,
        (Ref{ClangCompiler}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
        C, buf, sizeof(buf), file, sizeof(file))
end
EnterVirtualSource(C, buf, file::Symbol) = EnterVirtualSource(C, buf, string(file))

# Parses everything until the end of the currently entered source file
# Returns true if the file was successfully parsed (i.e. no error occurred)
function ParseToEndOfFile(C)
    hadError = ccall((:_cxxparse, libcxxffi), Cint, (Ref{ClangCompiler},), C) == 0
    if !hadError
        RunGlobalConstructors(C)
    end
    !hadError
end

function ParseTypeName(C, ParseAlias = false)
    ret = ccall((:ParseTypeName, libcxxffi), Ptr{Cvoid}, (Ref{ClangCompiler}, Cint), C, ParseAlias)
    if ret == C_NULL
        error("Could not parse type name")
    end
    QualType(ret)
end

function cxxparse(C, string, isTypeName = false, ParseAlias = false, DisableAC = false)
    EnterBuffer(C, string)
    old = DisableAC && set_access_control_enabled(C, false)
    if isTypeName
        ParseTypeName(C, ParseAlias)
    else
        ok = ParseToEndOfFile(C)
        DisableAC && set_access_control_enabled(C, old)
        ok || error("Could not parse string")
    end
end
cxxparse(C::CxxInstance, string) = cxxparse(instance(C), string)
cxxparse(string) = cxxparse(__default_compiler__, string)

function ParseVirtual(C, string, VirtualFileName, FileName, Line, Column, isTypeName = false, DisableAC = false)
    EnterVirtualSource(C, string, VirtualFileName)
    old = DisableAC && set_access_control_enabled(C, false)
    if isTypeName
        ParseTypeName(C)
    else
        ok = ParseToEndOfFile(C)
        DisableAC && set_access_control_enabled(C, old)
        ok || error("Could not parse C++ code at $FileName:$Line:$Column")
    end
end

setup_cpp_env(C, f::pcpp"llvm::Function") =
    ccall((:setup_cpp_env, libcxxffi), Ptr{Cvoid}, (Ref{ClangCompiler}, Ptr{Cvoid}), C, f)

function cleanup_cpp_env(C, state)
    ccall((:cleanup_cpp_env, libcxxffi), Cvoid, (Ref{ClangCompiler}, Ptr{Cvoid}), C, state)
    RunGlobalConstructors(C)
end

# Include paths and macro handling

# The kind of include directory
const C_User = 0 # -I
const C_System = 1 # -isystem

# Like -isystem, but the header gets explicitly wrapped in `extern "C"`
const C_ExternCSystem = 2

"""
    addHeaderDir([C::CxxInstance,] dirname; kind=C_User, isFramework=false)

Add a directory to the Clang `#include` path. The keyword argument `kind`
specifies the kind of directory, and can be one of

* `C_User` (like passing `-I` when compiling)
* `C_System` (like `-isystem`)
* `C_ExternCSystem` (like `-isystem`, but wrap in `extern "C"`)

The `isFramework` argument is the equivalent of passing the `-F` option
to Clang.
"""
function addHeaderDir(C, dirname; kind = C_User, isFramework = false)
    ccall((:add_directory, libcxxffi), Cvoid,
        (Ref{ClangCompiler}, Cint, Cint, Ptr{UInt8}), C, kind, isFramework, dirname)
end
addHeaderDir(C::CxxInstance, dirname; kwargs...) = addHeaderDir(instance(C), dirname; kwargs...)
addHeaderDir(dirname; kwargs...) = addHeaderDir(__default_compiler__, dirname; kwargs...)

"""
    defineMacro([C::CxxInstance,] name)

Define a C++ macro. Equivalent to `cxx"#define \$name"`.
"""
function defineMacro(C, Name)
    ccall((:defineMacro, libcxxffi), Cvoid, (Ref{ClangCompiler}, Ptr{UInt8},), C, Name)
end
defineMacro(C::CxxInstance, Name) = defineMacro(instance(C), Name)
defineMacro(Name) = defineMacro(__default_compiler__, Name)

function initialize_instance!(C; register_boot = true)
    register_boot && register_booth(C)
end

function register_booth(C)
    C = instance(C)
    cxxinclude(C, joinpath(@__DIR__, "boot.h"))
end

function process_cxx_exception end
function setup_exception_callback()
    # Setup exception translation callback
    callback = cglobal((:process_cxx_exception, libcxxffi), Ptr{Cvoid})
    unsafe_store!(callback, @cfunction(process_cxx_exception, Union{}, (UInt64, Ptr{Cvoid})))
end

function get_compiler_args(; is_cxx=true, version=v"7.1.0")
    args = JLLEnvs.get_default_args(is_cxx, version)
    push!(args, "-isystem" * CLANG_INC)
    is_cxx && push!(args, "-nostdinc++", "-nostdlib++")
    push!(args, "-nostdinc", "-nostdlib")
    pushfirst!(args, CLANG_BIN)  # Argv0
    return args
end

# As an optimzation, create a generic function per compiler instance,
# to avoid having to create closures at the call site
const GlobalPCHBuffer = UInt8[]
const inited = Ref{Bool}(false)
const PCHTime = Base.Libc.TmStruct()
const GlobalHeaders = Sys.isapple() ? String[] : collectAllHeaders(nostdcxx)
Base.Libc.time(PCHTime)
function __init__()
    inited[] && return
    inited[] = true
    init_libcxxffi()
    empty!(active_instances)

    args = get_compiler_args(; version=v"7.1.0")
    push!(args, "-std=c++14")
    Sys.isapple() && push!(args, "-stdlib=libc++")
    push!(args, joinpath(@__DIR__, "dummy.cpp"))

    C = setup_instance(args, GlobalPCHBuffer; PCHTime = PCHTime)
    initialize_instance!(C, register_boot = isempty(GlobalPCHBuffer))
    push!(active_instances, C)
end

function reset_init!()
    empty!(active_instances)
    inited[] = false
end

function new_clang_instance(register_boot = true, args = get_compiler_args())
    push!(args, "-std=c++14")
    Sys.isapple() && push!(args, "-stdlib=libc++")
    push!(args, joinpath(@__DIR__, "dummy.cpp"))
    C = setup_instance(args)
    initialize_instance!(C; register_boot = register_boot, headers = String[])
    push!(active_instances, C)
    CxxInstance{length(active_instances)}()
end

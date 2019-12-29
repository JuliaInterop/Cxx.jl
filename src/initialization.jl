# Clang initialization and include management
#
# Most of the actual Clang initialization is done on the C++ side, but, e.g.
# adding header search directories is done in this file.

using Libdl

# Paths
binpath = BASE_JULIA_BIN
srcpath = BASE_JULIA_SRC
depspath = joinpath(BASE_JULIA_SRC, "deps", "srccache")

# Load the Cxx.jl bootstrap library (in debug version if we're running the Julia debug version)
lib_suffix = ccall(:jl_is_debugbuild, Cint, ()) != 0 ? "-debug" : ""
@static if Sys.iswindows()
    const libcxxffi = joinpath(@__DIR__, "..", "deps", "usr", "bin", "libcxxffi"*lib_suffix)
else
    const libcxxffi = joinpath(@__DIR__, "..", "deps", "usr", "lib", "libcxxffi"*lib_suffix)
end
# Set up Clang's global data structures
function init_libcxxffi()
    # Force libcxxffi to be opened with RTLD_GLOBAL
    Libdl.dlopen(libcxxffi, Libdl.RTLD_GLOBAL)
end
init_libcxxffi()

function setup_instance(PCHBuffer = []; makeCCompiler=false, target = C_NULL, CPU = C_NULL,
        useDefaultCxxABI=true, PCHTime = Base.Libc.TmStruct())
    x = Ref{ClangCompiler}()
    sysroot = @static isapple() ? strip(read(`xcrun --sdk macosx --show-sdk-path`, String)) : C_NULL
    EmitPCH = true
    PCHPtr = C_NULL
    PCHSize = 0
    if !isempty(PCHBuffer)
        PCHPtr = pointer(PCHBuffer)
        PCHSize = sizeof(PCHBuffer)
    end
    ccall((:init_clang_instance,libcxxffi),Cvoid,
        (Ptr{Cvoid},Ptr{UInt8},Ptr{UInt8},Ptr{UInt8},Bool,Bool,Ptr{UInt8},Csize_t,Ref{Base.Libc.TmStruct},Ptr{Cvoid}),
        x,target,CPU,sysroot,EmitPCH,makeCCompiler, PCHPtr, PCHSize, PCHTime,
        _julia_to_llvm(Any)[2])
    useDefaultCxxABI && ccall((:apply_default_abi, libcxxffi),
        Cvoid, (Ref{ClangCompiler},), x)
    x[]
end

function setup_instance_from_inovcation(invocation)
    x = Ref{ClangCompiler}()
    ccall((:init_clang_instance_from_invocation,libcxxffi),Cvoid,
        (Ptr{Cvoid},Ptr{Cvoid}), x, invocation)
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
    ccall((:CollectGlobalConstructors,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},),C))

function RunGlobalConstructors(C)
    p = convert(Ptr{Cvoid}, CollectGlobalConstructors(C))
    # If p is NULL it means we have no constructors to run
    if p != C_NULL
        eval(:(let f()=llvmcall($p,Cvoid,Tuple{}); f(); end))
    end
end

"""
    cxxinclude([C::CxxInstance,] fname; isAngled=false)

Include the C++ file specified by `fname`. This should be used when the path
of the included file needs to be assembled programmatically as a Julia string.
In all other situations, it is avisable to just use `cxx"#include ..."`, which
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
function EnterBuffer(C,buf)
    ccall((:EnterSourceFile,libcxxffi),Cvoid,
        (Ref{ClangCompiler},Ptr{UInt8},Csize_t),C,buf,sizeof(buf))
end

# Enter's the buffer, while pretending it's the contents of the file at path
# `file`. Note that if `file` actually exists and is included from somewhere
# else, `buf` will be included instead.
function EnterVirtualSource(C,buf,file::String)
    ccall((:EnterVirtualFile,libcxxffi),Cvoid,
        (Ref{ClangCompiler},Ptr{UInt8},Csize_t,Ptr{UInt8},Csize_t),
        C,buf,sizeof(buf),file,sizeof(file))
end
EnterVirtualSource(C,buf,file::Symbol) = EnterVirtualSource(C,buf,string(file))

# Parses everything until the end of the currently entered source file
# Returns true if the file was successfully parsed (i.e. no error occurred)
function ParseToEndOfFile(C)
    hadError = ccall((:_cxxparse,libcxxffi),Cint,(Ref{ClangCompiler},),C) == 0
    if !hadError
        RunGlobalConstructors(C)
    end
    !hadError
end

function ParseTypeName(C, ParseAlias = false)
    ret = ccall((:ParseTypeName,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Cint),C, ParseAlias)
    if ret == C_NULL
        error("Could not parse type name")
    end
    QualType(ret)
end

function cxxparse(C, string, isTypeName = false, ParseAlias = false, DisableAC = false)
    EnterBuffer(C,string)
    old = DisableAC && set_access_control_enabled(C, false)
    if isTypeName
        ParseTypeName(C,ParseAlias)
    else
        ok = ParseToEndOfFile(C)
        DisableAC && set_access_control_enabled(C, old)
        ok || error("Could not parse string")
    end
end
cxxparse(C::CxxInstance,string) = cxxparse(instance(C),string)
cxxparse(string) = cxxparse(__default_compiler__,string)

function ParseVirtual(C,string, VirtualFileName, FileName, Line, Column, isTypeName = false, DisableAC = false)
    EnterVirtualSource(C,string, VirtualFileName)
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
    ccall((:setup_cpp_env,libcxxffi),Ptr{Cvoid},(Ref{ClangCompiler},Ptr{Cvoid}),C,f)

function cleanup_cpp_env(C, state)
    ccall((:cleanup_cpp_env,libcxxffi),Cvoid,(Ref{ClangCompiler}, Ptr{Cvoid}),C,state)
    RunGlobalConstructors(C)
end

# Include paths and macro handling

# The kind of include directory
const C_User            = 0 # -I
const C_System          = 1 # -isystem

# Like -isystem, but the header gets explicitly wrapped in `extern "C"`
const C_ExternCSystem   = 2

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
addHeaderDir(C::CxxInstance, dirname; kwargs...) = addHeaderDir(instance(C),dirname; kwargs...)
addHeaderDir(dirname; kwargs...) = addHeaderDir(__default_compiler__,dirname; kwargs...)

"""
    defineMacro([C::CxxInstance,] name)

Define a C++ macro. Equivalent to `cxx"#define \$name"`.
"""
function defineMacro(C,Name)
    ccall((:defineMacro, libcxxffi), Cvoid, (Ref{ClangCompiler},Ptr{UInt8},), C, Name)
end
defineMacro(C::CxxInstance,Name) = defineMacro(instance(C),Name)
defineMacro(Name) = defineMacro(__default_compiler__,Name)

# Setup Default Search Paths
#
# Clang has some code for this in Driver/, but it is not easily accessible for
# our use case. Instead, we have custom logic here, which should be sufficient
# for most use cases. This logic will be adjusted as the need arises.

# Sometimes it is useful to skip this step and do it yourself, e.g. when building
# a custom standard library.
nostdcxx = haskey(ENV,"CXXJL_NOSTDCXX")

# On OS X, we just use the libc++ headers that ship with XCode
@static if isapple() function collectStdHeaders!(headers)
    xcode_path = strip(read(`xcode-select --print-path`, String))
    sdk_path = strip(read(`xcrun --show-sdk-path`, String))
    occursin("Xcode", xcode_path) && (xcode_path *= "/Toolchains/XcodeDefault.xctoolchain/")
    didfind = false
    lib = joinpath(xcode_path, "usr", "lib", "c++", "v1")
    inc = joinpath(xcode_path, "usr", "include", "c++", "v1")
    isdir(lib) && (push!(headers, (lib, C_ExternCSystem)); didfind = true;)
    isdir(inc) && (push!(headers, (inc, C_ExternCSystem)); didfind = true;)
    if isdir("/usr/include")
        push!(headers,("/usr/include", C_System))
    else isdir(joinpath(sdk_path, "usr", "include"))
        push!(headers,(joinpath(sdk_path, "usr", "include"), C_System))
    end
    didfind || error("Could not find C++ standard library. Is XCode or CommandLineTools installed?")
end # function addStdHeaders(C)
end # isapple

# On linux the situation is a little more complicated as the system header is
# generally shipped with GCC, which every distribution seems to put in a
# different place.
# The below is translated from Clang's
#   Generic_GCC::GCCInstallationDetector::ScanLibDirForGCCTriple
function ScanLibDirForGCCTriple(base,triple)
    LibSuffixes = [
        ("/gcc/" * triple,"/../../.."),
        # Skip cross compilers
        # "gcc-cross"
        ("/" * triple * "/gcc/" * triple, "/../../../.."),
        ("/" * triple, "/../.."),
        # Don't try to find ubuntu weirdness
        # hopefully recent enough versions don't
        # have this mismatch
        ("/i386-linux-gnu/gcc/" * triple, "/../../../..")
    ]
    Version = v"0.0.0"
    VersionString = ""
    GccPath = ""
    for (suffix,isuffix) in LibSuffixes
        path = base * suffix
        isdir(path) || continue
        for dir in readdir(path)
            isdir(joinpath(path, dir)) || continue
            CandidateVersion = try
                VersionNumber(dir)
            catch
                continue
            end
            # Ignore versions less than 4.8
            if CandidateVersion < v"4.8" ||
                CandidateVersion < Version
                continue
            end
            InstallPath = path * "/" * dir
            IncPath = InstallPath * isuffix * "/../include"
            if ( !isdir( IncPath * "/" * triple * "/c++/" * dir ) ||
                  !isdir( IncPath * "/c++/" * dir ) )  &&
               ( !isdir( IncPath * "/c++/" * dir * "/" * triple ) ||
                  !isdir( IncPath * "/c++/" * dir ) )  &&
               (triple != "i686-linux-gnu" || !isdir( IncPath * "/i386-linux-gnu/c++/" * dir ))
                continue
            end
            Version = CandidateVersion
            VersionString = dir
            InstallPath = path * "/" * VersionString
            GccPath = InstallPath * isuffix
        end
    end
    return (Version, VersionString, GccPath)
end

function CollectLinuxHeaderPaths!(headers)
    # Taken from Clang's ToolChains.cpp
    X86_64LibDirs = ["/lib64", "/lib"]
    X86_64Triples = [
    "x86_64-linux-gnu", "x86_64-unknown-linux-gnu", "x86_64-pc-linux-gnu",
    "x86_64-redhat-linux6E", "x86_64-redhat-linux", "x86_64-suse-linux",
    "x86_64-manbo-linux-gnu", "x86_64-linux-gnu", "x86_64-slackware-linux",
    "x86_64-linux-android", "x86_64-unknown-linux", "x86_64-generic-linux"
    ]

    X86LibDirs = ["/lib32", "/lib"]
    X86Triples = ["i686-linux-gnu",       "i686-pc-linux-gnu",     "i486-linux-gnu",
                  "i386-linux-gnu",       "i386-redhat-linux6E",   "i686-redhat-linux",
                  "i586-redhat-linux",    "i386-redhat-linux",     "i586-suse-linux",
                  "i486-slackware-linux", "i686-montavista-linux", "i686-linux-android",
                  "i586-linux-gnu"]


    CXXJL_ROOTDIR = get(ENV, "CXXJL_ROOTDIR", "/usr")
    Prefixes = [ CXXJL_ROOTDIR ]

    LibDirs = (Int === Int64 ? X86_64LibDirs : X86LibDirs)
    Triples = (Int === Int64 ? X86_64Triples : X86Triples)
    Version = v"0.0.0"
    Path = VersionString = Triple = ""
    for prefix in Prefixes
        isdir(prefix) || continue
        for dir in LibDirs
            isdir(prefix*dir) || continue
            for triple in Triples
                CandidateVersion, CandidateVersionString, CandidatePath =
                    ScanLibDirForGCCTriple(prefix*dir,triple)
                if CandidateVersion > Version
                    Version = CandidateVersion
                    VersionString = CandidateVersionString
                    Path = CandidatePath
                    Triple = triple
                end
            end
        end
    end

    if Version == v"0.0.0"
        error("Could not find C++ standard library")
    end

    found = false

    incpath = Path * "/../include"

    push!(headers, (incpath, C_System))
    push!(headers, (incpath * "/c++/" * VersionString, C_System))
    push!(headers, (incpath * "/c++/" * VersionString * "/backward", C_System))

    # check which type of include dir we have
    if Triple == "i686-linux-gnu" && !isdir(incpath * "/" * Triple)
        Triple = "i386-linux-gnu"
    end
    if isdir(incpath * "/" * Triple)
       push!(headers, (incpath * "/" * Triple * "/c++/" * VersionString, C_System))
       push!(headers, (incpath * "/" * Triple, C_System))
    else
       push!(headers, (incpath * "/c++/" * VersionString * "/" * Triple, C_System))
    end
end

@static if islinux() function collectStdHeaders!(headers)
    CollectLinuxHeaderPaths!(headers)
    push!(headers,("/usr/include", C_System));
end # function addStdHeaders(C)
end # islinux

@static if iswindows() function collectStdHeaders!(headers)
    base = joinpath(@__DIR__, "..", "deps", "usr")
    push!(headers,(joinpath(base, "mingw", "include"), C_System))
    push!(headers,(joinpath(base, "mingw", "include", "c++", "7.1.0"), C_System))
    push!(headers,(joinpath(base, "mingw", "include", "c++", "7.1.0", "x86_64-w64-mingw32"), C_System))
    push!(headers,(joinpath(base, "mingw", "sys-root", "include"), C_System)) # not sure whether this is necessary
end #function addStdHeaders(C)
end # iswindows

# Also add clang's intrinsic headers
function collectClangHeaders!(headers)
    llvmver = string(Base.libllvm_version)
    baseclangdir = joinpath(BASE_JULIA_BIN, "..", "lib", "clang", llvmver, "include")
    cxxclangdir = @static IS_BINARYBUILD ? joinpath(@__DIR__, "..", "deps", "usr", "build", "clang-$llvmver", "lib", "clang", llvmver, "include") :
                                           baseclangdir
    if isdir(baseclangdir)
        push!(headers, (baseclangdir, C_ExternCSystem))
    else
        @assert isdir(cxxclangdir)
        push!(headers, (cxxclangdir, C_ExternCSystem))
    end
end

function collectAllHeaders!(headers, nostdcxx)
    nostdcxx || collectStdHeaders!(headers)
    for header in split(get(ENV, "CXXJL_HEADER_DIRS", ""), ":")
      push!(headers, (header, C_System))
    end
    collectClangHeaders!(headers)
    headers
end
collectAllHeaders(nostdcxx) = collectAllHeaders!(Tuple{String,Cint}[], nostdcxx)

function addHeaders(C, headers)
    for (path, kind) in headers
        addHeaderDir(C, path, kind = kind)
    end
end

function initialize_instance!(C; register_boot = true, headers = collectAllHeaders(nostdcxx))
    addHeaders(C, headers)
    register_boot && register_booth(C)
end

function register_booth(C)
    C = instance(C)
    cxxinclude(C, joinpath(@__DIR__, "boot.h"))
end

function process_cxx_exception end
function setup_exception_callback()
    # Setup exception translation callback
    callback = cglobal((:process_cxx_exception,libcxxffi),Ptr{Cvoid})
    unsafe_store!(callback, @cfunction(process_cxx_exception,Union{},(UInt64,Ptr{Cvoid})))
end

# As an optimzation, create a generic function per compiler instance,
# to avoid having to create closures at the call site
const GlobalPCHBuffer = UInt8[]
const inited = Ref{Bool}(false)
const PCHTime = Base.Libc.TmStruct()
const GlobalHeaders = collectAllHeaders(nostdcxx)
Base.Libc.time(PCHTime)
function __init__()
    inited[] && return
    inited[] = true
    init_libcxxffi()
    empty!(active_instances)
    C = setup_instance(GlobalPCHBuffer; PCHTime=PCHTime)
    initialize_instance!(C, register_boot=isempty(GlobalPCHBuffer),
        headers = GlobalHeaders)
    push!(active_instances, C)
end

function reset_init!()
    empty!(active_instances)
    inited[] = false
end

function new_clang_instance(register_boot = true, makeCCompiler = false; target = C_NULL, CPU = C_NULL)
    C = setup_instance(makeCCompiler = makeCCompiler, target = target, CPU = CPU)
    initialize_instance!(C; register_boot = register_boot)
    push!(active_instances, C)
    CxxInstance{length(active_instances)}()
end

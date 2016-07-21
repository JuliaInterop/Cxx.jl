# Clang initialization and include management
#
# Most of the actual Clang initialization is done on the C++ side, but, e.g.
# adding header search directories is done in this file.

# Paths
basepath = joinpath(BASE_JULIA_HOME, "../../")
depspath = joinpath(basepath, "deps", "srccache")

# Load the Cxx.jl bootstrap library (in debug version if we're running the Julia
# debug version)
push!(Libdl.DL_LOAD_PATH, joinpath(dirname(Base.source_path()),"../deps/usr/lib/"))

const libcxxffi =
    string("libcxxffi", ccall(:jl_is_debugbuild, Cint, ()) != 0 ? "-debug" : "")

# Set up Clang's global data structures
function init_libcxxffi()
    # Force libcxxffi to be opened with RTLD_GLOBAL
    Libdl.dlopen(libcxxffi, Libdl.RTLD_GLOBAL)
end
init_libcxxffi()

function setup_instance(UsePCH = C_NULL; makeCCompiler=false, target = C_NULL, CPU = C_NULL)
    x = Array(ClangCompiler,1)
    sysroot = @static is_apple() ? strip(readstring(`xcodebuild -version -sdk macosx Path`)) : C_NULL
    EmitPCH = true
    ccall((:init_clang_instance,libcxxffi),Void,
        (Ptr{Void},Ptr{UInt8},Ptr{UInt8},Ptr{UInt8},Bool,Bool,Ptr{UInt8},Ptr{Void}),
        x,target,CPU,sysroot,EmitPCH,makeCCompiler,UsePCH,julia_to_llvm(Any))
    x[1]
end

function setup_instance_from_inovcation(invocation)
    x = Array(ClangCompiler,1)
    ccall((:init_clang_instance_from_invocation,libcxxffi),Void,
        (Ptr{Void},Ptr{Void}), x, invocation)
    x[1]
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
    ccall((:CollectGlobalConstructors,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},),&C))

function RunGlobalConstructors(C)
    p = convert(Ptr{Void}, CollectGlobalConstructors(C))
    # If p is NULL it means we have no constructors to run
    if p != C_NULL
        eval(:(llvmcall($p,Void,Tuple{})))
    end
end

# Include a file names fname. Preserved for situations in which the
# path of an include file needs to be assembled as a julia string. In all
# other situations, it is advisable, to just use cxx"" with regular #include's
# which makes the intent clear and has the same directory resolution logic
# as C++
function cxxinclude(C, fname; isAngled = false)
    if ccall((:cxxinclude, libcxxffi), Cint, (Ptr{ClangCompiler}, Ptr{UInt8}, Cint),
        &C, fname, isAngled) == 0
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
    ccall((:EnterSourceFile,libcxxffi),Void,
        (Ptr{ClangCompiler},Ptr{UInt8},Csize_t),&C,buf,sizeof(buf))
end

# Enter's the buffer, while pretending it's the contents of the file at path
# `file`. Note that if `file` actually exists and is included from somewhere
# else, `buf` will be included instead.
function EnterVirtualSource(C,buf,file::String)
    ccall((:EnterVirtualFile,libcxxffi),Void,
        (Ptr{ClangCompiler},Ptr{UInt8},Csize_t,Ptr{UInt8},Csize_t),
        &C,buf,sizeof(buf),file,sizeof(file))
end
EnterVirtualSource(C,buf,file::Symbol) = EnterVirtualSource(C,buf,string(file))

# Parses everything until the end of the currently entered source file
# Returns true if the file was successfully parsed (i.e. no error occurred)
function ParseToEndOfFile(C)
    hadError = ccall((:_cxxparse,libcxxffi),Cint,(Ptr{ClangCompiler},),&C) == 0
    if !hadError
        RunGlobalConstructors(C)
    end
    !hadError
end

function ParseTypeName(C, ParseAlias = false)
    ret = ccall((:ParseTypeName,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Cint),&C, ParseAlias)
    if ret == C_NULL
        error("Could not parse type name")
    end
    QualType(ret)
end

function cxxparse(C,string, isTypeName = false, ParseAlias = false)
    EnterBuffer(C,string)
    if isTypeName
        ParseTypeName(C,ParseAlias)
    else
        ParseToEndOfFile(C) || error("Could not parse string")
    end
end
cxxparse(C::CxxInstance,string) = cxxparse(instance(C),string)
cxxparse(string) = cxxparse(__default_compiler__,string)

function ParseVirtual(C,string, VirtualFileName, FileName, Line, Column, isTypeName = false)
    EnterVirtualSource(C,string, VirtualFileName)
    if isTypeName
        ParseTypeName(C)
    else
        ParseToEndOfFile(C) ||
            error("Could not parse C++ code at $FileName:$Line:$Column")
    end
end

setup_cpp_env(C, f::pcpp"llvm::Function") =
    ccall((:setup_cpp_env,libcxxffi),Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,f)

function cleanup_cpp_env(C, state)
    ccall((:cleanup_cpp_env,libcxxffi),Void,(Ptr{ClangCompiler}, Ptr{Void}),&C,state)
    RunGlobalConstructors(C)
end

# Include paths and macro handling

# The kind of include directory
const C_User            = 0 # -I
const C_System          = 1 # -isystem

# Like -isystem, but the header gets explicitly wrapped in `extern "C"`
const C_ExternCSystem   = 2

# Add a directory to the clang include path
# `kind` is one of the options above ans `isFramework` is the equivalent of the
# `-F` option to clang.
function addHeaderDir(C, dirname; kind = C_User, isFramework = false)
    ccall((:add_directory, libcxxffi), Void,
        (Ptr{ClangCompiler}, Cint, Cint, Ptr{UInt8}), &C, kind, isFramework, dirname)
end
addHeaderDir(C::CxxInstance, dirname; kwargs...) = addHeaderDir(instance(C),dirname; kwargs...)
addHeaderDir(dirname; kwargs...) = addHeaderDir(__default_compiler__,dirname; kwargs...)

# The equivalent of `#define $Name`
function defineMacro(C,Name)
    ccall((:defineMacro, libcxxffi), Void, (Ptr{ClangCompiler},Ptr{UInt8},), &C, Name)
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
@static if is_apple() function addStdHeaders(C)
    xcode_path =
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/"
    didfind = false
    for path in ("usr/lib/c++/v1/","usr/include/c++/v1")
        if isdir(joinpath(xcode_path,path))
            addHeaderDir(C,joinpath(xcode_path,path), kind = C_ExternCSystem)
            didfind = true
        end
    end
    didfind || error("Could not find C++ standard library. Is XCode installed?")
end # function addStdHeaders(C)
end # is_apple

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

function AddLinuxHeaderPaths(C)
    # Taken from Clang's ToolChains.cpp
    const X86_64LibDirs = ["/lib64", "/lib"]
    const X86_64Triples = [
    "x86_64-linux-gnu", "x86_64-unknown-linux-gnu", "x86_64-pc-linux-gnu",
    "x86_64-redhat-linux6E", "x86_64-redhat-linux", "x86_64-suse-linux",
    "x86_64-manbo-linux-gnu", "x86_64-linux-gnu", "x86_64-slackware-linux",
    "x86_64-linux-android", "x86_64-unknown-linux"
    ]

    const X86LibDirs = ["/lib32", "/lib"]
    const X86Triples = ["i686-linux-gnu",       "i686-pc-linux-gnu",     "i486-linux-gnu",
                        "i386-linux-gnu",       "i386-redhat-linux6E",   "i686-redhat-linux",
                        "i586-redhat-linux",    "i386-redhat-linux",     "i586-suse-linux",
                        "i486-slackware-linux", "i686-montavista-linux", "i686-linux-android",
                        "i586-linux-gnu"]


    CXXJL_ROOTDIR = get(ENV, "CXXJL_ROOTDIR", "/usr")
    const Prefixes = [ CXXJL_ROOTDIR ]

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

    addHeaderDir(C, incpath, kind = C_System)
    addHeaderDir(C, incpath * "/c++/" * VersionString, kind = C_System)
    addHeaderDir(C, incpath * "/c++/" * VersionString * "/backward", kind = C_System)

    # check which type of include dir we have
    if Triple == "i686-linux-gnu" && !isdir(incpath * "/" * Triple)
        Triple = "i386-linux-gnu"
    end
    if isdir(incpath * "/" * Triple)
       addHeaderDir(C, incpath * "/" * Triple * "/c++/" * VersionString, kind = C_System)
       addHeaderDir(C, incpath * "/" * Triple, kind = C_System)
    else
       addHeaderDir(C, incpath * "/c++/" * VersionString * "/" * Triple, kind = C_System)
    end
end

@static if is_linux() function addStdHeaders(C)
    AddLinuxHeaderPaths(C)
    addHeaderDir(C,"/usr/include", kind = C_System);
end # function addStdHeaders(C)
end # is_linux

@static if is_windows() function addStdHeaders(C)
      base = "C:/mingw-builds/x64-4.8.1-win32-seh-rev5/mingw64/"
      addHeaderDir(C,joinpath(base,"x86_64-w64-mingw32/include"), kind = C_System)
      #addHeaderDir(joinpath(base,"lib/gcc/x86_64-w64-mingw32/4.8.1/include/"), kind = C_System)
      addHeaderDir(C,joinpath(base,"lib/gcc/x86_64-w64-mingw32/4.8.1/include/c++"), kind = C_System)
      addHeaderDir(C,joinpath(base,"lib/gcc/x86_64-w64-mingw32/4.8.1/include/c++/x86_64-w64-mingw32"), kind = C_System)
end #function addStdHeaders(C)
end # is_windows

# Also add clang's intrinsic headers
function addClangHeaders(C)
    ver = Base.VersionNumber(Base.libllvm_version)
    ver = Base.VersionNumber(ver.major, ver.minor, ver.patch)        
    baseclangdir = joinpath(BASE_JULIA_HOME,
        "../lib/clang/$ver/include/")
    cxxclangdir = joinpath(dirname(@__FILE__),
        "../deps/build/clang-$(Base.libllvm_version)/lib/clang/$ver/include")
    if isdir(baseclangdir)
        addHeaderDir(C, baseclangdir, kind = C_ExternCSystem)
    else
        @assert isdir(cxxclangdir)
        addHeaderDir(C, cxxclangdir, kind = C_ExternCSystem)
    end
end

function initialize_instance!(C; register_boot = true)
    if !nostdcxx
        addStdHeaders(C)
    end
    addClangHeaders(C)
    register_boot && register_booth(C)
end

function register_booth(C)
    C = Cxx.instance(C)
    cxxinclude(C,joinpath(dirname(@__FILE__),"boot.h"))
end

# As an optimzation, create a generic function per compiler instance,
# to avoid having to create closures at the call site
function __init__()
    init_libcxxffi()
    C = setup_instance()
    initialize_instance!(C)
    push!(active_instances, C)
    # Setup exception translation callback
    callback = cglobal((:process_cxx_exception,libcxxffi),Ptr{Void})
    unsafe_store!(callback, cfunction(process_cxx_exception,Union{},Tuple{UInt64,Ptr{Void}}))
end

function new_clang_instance(register_boot = true, makeCCompiler = false; target = C_NULL, CPU = C_NULL)
    C = setup_instance(makeCCompiler = makeCCompiler, target = target, CPU = CPU)
    initialize_instance!(C; register_boot = register_boot)
    push!(active_instances, C)
    CxxInstance{length(active_instances)}()
end

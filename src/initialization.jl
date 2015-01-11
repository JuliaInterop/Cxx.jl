# Clang initialization and include management
#
# Most of the actual Clang initialization is done on the C++ side, but, e.g.
# adding header search directories is done in this file.

# Load the Cxx.jl bootstrap library (in debug version if we're running the Julia
# debug version)
push!(DL_LOAD_PATH, joinpath(dirname(Base.source_path()),"../deps/usr/lib/"))

const libcxxffi =
    string("libcxxffi", ccall(:jl_is_debugbuild, Cint, ()) != 0 ? "-debug" : "")

# Set up Clang's global data structures
function init()
    # Force libcxxffi to be opened with RTLD_GLOBAL
    dlopen(libcxxffi, RTLD_GLOBAL)
    ccall((:init_julia_clang_env,libcxxffi),Void,())
end
init()

# Running global constructors
#
# When declaring new global variables that are not POD types (i.e. have
# non-trivial constructors), we need to call the constructor ourselves in
# order to make sure the allocated global is actually initialized. In LLVM IR
# this is declared as @llvm.global_ctors, but here we just ask clang to give
# us a list of all global constructors declared so far that need to be run
# and put them in a single function. Calling this function, will then in turn
# call all the global constructors and initialize them as needed.
import Base: llvmcall

CollectGlobalConstructors() = pcpp"llvm::Function"(
    ccall((:CollectGlobalConstructors,libcxxffi),Ptr{Void},()))

function RunGlobalConstructors()
    p = CollectGlobalConstructors().ptr
    # If p is NULL it means we have no constructors to run
    if p != C_NULL
        eval(:(llvmcall($p,Void,())))
    end
end

# Include a file names fname. Preserved for situations in which the
# path of an include file needs to be assembled as a julia string. In all
# other situations, it is advisable, to just use cxx"" with regular #include's
# which makes the intent clear and has the same directory resolution logic
# as C++
function cxxinclude(fname; isAngled = false)
    if ccall((:cxxinclude, libcxxffi), Cint, (Ptr{Uint8}, Cint),
        fname, isAngled) == 0
        error("Could not include file $fname")
    end
    RunGlobalConstructors()
end

# Tell the clang preprocessor to enter a source buffer.
# The first method (EnterBuffer) creates the buffer as an anonymous source file.
# Note that this mode of operation isn't really common in clang and there may
# be differences in behavior when compared to regular source files. In
# particular, there is no way to specify what directory contains an anonymous
# buffer and hence relative includes do not work.
function EnterBuffer(buf)
    ccall((:EnterSourceFile,libcxxffi),Void,
        (Ptr{Uint8},Csize_t),buf,sizeof(buf))
end

# Enter's the buffer, while pretending it's the contents of the file at path
# `file`. Note that if `file` actually exists and is included from somewhere
# else, `buf` will be included instead.
function EnterVirtualSource(buf,file::ByteString)
    ccall((:EnterVirtualFile,libcxxffi),Void,
        (Ptr{Uint8},Csize_t,Ptr{Uint8},Csize_t),
        buf,sizeof(buf),file,sizeof(file))
end
EnterVirtualSource(buf,file::Symbol) = EnterVirtualSource(buf,bytestring(file))

# Parses everything until the end of the currently entered source file
# Returns true if the file was successfully parsed (i.e. no error occurred)
function ParseToEndOfFile()
    hadError = ccall(:_cxxparse,Cint,()) == 0
    if !hadError
        RunGlobalConstructors()
    end
    !hadError
end

function cxxparse(string)
    EnterBuffer(string)
    ParseToEndOfFile() || error("Could not parse string")
end

function ParseVirtual(string, VirtualFileName, FileName, Line, Column)
    EnterVirtualSource(string, VirtualFileName)
    ParseToEndOfFile() ||
        error("Could not parse C++ code at $FileName:$Line:$Column")
end

setup_cpp_env(f::pcpp"llvm::Function") =
    ccall((:setup_cpp_env,libcxxffi),Ptr{Void},(Ptr{Void},),f)
function cleanup_cpp_env(state)
    ccall((:cleanup_cpp_env,libcxxffi),Void,(Ptr{Void},),state)
    RunGlobalConstructors()
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
function addHeaderDir(dirname; kind = C_User, isFramework = false)
    ccall((:add_directory, libcxxffi), Void,
        (Cint, Cint, Ptr{Uint8}), kind, isFramework, dirname)
end

# The equivalent of `#define $Name`
function defineMacro(Name)
    ccall((:defineMacro, libcxxffi), Void, (Ptr{Uint8},), Name)
end

# Setup Default Search Paths
#
# Clang has some code for this in Driver/, but it is not easily accessible for
# our use case. Instead, we have custom logic here, which should be sufficient
# for most use cases. This logic will be adjusted as the need arises.

basepath = joinpath(JULIA_HOME, "../../")

# On OS X, we just use the libc++ headers that ship with XCode
@osx_only begin
    xcode_path =
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/"
    didfind = false
    for path in ("usr/lib/c++/v1/","usr/include/c++/v1")
        if isdir(joinpath(xcode_path,path))
            addHeaderDir(joinpath(xcode_path,path), kind = C_ExternCSystem)
            didfind = true
        end
    end
    didfind || error("Could not find C++ standard library. Is XCode installed?")
end

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
        ("/" * triple, "/../..")
        # Don't try to find ubuntu weirdness
        # hopefully recent enough versions don't
        # have this mismatch
        # "/i386-linux-gnu/gcc/" * triple
    ]
    Version = v"0.0.0"
    VersionString = ""
    GccPath = ""
    for (suffix,isuffix) in LibSuffixes
        path = base * suffix
        isdir(path) || continue
        for dir in readdir(path)
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
            if !isdir( IncPath * "/" * triple * "/c++/" * dir ) ||
               !isdir( IncPath * "/c++/" * dir )
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

function AddLinuxHeaderPaths()
    # Taken from Clang's ToolChains.cpp
    const X86_64LibDirs = ["/lib64", "/lib"]
    const X86_64Triples = [
    "x86_64-linux-gnu", "x86_64-unknown-linux-gnu", "x86_64-pc-linux-gnu",
    "x86_64-redhat-linux6E", "x86_64-redhat-linux", "x86_64-suse-linux",
    "x86_64-manbo-linux-gnu", "x86_64-linux-gnu", "x86_64-slackware-linux",
    "x86_64-linux-android", "x86_64-unknown-linux"
    ]

    const Prefixes = ["/usr"]

    Version = v"0.0.0"
    Path = VersionString = Triple = ""
    for prefix in Prefixes
        isdir(prefix) || continue
        for dir in X86_64LibDirs
            isdir(prefix) || continue
            for triple in X86_64Triples
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

    addHeaderDir(incpath, kind = C_System)
    addHeaderDir(incpath * "/" * Triple * "/c++/" * VersionString, kind = C_System)
    addHeaderDir(incpath * "/c++/" * VersionString, kind = C_System)
    addHeaderDir(incpath * "/" * Triple, kind = C_System)
end

@linux_only begin
    AddLinuxHeaderPaths()
    addHeaderDir("/usr/include", kind = C_System);
end

@windows_only begin
      base = "C:/mingw-builds/x64-4.8.1-win32-seh-rev5/mingw64/"
      addHeaderDir(joinpath(base,"x86_64-w64-mingw32/include"), kind = C_System)
      #addHeaderDir(joinpath(base,"lib/gcc/x86_64-w64-mingw32/4.8.1/include/"), kind = C_System)
      addHeaderDir(joinpath(base,"lib/gcc/x86_64-w64-mingw32/4.8.1/include/c++"), kind = C_System)
      addHeaderDir(joinpath(base,"lib/gcc/x86_64-w64-mingw32/4.8.1/include/c++/x86_64-w64-mingw32"), kind = C_System)
end

# Also add clang's intrinsic headers
addHeaderDir(joinpath(basepath,"usr/lib/clang/3.6.0/include/"), kind = C_ExternCSystem)

# __dso_handle is usually added by the linker when not present. However, since
# we're not passing through a linker, we need to add it ourselves.
cxxparse("""
#include <stdint.h>
extern "C" {
    void __dso_handle() {}
}
""")

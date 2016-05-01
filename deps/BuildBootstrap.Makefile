JULIAHOME := $(subst \,/,$(BASE_JULIA_HOME))/../..
include $(JULIAHOME)/deps/Versions.make
include $(JULIAHOME)/Make.inc

CXXJL_CPPFLAGS = -I$(build_includedir) \
		-I$(JULIAHOME)/src/support \
		-I$(call exec,$(LLVM_CONFIG) --includedir) \
		-I$(JULIAHOME)/deps/srccache/llvm-$(LLVM_VER)/tools/clang/lib \
		-I$(JULIAHOME)/deps/llvm-$(LLVM_VER)/tools/clang/lib

FLAGS = -std=c++11 $(CPPFLAGS) $(CFLAGS) $(CXXJL_CPPFLAGS)

ifneq ($(USEMSVC), 1)
CPP_STDOUT := $(CPP) -P
else
CPP_STDOUT := $(CPP) -E
endif

JULIA_LDFLAGS = -L$(build_shlibdir) -L$(build_libdir)

CLANG_LIBS = -lclangFrontendTool -lclangBasic -lclangLex -lclangDriver -lclangFrontend -lclangParse \
    -lclangAST -lclangASTMatchers -lclangSema -lclangAnalysis -lclangEdit \
    -lclangRewriteFrontend -lclangRewrite -lclangSerialization -lclangStaticAnalyzerCheckers \
    -lclangStaticAnalyzerCore -lclangStaticAnalyzerFrontend -lclangTooling -lclangToolingCore \
    -lclangCodeGen -lclangARCMigrate

LLDB_LIBS = -llldbBreakpoint -llldbCommands -llldbCore -llldbInitialization \
    -llldbDataFormatters -llldbExpression -llldbHost  \
    -llldbBase -llldbInterpreter  \
    -llldbPluginABISysV_x86_64 -llldbPluginABISysV_i386 -llldbPluginABISysV_ppc -llldbPluginABISysV_ppc64 -llldbPluginDisassemblerLLVM \
    -llldbPluginABISysV_arm -llldbPluginABISysV_arm64 -llldbPluginABISysV_mips -llldbPluginABISysV_mips64 \
    -llldbPluginDynamicLoaderPosixDYLD -llldbPluginDynamicLoaderStatic -llldbPluginInstructionARM \
    -llldbPluginDynamicLoaderMacOSXDYLD -llldbPluginDynamicLoaderWindowsDYLD \
    -llldbPluginInstructionMIPS64 -llldbPluginInstructionMIPS \
    -llldbPluginInstructionARM64 -llldbPluginJITLoaderGDB -llldbPluginCXXItaniumABI \
    -llldbPluginObjectFileELF -llldbPluginObjectFileJIT -llldbPluginObjectContainerBSDArchive \
    -llldbPluginObjectContainerMachOArchive \
    -llldbPluginObjectFilePECOFF -llldbPluginOSPython \
    -llldbPluginPlatformFreeBSD -llldbPluginPlatformGDB -llldbPluginPlatformLinux \
    -llldbPluginPlatformPOSIX -llldbPluginPlatformWindows -llldbPluginPlatformKalimba \
    -llldbPluginPlatformMacOSX  -llldbPluginAppleObjCRuntime \
    -llldbPluginProcessElfCore -llldbPluginProcessGDBRemote -llldbPluginMemoryHistoryASan \
    -llldbPluginSymbolFileDWARF -llldbPluginSymbolFileSymtab -llldbPluginSymbolVendorELF -llldbSymbol -llldbUtility \
    -llldbPluginSystemRuntimeMacOSX \
    -llldbPluginUnwindAssemblyInstEmulation -llldbPluginUnwindAssemblyX86 -llldbTarget \
    -llldbPluginInstrumentationRuntimeAddressSanitizer -llldbPluginPlatformAndroid \
    -llldbPluginRenderScriptRuntime \
    $(call exec,$(LLVM_CONFIG) --system-libs)

ifeq ($(LLVM_VER),svn)
LLDB_LIBS += -llldbPluginProcessUtility \
    -llldbPluginScriptInterpreterNone \
    -llldbPluginObjCLanguage \
    -llldbPluginCPlusPlusLanguage \
    -llldbPluginObjCPlusPlusLanguage \
    -llldbPluginExpressionParserClang \
    -llldbPluginOSGo -llldbPluginLanguageRuntimeGo -llldbPluginGoLanguage \
    -llldbPluginExpressionParserGo \
    $(call exec,$(LLVM_CONFIG) --system-libs)
else
LLDB_LIBS += -llldbPluginUtility
endif

LLDB_LIBS += -llldbPluginABIMacOSX_arm -llldbPluginABIMacOSX_arm64 -llldbPluginABIMacOSX_i386
ifeq ($(OS), Darwin)
LLDB_LIBS += -F/System/Library/Frameworks -F/System/Library/PrivateFrameworks -framework DebugSymbols \
	-llldbPluginPlatformAndroid \
    -llldbPluginDynamicLoaderDarwinKernel \
    -llldbPluginProcessDarwin  -llldbPluginProcessMachCore \
    -llldbPluginSymbolVendorMacOSX  -llldbPluginObjectFileMachO \
    -framework Security -lpanel -framework CoreFoundation \
    -framework Foundation -framework Carbon -lobjc -ledit -lxml2
endif
ifeq ($(EXPERIMENTAL_LLDB),1)
LLDB_LIBS +=  -llldbPluginABIMips32 -llldbPluginUnwindAssemblyMips
endif
ifeq ($(OS), WINNT)
LLDB_LIBS += -llldbPluginProcessWindows -lWs2_32
endif
ifeq ($(OS), Linux)
LLDB_LIBS += -llldbPluginProcessLinux -llldbPluginProcessPOSIX -lz -lbsd -ledit
endif

ifneq ($(LLVM_USE_CMAKE),1)
LLDB_LIBS += -llldbAPI
endif

ifeq ($(USE_LLVM_SHLIB),1)
ifeq ($(LLVM_USE_CMAKE),1)
LLVM_LIB_NAME = LLVM
else
LLVM_LIB_NAME = LLVM-$(call exec,$(LLVM_CONFIG) --version)
endif
endif
LDFLAGS += -l$(LLVM_LIB_NAME)

all: usr/lib/libcxxffi.$(SHLIB_EXT) usr/lib/libcxxffi-debug.$(SHLIB_EXT) clang_constants.jl

usr/lib:
	@mkdir -p $(CURDIR)/usr/lib/

build:
	@mkdir -p $(CURDIR)/build

LLVM_EXTRA_CPPFLAGS = 
ifneq ($(LLVM_ASSERTIONS),1)
LLVM_EXTRA_CPPFLAGS += -DLLVM_NDEBUG
endif

ifneq ($(BUILD_LLVM_CLANG),1)
$(error Cxx.jl requires Clang to be built with julia - Set BUILD_LLVM_CLANG in Make.user)
endif
ifneq ($(USE_LLVM_SHLIB),1)
$(error Cxx.jl currently requires LLVM to be built as a shared library - Set USE_LLVM_SHLIB in Make.user)
endif

build/bootstrap.o: ../src/bootstrap.cpp BuildBootstrap.Makefile | build
	@$(call PRINT_CC, $(CXX) -fno-rtti -DLIBRARY_EXPORTS -fPIC -O0 -g $(FLAGS) -c ../src/bootstrap.cpp -o $@)


LINKED_LIBS = $(CLANG_LIBS)
ifeq ($(BUILD_LLDB),1)
LINKED_LIBS += $(LLDB_LIBS)
endif

ifneq (,$(wildcard $(build_shlibdir)/libjulia.$(SHLIB_EXT)))
usr/lib/libcxxffi.$(SHLIB_EXT): build/bootstrap.o $(build_libdir)/lib$(LLVM_LIB_NAME).$(SHLIB_EXT) | usr/lib
	@$(call PRINT_LINK, $(CXX) -shared -fPIC $(JULIA_LDFLAGS) -ljulia $(LDFLAGS) -o $@ $(WHOLE_ARCHIVE) $(LINKED_LIBS) $(NO_WHOLE_ARCHIVE) $< )
	@cp usr/lib/libcxxffi.$(SHLIB_EXT) $(build_shlibdir)
else
usr/lib/libcxxffi.$(SHLIB_EXT):
	@echo "Not building release library because corresponding julia RELEASE library does not exist."
	@echo "To build, simply run the build again once the library at"
	@echo $(build_libdir)/libjulia.$(SHLIB_EXT)
	@echo "has been built."
endif

ifneq (,$(wildcard $(build_shlibdir)/libjulia-debug.$(SHLIB_EXT)))
usr/lib/libcxxffi-debug.$(SHLIB_EXT): build/bootstrap.o | usr/lib
	@$(call PRINT_LINK, $(CXX) -shared -fPIC $(JULIA_LDFLAGS) -ljulia-debug $(LDFLAGS) -o $@ $(WHOLE_ARCHIVE) $(LINKED_LIBS) $(NO_WHOLE_ARCHIVE) $< )
else
usr/lib/libcxxffi-debug.$(SHLIB_EXT):
	@echo "Not building debug library because corresponding julia DEBUG library does not exist."
	@echo "To build, simply run the build again once the library at"
	@echo $(build_libdir)/libjulia-debug.$(SHLIB_EXT)
	@echo "has been built."
endif

clang_constants.jl: ../src/cenumvals.jl.h usr/lib/libcxxffi.$(SHLIB_EXT)
	@$(call PRINT_PERL, $(CPP_STDOUT) $(CXXJL_CPPFLAGS) -DJULIA ../src/cenumvals.jl.h > $@)

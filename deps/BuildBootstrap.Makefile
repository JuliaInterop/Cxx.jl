JULIAHOME = $(JULIA_HOME)/../..
include $(JULIAHOME)/deps/Versions.make
include $(JULIAHOME)/Make.inc

FLAGS = -std=c++11 $(CPPFLAGS) $(CFLAGS) -I$(build_includedir) \
		-I$(JULIAHOME)/src/support \
		-I$(call exec,$(LLVM_CONFIG) --includedir) \
		-I$(JULIAHOME)/deps/llvm-$(LLVM_VER)/tools/clang/lib

JULIA_LDFLAGS = -L$(build_libdir) -ljulia

CLANG_LIBS = -lclangFrontendTool -lclangBasic -lclangLex -lclangDriver -lclangFrontend -lclangParse \
    -lclangAST -lclangASTMatchers -lclangSema -lclangAnalysis -lclangEdit \
    -lclangRewriteFrontend -lclangRewriteCore -lclangSerialization -lclangStaticAnalyzerCheckers \
    -lclangStaticAnalyzerCore -lclangStaticAnalyzerFrontend -lclangTooling \
    -lclangCodeGen -lclangARCMigrate

LLDB_LIBS = -llldbAPI -llldbBreakpoint -llldbCommands -llldbCore \
    -llldbDataFormatters -llldbExpression -llldbHostCommon -llldbHostMacOSX \
    -llldbInitAndLog -llldbInterpreter -llldbPluginABIMacOSX_arm -llldbPluginABIMacOSX_arm64 -llldbPluginABIMacOSX_i386 \
    -llldbPluginABISysV_x86_64 -llldbPluginDisassemblerLLVM -llldbPluginDynamicLoaderDarwinKernel -llldbPluginDynamicLoaderMacOSX \
    -llldbPluginDynamicLoaderPOSIX -llldbPluginDynamicLoaderStatic -llldbPluginEmulateInstructionARM \
    -llldbPluginEmulateInstructionARM64 -llldbPluginJITLoaderGDB -llldbPluginLanguageRuntimeCPlusPlusItaniumABI \
    -llldbPluginLanguageRuntimeObjCAppleObjCRuntime -llldbPluginObjectContainerBSDArchive \
    -llldbPluginObjectContainerUniversalMachO -llldbPluginObjectFileELF -llldbPluginObjectFileJIT \
    -llldbPluginObjectFileMachO -llldbPluginObjectFilePECOFF -llldbPluginOperatingSystemPython \
    -llldbPluginPlatformFreeBSD -llldbPluginPlatformGDBServer -llldbPluginPlatformLinux \
    -llldbPluginPlatformMacOSX -llldbPluginPlatformPOSIX -llldbPluginPlatformWindows \
    -llldbPluginProcessDarwin -llldbPluginProcessElfCore -llldbPluginProcessGDBRemote \
    -llldbPluginProcessMachCore -llldbPluginSymbolFileDWARF -llldbPluginSymbolFileSymtab \
    -llldbPluginSymbolVendorELF -llldbPluginSymbolVendorMacOSX -llldbPluginSystemRuntimeMacOSX \
    -llldbPluginUnwindAssemblyInstEmulation -llldbPluginUnwindAssemblyx86 -llldbPluginUtility \
    -F/System/Library/Frameworks -F/System/Library/PrivateFrameworks -framework DebugSymbols \
    -llldbSymbol -llldbTarget -llldbUtility -framework Security -lxml2 -lcurses -lpanel -framework CoreFoundation \
    -framework Foundation -framework Carbon -lobjc

all: usr/lib/libcxxffi.$(SHLIB_EXT)

usr/lib:
	@mkdir -p $(CURDIR)/usr/lib/

build:
	@mkdir -p $(CURDIR)/build

build/bootstrap.o: ../src/bootstrap.cpp BuildBootstrap.Makefile | build
	@$(call PRINT_CC, $(CXX) -fno-rtti -fPIC $(FLAGS) -c ../src/bootstrap.cpp -o $@)

usr/lib/libcxxffi.$(SHLIB_EXT): build/bootstrap.o | usr/lib
	@$(call PRINT_LINK, $(CXX) -shared -fPIC $(JULIA_LDFLAGS) $(LDFLAGS) $(CLANG_LIBS) $< -o $@)

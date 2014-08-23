JULIAHOME = $(subst \,/,$(JULIA_HOME))/../..
include $(JULIAHOME)/deps/Versions.make
include $(JULIAHOME)/Make.inc

FLAGS = -std=c++11 $(CPPFLAGS) $(CFLAGS) -I$(build_includedir) \
		-I$(JULIAHOME)/src/support \
		-I$(call exec,$(LLVM_CONFIG) --includedir) \
		-I$(JULIAHOME)/deps/llvm-$(LLVM_VER)/tools/clang/lib

JULIA_LDFLAGS = -L$(build_shlibdir) -L$(build_libdir)

CLANG_LIBS = -lclangFrontendTool -lclangBasic -lclangLex -lclangDriver -lclangFrontend -lclangParse \
    -lclangAST -lclangASTMatchers -lclangSema -lclangAnalysis -lclangEdit \
    -lclangRewriteFrontend -lclangRewrite -lclangSerialization -lclangStaticAnalyzerCheckers \
    -lclangStaticAnalyzerCore -lclangStaticAnalyzerFrontend -lclangTooling \
    -lclangCodeGen -lclangARCMigrate

LLDB_LIBS = -llldbAPI -llldbBreakpoint -llldbCommands -llldbCore \
    -llldbDataFormatters -llldbExpression -llldbHostCommon  \
    -llldbInitAndLog -llldbInterpreter  \
    -llldbPluginABISysV_x86_64 -llldbPluginDisassemblerLLVM \
    -llldbPluginDynamicLoaderPOSIX -llldbPluginDynamicLoaderStatic -llldbPluginEmulateInstructionARM \
    -llldbPluginEmulateInstructionARM64 -llldbPluginJITLoaderGDB -llldbPluginLanguageRuntimeCPlusPlusItaniumABI \
    -llldbPluginObjectFileELF -llldbPluginObjectFileJIT -llldbPluginObjectContainerBSDArchive \
    -llldbPluginObjectFilePECOFF -llldbPluginOperatingSystemPython \
    -llldbPluginPlatformFreeBSD -llldbPluginPlatformGDBServer -llldbPluginPlatformLinux \
    -llldbPluginPlatformPOSIX -llldbPluginPlatformWindows -llldbPluginPlatformKalimba \
    -llldbPluginPlatformMacOSX  -llldbPluginLanguageRuntimeObjCAppleObjCRuntime \
    -llldbPluginProcessElfCore -llldbPluginProcessGDBRemote \
    -llldbPluginSymbolFileDWARF -llldbPluginSymbolFileSymtab -llldbPluginSymbolVendorELF -llldbSymbol -llldbUtility \
    -llldbPluginUnwindAssemblyInstEmulation -llldbPluginUnwindAssemblyx86 -llldbPluginUtility -llldbTarget \
    $(call exec,$(LLVM_CONFIG) --system-libs)
LLDB_LIBS += -llldbPluginABIMacOSX_arm -llldbPluginABIMacOSX_arm64 -llldbPluginABIMacOSX_i386
ifeq ($(OS), Darwin)
LLDB_LIBS += -F/System/Library/Frameworks -F/System/Library/PrivateFrameworks -framework DebugSymbols -llldbHostMacOSX \
	-llldbHostPOSIX \
    -llldbPluginDynamicLoaderMacOSX -llldbPluginDynamicLoaderDarwinKernel -llldbPluginObjectContainerUniversalMachO \
    -llldbPluginProcessDarwin  -llldbPluginProcessMachCore \
    -llldbPluginSymbolVendorMacOSX -llldbPluginSystemRuntimeMacOSX -llldbPluginObjectFileMachO \
    -framework Security  -lpanel -framework CoreFoundation \
    -framework Foundation -framework Carbon -lobjc -ledit -lxml2
endif
ifeq ($(OS), WINNT)
LLDB_LIBS += -llldbHostWindows -llldbPluginProcessWindows -lWs2_32
endif
ifeq ($(OS), Linux)
LLDB_LIBS += -llldbHostLinux -llldbPluginProcessLinux -llldbPluginProcessPOSIX
endif


ifeq ($(USE_LLVM_SHLIB),1)
LDFLAGS += -lLLVM-$(call exec,$(LLVM_CONFIG) --version)
endif


all: usr/lib/libcxxffi.$(SHLIB_EXT) usr/lib/libcxxffi-debug.$(SHLIB_EXT)

usr/lib:
	@mkdir -p $(CURDIR)/usr/lib/

build:
	@mkdir -p $(CURDIR)/build

build/bootstrap.o: ../src/bootstrap.cpp BuildBootstrap.Makefile | build
	@$(call PRINT_CC, $(CXX) -fno-rtti -DLIBRARY_EXPORTS -fPIC -O0 -g $(FLAGS) -c ../src/bootstrap.cpp -o $@)


ifneq (,$(wildcard $(build_shlibdir)/libjulia.$(SHLIB_EXT)))
usr/lib/libcxxffi.$(SHLIB_EXT): build/bootstrap.o | usr/lib
	@$(call PRINT_LINK, $(CXX) -shared -fPIC $(JULIA_LDFLAGS) -ljulia $(LDFLAGS) -o $@ $(WHOLE_ARCHIVE) $(CLANG_LIBS) $(LLDB_LIBS) $(NO_WHOLE_ARCHIVE) $< )
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
	@$(call PRINT_LINK, $(CXX) -shared -fPIC $(JULIA_LDFLAGS) -ljulia-debug $(LDFLAGS) -o $@ $(WHOLE_ARCHIVE) $(CLANG_LIBS) $(LLDB_LIBS) $(NO_WHOLE_ARCHIVE) $< )
else
usr/lib/libcxxffi-debug.$(SHLIB_EXT):
	@echo "Not building debug library because corresponding julia DEBUG library does not exist."
	@echo "To build, simply run the build again once the library at"
	@echo $(build_libdir)/libjulia-debug.$(SHLIB_EXT)
	@echo "has been built."
endif

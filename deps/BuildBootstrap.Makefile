# Cxx source build
# download sources
LLVM_VER := 6.0.1
LLVM_URL_PREFIX := http://releases.llvm.org/$(LLVM_VER)
LLVM_TAR := llvm-$(LLVM_VER).src.tar.xz
CLANG_TAR := cfe-$(LLVM_VER).src.tar.xz
COMPILER_RT_TAR := compiler-rt-$(LLVM_VER).src.tar.xz
LIBCXX_TAR := libcxx-$(LLVM_VER).src.tar.xz
LIBCXXABI_TAR := libcxxabi-$(LLVM_VER).src.tar.xz
POLLY_TAR := polly-$(LLVM_VER).src.tar.xz
LIBUNWIND_TAR := libunwind-$(LLVM_VER).src.tar.xz
LLD_TAR := lld-$(LLVM_VER).src.tar.xz

TIMEOUT := 180
CURL := curl -fkL --connect-timeout $(TIMEOUT) -y $(TIMEOUT)

usr/download:
	@[ -d usr ] || mkdir usr
	mkdir $@

LLVM_TARS := $(LLVM_TAR) $(CLANG_TAR) $(COMPILER_RT_TAR) $(LIBCXX_TAR) $(LIBCXXABI_TAR) $(POLLY_TAR) $(LIBUNWIND_TAR) $(LLD_TAR)

llvm_tars: usr/download
	@for tar in $(LLVM_TARS); do \
		if [[ -e $</$$tar ]]; then \
    		echo "$$tar already exists, please delete it manually if you'd like to re-download it."; \
		else \
    		$(CURL) -o $</$$tar $(LLVM_URL_PREFIX)/$$tar ; \
		fi \
	done

# unzip
usr/src: usr/download
	mkdir $@

llvm-$(LLVM_VER): usr/src llvm_tars
	@[ -d $</$@ ] || mkdir -p $</$@
	tar -C $</$@ --strip-components=1 -xf usr/download/$(LLVM_TAR)
	@[ -d $</$@/tools/clang ] || mkdir -p $</$@/tools/clang
	tar -C $</$@/tools/clang --strip-components=1 -xf usr/download/$(CLANG_TAR)
	@[ -d $</$@/tools/polly ] || mkdir -p $</$@/tools/polly
	tar -C $</$@/tools/polly --strip-components=1 -xf usr/download/$(POLLY_TAR)
	@[ -d $</$@/tools/lld ] || mkdir -p $</$@/tools/lld
	tar -C $</$@/tools/lld --strip-components=1 -xf usr/download/$(LLD_TAR)
	@[ -d $</$@/projects/compiler-rt ] || mkdir -p $</$@/projects/compiler-rt
	tar -C $</$@/projects/compiler-rt --strip-components=1 -xf usr/download/$(COMPILER_RT_TAR)
	@[ -d $</$@/projects/libcxx ] || mkdir -p $</$@/projects/libcxx
	tar -C $</$@/projects/libcxx --strip-components=1 -xf usr/download/$(LIBCXX_TAR)
	@[ -d $</$@/projects/libcxxabi ] || mkdir -p $</$@/projects/libcxxabi
	tar -C $</$@/projects/libcxxabi --strip-components=1 -xf usr/download/$(LIBCXXABI_TAR)
	@[ -d $</$@/projects/libunwind ] || mkdir -p $</$@/projects/libunwind
	tar -C $</$@/projects/libunwind --strip-components=1 -xf usr/download/$(LIBUNWIND_TAR)

# apply patches
llvm-patched: llvm-$(LLVM_VER)
	cd usr/src/$< && \
	for p in ../../../llvm_patches/*.patch; do \
		echo "Applying patch $$p"; \
		patch -p1 < $$p ; \
	done

# build libcxxffi
include Make.inc

JULIA_SRC := $(subst \,/,$(BASE_JULIA_SRC))
JULIA_BIN := $(subst \,/,$(BASE_JULIA_BIN))

ifeq ($(OLD_CXX_ABI),1)
CXX_ABI_SETTING=-D_GLIBCXX_USE_CXX11_ABI=0
else
CXX_ABI_SETTING=-D_GLIBCXX_USE_CXX11_ABI=1
endif

JULIA_SOURCE_INCLUDE_DIRS := $(JULIA_SRC)/src/support
JULIA_INCLUDE_DIRS := $(JULIA_BIN)/../include
CLANG_SOURCE_INCLUDE_DIRS := usr/src/llvm-$(LLVM_VER)/tools/clang/include
CLANG_SOURCE_INCLUDE_DIRS += usr/src/llvm-$(LLVM_VER)/tools/clang/lib
CLANG_INCLUDE_DIRS := $(JULIA_BIN)/../include $(JULIA_BIN)/../include/clang
INCLUDE_DIRS := $(JULIA_SOURCE_INCLUDE_DIRS) $(JULIA_INCLUDE_DIRS) $(CLANG_SOURCE_INCLUDE_DIRS) $(CLANG_INCLUDE_DIRS)
CXXJL_CPPFLAGS = $(addprefix -I, $(INCLUDE_DIRS))

CLANG_LIBS := clangFrontendTool clangBasic clangLex clangDriver clangFrontend clangParse
CLANG_LIBS += clangAST clangASTMatchers clangSema clangAnalysis clangEdit
CLANG_LIBS += clangRewriteFrontend clangRewrite clangSerialization clangStaticAnalyzerCheckers
CLANG_LIBS += clangStaticAnalyzerCore clangStaticAnalyzerFrontend clangTooling clangToolingCore
CLANG_LIBS += clangCodeGen clangARCMigrate clangFormat
LINKED_LIBS = $(addprefix -l,$(CLANG_LIBS))

LIB_DIRS := $(JULIA_BIN)/../lib
LIB_DIRS += $(JULIA_BIN)/../lib/julia
ifneq ($(USEMSVC), 1)
LIB_DIRS += $(JULIA_BIN)
endif
JULIA_LDFLAGS = $(addprefix -L,$(LIB_DIRS))
# JULIA_LDFLAGS += -Lbuild/clang-$(LLVM_VER)/lib


FLAGS = -std=c++11 $(CPPFLAGS) $(CFLAGS) $(CXXJL_CPPFLAGS)

ifneq ($(USEMSVC), 1)
CPP_STDOUT := $(CPP) -P
else
CPP_STDOUT := $(CPP) -E
endif

LLVM_LIB_NAME := LLVM
LDFLAGS += -l$(LLVM_LIB_NAME)
LIB_DEPENDENCY += $(JULIA_BIN)/../lib/lib$(LLVM_LIB_NAME).$(SHLIB_EXT)
LLVM_EXTRA_CPPFLAGS = -DLLVM_NDEBUG
JULIA_LIB := $(JULIA_BIN)/../lib/libjulia.dylib
JULIA_DEBUG_LIB := $(JULIA_BIN)/../lib/libjulia-debug.dylib

all: usr/lib/libcxxffi.$(SHLIB_EXT) usr/lib/libcxxffi-debug.$(SHLIB_EXT) usr/clang_constants.jl

usr/lib: usr/src
	mkdir $@

usr/lib/bootstrap.o: ../src/bootstrap.cpp BuildBootstrap.Makefile $(LIB_DEPENDENCY) llvm-patched | usr/lib
	@$(call PRINT_CC, $(CXX) $(CXX_ABI_SETTING) -fno-rtti -DLIBRARY_EXPORTS -fPIC -O0 -g $(FLAGS) $(LLVM_EXTRA_CPPFLAGS) -c ../src/bootstrap.cpp -o $@)

ifneq (,$(wildcard $(JULIA_LIB)))
usr/lib/libcxxffi.$(SHLIB_EXT): usr/lib/bootstrap.o $(LIB_DEPENDENCY) | usr/lib
	@$(call PRINT_LINK, $(CXX) -shared -fPIC $(JULIA_LDFLAGS) -ljulia $(LDFLAGS) -o $@ $(WHOLE_ARCHIVE) $(LINKED_LIBS) $(NO_WHOLE_ARCHIVE) $< )
else
usr/lib/libcxxffi.$(SHLIB_EXT):
	@echo "Not building release library because corresponding julia RELEASE library does not exist."
	@echo "To build, simply run the build again once the library at"
	@echo $(JULIA_LIB)
	@echo "has been built."
endif

ifneq (,$(wildcard $(JULIA_DEBUG_LIB)))
usr/lib/libcxxffi-debug.$(SHLIB_EXT): build/bootstrap.o $(LIB_DEPENDENCY) | usr/lib
	@$(call PRINT_LINK, $(CXX) -shared -fPIC $(JULIA_LDFLAGS) -ljulia-debug $(LDFLAGS) -o $@ $(WHOLE_ARCHIVE) $(LINKED_LIBS) $(NO_WHOLE_ARCHIVE) $< )
else
usr/lib/libcxxffi-debug.$(SHLIB_EXT):
	@echo "Not building debug library because corresponding julia DEBUG library does not exist."
	@echo "To build, simply run the build again once the library at"
	@echo $(JULIA_DEBUG_LIB)
	@echo "has been built."
endif

usr/clang_constants.jl: ../src/cenumvals.jl.h usr/lib/libcxxffi.$(SHLIB_EXT)
	@$(call PRINT_PERL, $(CPP_STDOUT) $(CXXJL_CPPFLAGS) -DJULIA ../src/cenumvals.jl.h > $@)

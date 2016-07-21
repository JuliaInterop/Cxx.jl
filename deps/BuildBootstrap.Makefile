JULIAHOME := $(subst \,/,$(BASE_JULIA_HOME))/../..

ifeq ($(LLVM_VER),)
include $(JULIAHOME)/deps/Versions.make
include $(JULIAHOME)/Make.user
endif
include Make.inc

all: usr/lib/libcxxffi.$(SHLIB_EXT) usr/lib/libcxxffi-debug.$(SHLIB_EXT) build/clang_constants.jl


CXXJL_CPPFLAGS = -I$(JULIAHOME)/src/support -I$(BASE_JULIA_HOME)/../include

ifeq ($(JULIA_BINARY_BUILD),1)
LIBDIR := $(BASE_JULIA_HOME)/../lib/julia
else
LIBDIR := $(BASE_JULIA_HOME)/../lib
endif

CLANG_LIBS = clangFrontendTool clangBasic clangLex clangDriver clangFrontend clangParse \
	clangAST clangASTMatchers clangSema clangAnalysis clangEdit \
	clangRewriteFrontend clangRewrite clangSerialization clangStaticAnalyzerCheckers \
	clangStaticAnalyzerCore clangStaticAnalyzerFrontend clangTooling clangToolingCore \
	clangCodeGen clangARCMigrate clangFormat

# If clang is not built by base julia, build it ourselves 
ifeq ($(BUILD_LLVM_CLANG),)
ifeq ($(LLVM_VER),svn)
$(error For julia built against llvm-svn, please built clang in tree)
endif

LLVM_TAR_EXT:=$(LLVM_VER).src.tar.xz
LLVM_CLANG_TAR:=src/cfe-$(LLVM_TAR_EXT)
LLVM_SRC_TAR:=src/llvm-$(LLVM_TAR_EXT)
LLVM_COMPILER_RT_TAR:=src/compiler-rt-$(LLVM_TAR_EXT)
LLVM_SRC_URL := http://llvm.org/releases/$(LLVM_VER)

src:
	mkdir $@

# Also build a new copy of LLVM, so we get headers, tools, etc.
ifeq ($(JULIA_BINARY_BUILD),1)
LLVM_SRC_DIR := src/llvm-$(LLVM_VER)
include llvm-patches/apply-llvm-patches.mk
$(LLVM_SRC_TAR): | src
	curl -o $@ $(LLVM_SRC_URL)/$(notdir $@)
src/llvm-$(LLVM_VER): $(LLVM_SRC_TAR)
	mkdir -p $@
	tar -C $@ --strip-components=1 -xf $<
build/llvm-$(LLVM_VER)/Makefile: src/llvm-$(LLVM_VER) $(LLVM_PATCH_LIST)
	mkdir -p $(dir $@)
	cd $(dir $@) && \
		cmake -G "Unix Makefiles"  -DLLVM_TARGETS_TO_BUILD="X86" \
		 	-DLLVM_BUILD_LLVM_DYLIB=ON -DCMAKE_BUILD_TYPE=Release \
			-DLLVM_LINK_LLVM_DYLIB=ON -DLLVM_ENABLE_THREADS=OFF \
			-DCMAKE_CXX_COMPILER_ARG1="-D_GLIBCXX_USE_CXX11_ABI=0" \
			../../src/llvm-$(LLVM_VER)
build/llvm-$(LLVM_VER)/bin/llvm-config: build/llvm-$(LLVM_VER)/Makefile
	cd build/llvm-$(LLVM_VER) && $(MAKE)
LLVM_HEADER_DIRS = src/llvm-$(LLVM_VER)/include build/llvm-$(LLVM_VER)/include
CLANG_CMAKE_DEP = build/llvm-$(LLVM_VER)/bin/llvm-config
LLVM_CONFIG = ../llvm-$(LLVM_VER)/bin/llvm-config
else
CLANG_CMAKE_OPTS += -DLLVM_TABLEGEN_EXE=$(BASE_JULIA_HOME)/../tools/llvm-tblgen
endif

JULIA_LDFLAGS = -L$(BASE_JULIA_HOME)/../lib -L$(BASE_JULIA_HOME)/../lib/julia

$(LLVM_CLANG_TAR): | src
	curl -o $@ $(LLVM_SRC_URL)/$(notdir $@)
$(LLVM_COMPILER_RT_TAR): | src
	$(JLDOWNLOAD) $@ $(LLVM_SRC_URL)/$(notdir $@)
src/clang-$(LLVM_VER): $(LLVM_CLANG_TAR)
	mkdir -p $@
	tar -C $@ --strip-components=1 -xf $<
build/clang-$(LLVM_VER)/Makefile: src/clang-$(LLVM_VER) $(CLANG_CMAKE_DEP)
	mkdir -p $(dir $@)
	cd $(dir $@) && \
		cmake -G "Unix Makefiles" \
			-DLLVM_BUILD_LLVM_DYLIB=ON -DCMAKE_BUILD_TYPE=Release \
			-DLLVM_LINK_LLVM_DYLIB=ON -DLLVM_ENABLE_THREADS=OFF \
                        -DCMAKE_CXX_COMPILER_ARG1="-D_GLIBCXX_USE_CXX11_ABI=0" \
			-DLLVM_CONFIG=$(LLVM_CONFIG) $(CLANG_CMAKE_OPTS) ../../src/clang-$(LLVM_VER)
build/clang-$(LLVM_VER)/lib/libclangCodeGen.a: build/clang-$(LLVM_VER)/Makefile
	cd build/clang-$(LLVM_VER) && $(MAKE)
LIB_DEPENDENCY += build/clang-$(LLVM_VER)/lib/libclangCodeGen.a
JULIA_LDFLAGS += -Lbuild/clang-$(LLVM_VER)/lib
CXXJL_CPPFLAGS += -Isrc/clang-$(LLVM_VER)/lib -Ibuild/clang-$(LLVM_VER)/include \
	-Isrc/clang-$(LLVM_VER)/include
else # BUILD_LLVM_CLANG
JULIA_LDFLAGS = -L$(BASE_JULIA_HOME)/../lib -L$(BASE_JULIA_HOME)/../lib/julia
CXXJL_CPPFLAGS += -I$(JULIAHOME)/deps/srccache/llvm-$(LLVM_VER)/tools/clang/lib \
		-I$(JULIAHOME)/deps/llvm-$(LLVM_VER)/tools/clang/lib
endif

CXX_LLVM_VER := $(LLVM_VER)
ifeq ($(CXX_LLVM_VER),svn)
CXX_LLVM_VER := $(shell $(BASE_JULIA_HOME)/../tools/llvm-config --version)
endif

ifneq ($(LLVM_HEADER_DIRS),)
CXXJL_CPPFLAGS += $(addprefix -I,$(LLVM_HEADER_DIRS))
endif

FLAGS = -std=c++11 $(CPPFLAGS) $(CFLAGS) $(CXXJL_CPPFLAGS)

ifneq ($(USEMSVC), 1)
CPP_STDOUT := $(CPP) -P
else
CPP_STDOUT := $(CPP) -E
endif


ifeq ($(LLVM_USE_CMAKE),1)
LLVM_LIB_NAME := LLVM
else ifeq ($(LLVM_VER),svn)
LLVM_LIB_NAME := LLVM
else
LLVM_LIB_NAME := LLVM-$(CXX_LLVM_VER)
endif
LDFLAGS += -l$(LLVM_LIB_NAME)

LIB_DEPENDENCY += $(LIBDIR)/lib$(LLVM_LIB_NAME).$(SHLIB_EXT)

usr/lib:
	@mkdir -p $(CURDIR)/usr/lib/

build:
	@mkdir -p $(CURDIR)/build

LLVM_EXTRA_CPPFLAGS = 
ifneq ($(LLVM_ASSERTIONS),1)
LLVM_EXTRA_CPPFLAGS += -DLLVM_NDEBUG
endif

build/bootstrap.o: ../src/bootstrap.cpp BuildBootstrap.Makefile $(LIB_DEPENDENCY) | build
	@$(call PRINT_CC, $(CXX) -D_GLIBCXX_USE_CXX11_ABI=0 -fno-rtti -DLIBRARY_EXPORTS -fPIC -O0 -g $(FLAGS) $(LLVM_EXTRA_CPPFLAGS) -c ../src/bootstrap.cpp -o $@)


LINKED_LIBS = $(addprefix -l,$(CLANG_LIBS))
ifeq ($(BUILD_LLDB),1)
LINKED_LIBS += $(LLDB_LIBS)
endif

ifneq (,$(wildcard $(BASE_JULIA_HOME)/../lib/libjulia.$(SHLIB_EXT)))
usr/lib/libcxxffi.$(SHLIB_EXT): build/bootstrap.o $(LIB_DEPENDENCY) | usr/lib
	@$(call PRINT_LINK, $(CXX) -shared -fPIC $(JULIA_LDFLAGS) -ljulia $(LDFLAGS) -o $@ $(WHOLE_ARCHIVE) $(LINKED_LIBS) $(NO_WHOLE_ARCHIVE) $< )
else
usr/lib/libcxxffi.$(SHLIB_EXT):
	@echo "Not building release library because corresponding julia RELEASE library does not exist."
	@echo "To build, simply run the build again once the library at"
	@echo $(build_libdir)/libjulia.$(SHLIB_EXT)
	@echo "has been built."
endif

ifneq (,$(wildcard $(BASE_JULIA_HOME)/../lib/libjulia-debug.$(SHLIB_EXT)))
usr/lib/libcxxffi-debug.$(SHLIB_EXT): build/bootstrap.o $(LIB_DEPENDENCY) | usr/lib
	@$(call PRINT_LINK, $(CXX) -shared -fPIC $(JULIA_LDFLAGS) -ljulia-debug $(LDFLAGS) -o $@ $(WHOLE_ARCHIVE) $(LINKED_LIBS) $(NO_WHOLE_ARCHIVE) $< )
else
usr/lib/libcxxffi-debug.$(SHLIB_EXT):
	@echo "Not building debug library because corresponding julia DEBUG library does not exist."
	@echo "To build, simply run the build again once the library at"
	@echo $(build_libdir)/libjulia-debug.$(SHLIB_EXT)
	@echo "has been built."
endif

build/clang_constants.jl: ../src/cenumvals.jl.h usr/lib/libcxxffi.$(SHLIB_EXT)
	@$(call PRINT_PERL, $(CPP_STDOUT) $(CXXJL_CPPFLAGS) -DJULIA ../src/cenumvals.jl.h > $@)

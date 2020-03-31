# Cxx source build
# download sources
LLVM_URL_PREFIX := https://github.com/llvm/llvm-project/archive/
LLVM_TAR := llvmorg-$(LLVM_VER).tar.gz

TIMEOUT := 180
CURL := curl -fkL --connect-timeout $(TIMEOUT) -y $(TIMEOUT)

usr/downloads:
	@[ -d usr ] || mkdir usr
	mkdir -p $@

LLVM_TARS := $(LLVM_TAR)

llvm_tars: usr/downloads
	@for tar in $(LLVM_TARS); do \
		if [ -e $</$$tar ]; then \
    		echo "$$tar already exists, please delete it manually if you'd like to re-download it."; \
		else \
    		$(CURL) -o $</$$tar $(LLVM_URL_PREFIX)/$$tar ; \
		fi \
	done

# unzip
usr/src: usr/downloads
	mkdir -p $@

llvm-$(LLVM_VER): usr/src llvm_tars
	@[ -d $</$@ ] || mkdir -p $</$@
	tar -C $</$@ --strip-components=1 -xf usr/downloads/$(LLVM_TAR)

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
CLANG_SOURCE_INCLUDE_DIRS := usr/src/llvm-$(LLVM_VER)/clang/include
CLANG_SOURCE_INCLUDE_DIRS += usr/src/llvm-$(LLVM_VER)/clang/lib
INCLUDE_DIRS := $(JULIA_SOURCE_INCLUDE_DIRS) $(JULIA_INCLUDE_DIRS) $(CLANG_SOURCE_INCLUDE_DIRS) $(CLANG_INCLUDE_DIRS)
CXXJL_CPPFLAGS = $(addprefix -I, $(INCLUDE_DIRS))

CLANG_LIBS := clang-cpp
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
JULIA_LIB := $(JULIA_BIN)/../lib/libjulia.$(SHLIB_EXT)
JULIA_DEBUG_LIB := $(JULIA_BIN)/../lib/libjulia-debug.$(SHLIB_EXT)

all: usr/lib/libcxxffi.$(SHLIB_EXT) usr/lib/libcxxffi-debug.$(SHLIB_EXT) usr/clang_constants.jl

usr/lib: usr/src
	mkdir $@

usr/lib/bootstrap.o: ../src/bootstrap.cpp BuildBootstrap.Makefile $(LIB_DEPENDENCY) | usr/lib
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
usr/lib/libcxxffi-debug.$(SHLIB_EXT): usr/lib/bootstrap.o $(LIB_DEPENDENCY) | usr/lib
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

# This file is extracted partly from julia
# Copyright (c) 2009-2016: Jeff Bezanson, Stefan Karpinski, Viral B. Shah, and other contributors:
# https://github.com/JuliaLang/julia/contributors

# Figure out OS and architecture
BUILD_OS := $(shell uname)

# Figure out OS and architecture
OS := $(BUILD_OS)

ifneq (,$(findstring MINGW,$(OS)))
override OS := WINNT
endif
ifneq (,$(findstring MINGW,$(BUILD_OS)))
override BUILD_OS := WINNT
endif
ifneq (,$(findstring MSYS,$(OS)))
override OS := WINNT
endif
ifneq (,$(findstring MSYS,$(BUILD_OS)))
override BUILD_OS := WINNT
endif

ifeq ($(OS), WINNT)
  SHLIB_EXT := dll
else ifeq ($(OS), Darwin)
  SHLIB_EXT := dylib
else
  SHLIB_EXT := so
endif

ifeq ($(OS), Darwin)
  WHOLE_ARCHIVE := -Xlinker -all_load
  NO_WHOLE_ARCHIVE :=
else ifneq ($(USEMSVC), 1)
  WHOLE_ARCHIVE := -Wl,--whole-archive
  NO_WHOLE_ARCHIVE := -Wl,--no-whole-archive
endif

CCCOLOR:="\033[34m"
LINKCOLOR:="\033[34;1m"
PERLCOLOR:="\033[35m"

GOAL=$(subst ','\'',$(subst $(abspath $(JULIAHOME))/,,$(abspath $@)))

ENDCOLOR:="\033[0m"

ifeq ($(VERBOSE), 0)
PRINT_CC = printf '    %b %b\n' $(CCCOLOR)CC$(ENDCOLOR) $(SRCCOLOR)$(GOAL)$(ENDCOLOR); $(1)
PRINT_LINK = printf '    %b %b\n' $(LINKCOLOR)LINK$(ENDCOLOR) $(BINCOLOR)$(GOAL)$(ENDCOLOR); $(1)
PRINT_PERL = printf '    %b %b\n' $(PERLCOLOR)PERL$(ENDCOLOR) $(BINCOLOR)$(GOAL)$(ENDCOLOR); $(1)
else
PRINT_CC = echo '$(subst ','\'',$(1))'; $(1)
PRINT_LINK = echo '$(subst ','\'',$(1))'; $(1)
PRINT_PERL = echo '$(subst ','\'',$(1))'; $(1)
endif

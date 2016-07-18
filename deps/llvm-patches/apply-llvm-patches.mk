# Compute normalized llvm version
LLVM_VER_MAJ:=$(word 1, $(subst ., ,$(LLVM_VER)))
LLVM_VER_MIN:=$(word 2, $(subst ., ,$(LLVM_VER)))
# define a "short" LLVM version for easy comparisons
ifeq ($(LLVM_VER),svn)
LLVM_VER_SHORT:=svn
else
LLVM_VER_SHORT:=$(LLVM_VER_MAJ).$(LLVM_VER_MIN)
endif
LLVM_VER_PATCH:=$(word 3, $(subst ., ,$(LLVM_VER)))
ifeq ($(LLVM_VER_PATCH),)
LLVM_VER_PATCH := 0
endif

# Apply version-specific LLVM patches
LLVM_PATCH_PREV:=
LLVM_PATCH_LIST:=
define LLVM_PATCH
$$(LLVM_SRC_DIR)/$1.patch-applied: $$(LLVM_SRC_DIR) | llvm-patches/$1.patch $$(LLVM_PATCH_PREV)
	cd $$(LLVM_SRC_DIR) && patch -p1 < ../../llvm-patches/$1.patch
	echo 1 > $$@
LLVM_PATCH_PREV := $$(LLVM_SRC_DIR)/$1.patch-applied
LLVM_PATCH_LIST += $$(LLVM_PATCH_PREV)
endef
ifeq ($(LLVM_VER),3.3)
$(eval $(call LLVM_PATCH,llvm-3.3))
$(eval $(call LLVM_PATCH,instcombine-llvm-3.3))
$(eval $(call LLVM_PATCH,int128-vector.llvm-3.3))
$(eval $(call LLVM_PATCH,osx-10.10.llvm-3.3))
$(eval $(call LLVM_PATCH,win64-int128.llvm-3.3))
else ifeq ($(LLVM_VER_SHORT),3.7)
ifeq ($(LLVM_VER),3.7.0)
$(eval $(call LLVM_PATCH,llvm-3.7.0))
endif
$(eval $(call LLVM_PATCH,llvm-3.7.1))
$(eval $(call LLVM_PATCH,llvm-3.7.1_2))
$(eval $(call LLVM_PATCH,llvm-3.7.1_3))
$(eval $(call LLVM_PATCH,llvm-3.7.1_symlinks))
$(eval $(call LLVM_PATCH,llvm-3.8.0_bindir))
$(eval $(call LLVM_PATCH,llvm-D14260))
$(eval $(call LLVM_PATCH,llvm-nodllalias))
$(eval $(call LLVM_PATCH,llvm-D21271-instcombine-tbaa-3.7))
$(eval $(call LLVM_PATCH,llvm-win64-reloc-dwarf))
else ifeq ($(LLVM_VER_SHORT),3.8)
ifeq ($(LLVM_VER),3.8.0)
$(eval $(call LLVM_PATCH,llvm-D17326_unpack_load))
endif
$(eval $(call LLVM_PATCH,llvm-3.7.1_3)) # Remove for 3.9
$(eval $(call LLVM_PATCH,llvm-D14260))
$(eval $(call LLVM_PATCH,llvm-3.8.0_bindir)) # Remove for 3.9
$(eval $(call LLVM_PATCH,llvm-3.8.0_winshlib)) # Remove for 3.9
$(eval $(call LLVM_PATCH,llvm-nodllalias)) # Remove for 3.9
# Cygwin and openSUSE still use win32-threads mingw, https://llvm.org/bugs/show_bug.cgi?id=26365
$(eval $(call LLVM_PATCH,llvm-3.8.0_threads))
# fix replutil test on unix
$(eval $(call LLVM_PATCH,llvm-D17165-D18583)) # Remove for 3.9
# Segfault for aggregate load
$(eval $(call LLVM_PATCH,llvm-D17712)) # Remove for 3.9
$(eval $(call LLVM_PATCH,llvm-PR26180)) # Remove for 3.9
$(eval $(call LLVM_PATCH,llvm-PR27046)) # Remove for 3.9
$(eval $(call LLVM_PATCH,llvm-3.8.0_ppc64_SUBFC8)) # Remove for 3.9
$(eval $(call LLVM_PATCH,llvm-D21271-instcombine-tbaa-3.8)) # Remove for 3.9
$(eval $(call LLVM_PATCH,llvm-win64-reloc-dwarf))
endif # LLVM_VER

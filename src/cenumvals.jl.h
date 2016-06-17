count = 0
#include "llvm/Config/llvm-config.h"
#if defined(LLVM_VERSION_MAJOR) && LLVM_VERSION_MAJOR == 3 && LLVM_VERSION_MINOR >= 9
#define IMAGE_TYPE(ImgType, Id, SingletonId, Access, Suffix) const c ## Id = (count += 1; count - 1)
#include "clang/Basic/OpenCLImageTypes.def"
#endif
#define BUILTIN_TYPE(Id, SingletonId) const c ## Id = (count += 1; count - 1)
#define LAST_BUILTIN_TYPE(Id)
#include "clang/AST/BuiltinTypes.def"

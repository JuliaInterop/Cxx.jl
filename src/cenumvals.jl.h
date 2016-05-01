count = 0
#define IMAGE_TYPE(ImgType, Id, SingletonId, Access, Suffix) const c ## Id = (count += 1; count - 1)
#include "clang/Basic/OpenCLImageTypes.def"
#define BUILTIN_TYPE(Id, SingletonId) const c ## Id = (count += 1; count - 1)
#define LAST_BUILTIN_TYPE(Id)
#include "clang/AST/BuiltinTypes.def"

#define __STDC_CONSTANT_MACROS
#define __STDC_LIMIT_MACROS
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/BitCode/ReaderWriter.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/CFG.h"
#include "llvm/Support/GraphWriter.h"
#include "llvm/ExecutionEngine/ExecutionEngine.h"
#include "lib/CodeGen/CGValue.h"
#include "lib/CodeGen/CodeGenTypes.h"
#include "clang/AST/DeclBase.h"
#include "clang/AST/Type.h"
#include "clang/Basic/SourceLocation.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/AST/DeclTemplate.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/Analysis/CallGraph.h"
#define LLDB_DISABLE_PYTHON // NO!
#include "/Users/kfischer/julia-upstream/deps/llvm-svn/tools/lldb/include/lldb/Interpreter/CommandInterpreter.h"
#include "/Users/kfischer/julia-upstream/deps/llvm-svn/tools/lldb/include/lldb/Interpreter/CommandReturnObject.h"
#include <string>
namespace clang {
namespace CodeGen {
typedef llvm::IRBuilder<false> CGBuilderTy;
};
};

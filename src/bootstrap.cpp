#undef B0 //rom termios
#define __STDC_LIMIT_MACROS
#define __STDC_CONSTANT_MACROS

#include <iostream>
#include <dlfcn.h>
#include <cstdlib>

#ifdef NDEBUG
#define OLD_NDEBUG
#endif

#ifdef LLVM_NDEBUG
#define NDEBUG 1
#else
#undef NDEBUG
#endif

#include "llvm/Config/llvm-config.h"

#if defined(LLVM_VERSION_MAJOR) && LLVM_VERSION_MAJOR == 3 && LLVM_VERSION_MINOR >= 6
#define LLVM36 1
#endif
#if defined(LLVM_VERSION_MAJOR) && LLVM_VERSION_MAJOR == 3 && LLVM_VERSION_MINOR >= 8
#define LLVM38 1
#endif
#if defined(LLVM_VERSION_MAJOR) && LLVM_VERSION_MAJOR == 3 && LLVM_VERSION_MINOR >= 9
#define LLVM39 1
#endif
#if defined(LLVM_VERSION_MAJOR) && LLVM_VERSION_MAJOR >= 4
#define LLVM36 1
#define LLVM38 1
#define LLVM39 1
#define LLVM40 1
#endif

// LLVM includes
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Type.h"
#include "llvm/Transforms/Utils/ValueMapper.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Support/VirtualFileSystem.h"

// // Clang includes
#include "clang/AST/AST.h"
#include "clang/AST/DeclVisitor.h"
#include "clang/AST/ExprCXX.h"
#include "clang/AST/PrettyDeclStackTrace.h"
#include "clang/CodeGen/CGFunctionInfo.h"
#include "clang/Frontend/FrontendOptions.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/MultiplexConsumer.h"
#include "clang/Lex/Lexer.h"
#include "clang/Lex/HeaderSearch.h"
#include "clang/Lex/Preprocessor.h"
#include "clang/Lex/PreprocessorOptions.h"
#include "clang/Sema/Sema.h"
#include "clang/Sema/Lookup.h"
#include "clang/Sema/Initialization.h"
#include "clang/Sema/SemaDiagnostic.h"
#include "clang/Serialization/ASTWriter.h"
// Well, yes this is cheating
#define private public
#include "clang/Parse/Parser.h" // 'DeclSpecContext' 'ParseDeclarator'
#undef private
#include "clang/Parse/RAIIObjectsForParser.h"

// clang/lib/
#include "Sema/TypeLocBuilder.h"
#include "CodeGen/CodeGenModule.h"
#define private public
#include "CodeGen/CodeGenFunction.h"
#undef private
#include "CodeGen/CGCXXABI.h"
#include "Sema/TypeLocBuilder.h"

#ifdef _OS_WINDOWS_
#define STDCALL __stdcall
# ifdef LIBRARY_EXPORTS
#  define JL_DLLEXPORT __declspec(dllexport)
# else
#  define JL_DLLEXPORT __declspec(dllimport)
# endif
#else
#define STDCALL
#define JL_DLLEXPORT __attribute__ ((visibility("default")))
#endif

#ifndef OLD_NDEBUG
#undef NDEBUG
#endif

#if defined(_CPU_X86_64_)
#  define _P64
#elif defined(_CPU_X86_)
#  define _P32
#elif defined(_OS_WINDOWS_)
/* Not sure how to determine pointer size on Windows running ARM. */
#  if _WIN64
#    define _P64
#  else
#    define _P32
#  endif
#elif __SIZEOF_POINTER__ == 8
#    define _P64
#elif __SIZEOF_POINTER__ == 4
#    define _P32
#else
#  error pointer size not known for your platform / compiler
#endif

// From julia
using namespace llvm;
extern llvm::LLVMContext &jl_LLVMContext;
static llvm::Type *T_pvalue_llvmt;
static llvm::Type *T_pjlvalue;
static llvm::Type *T_prjlvalue;

// From julia's codegen_shared.h
enum AddressSpace {
    Generic = 0,
    Tracked = 10,
    Derived = 11,
    CalleeRooted = 12,
    Loaded = 13,
    FirstSpecial = Tracked,
    LastSpecial = Loaded,
};

#define JLCALL_CC (CallingConv::ID)36
#define JLCALL_F_CC (CallingConv::ID)37

class JuliaCodeGenerator;
class JuliaPCHGenerator;

struct CxxInstance {
  llvm::Module *shadow;
  clang::CompilerInstance *CI;
  clang::CodeGen::CodeGenModule *CGM;
  clang::CodeGen::CodeGenFunction *CGF;
  clang::Parser *Parser;
  JuliaCodeGenerator *JCodeGen;
  JuliaPCHGenerator *PCHGenerator;
};
const clang::InputKind CKind = clang::InputKind::C;

extern "C" {
  #define TYPE_ACCESS(EX,IN)                                    \
  JL_DLLEXPORT const clang::Type *EX(CxxInstance *Cxx) {                          \
    return Cxx->CI->getASTContext().IN.getTypePtrOrNull();      \
  }

  TYPE_ACCESS(cT_char,CharTy)
  TYPE_ACCESS(cT_cchar,CharTy)
  TYPE_ACCESS(cT_int1,BoolTy)
  TYPE_ACCESS(cT_int8,SignedCharTy)
  TYPE_ACCESS(cT_uint8,UnsignedCharTy)
  TYPE_ACCESS(cT_int16,ShortTy)
  TYPE_ACCESS(cT_uint16,UnsignedShortTy)
  TYPE_ACCESS(cT_int32,IntTy)
  TYPE_ACCESS(cT_uint32,UnsignedIntTy)
#ifdef _OS_WINDOWS_
  TYPE_ACCESS(cT_int64,LongLongTy)
  TYPE_ACCESS(cT_uint64,UnsignedLongLongTy)
#else
  #ifdef _P32
    TYPE_ACCESS(cT_int64,LongLongTy)
    TYPE_ACCESS(cT_uint64,UnsignedLongLongTy)
  #else
    TYPE_ACCESS(cT_int64,LongTy)
    TYPE_ACCESS(cT_uint64,UnsignedLongTy)
  #endif
#endif
  TYPE_ACCESS(cT_size,getSizeType())
  TYPE_ACCESS(cT_int128,Int128Ty)
  TYPE_ACCESS(cT_uint128,UnsignedInt128Ty)
  TYPE_ACCESS(cT_complex64,FloatComplexTy)
  TYPE_ACCESS(cT_complex128,DoubleComplexTy)
  TYPE_ACCESS(cT_float32,FloatTy)
  TYPE_ACCESS(cT_float64,DoubleTy)
  TYPE_ACCESS(cT_void,VoidTy)
  TYPE_ACCESS(cT_wint,WIntTy)
}

// Utilities
clang::SourceLocation getTrivialSourceLocation(CxxInstance *Cxx)
{
    clang::SourceManager &sm = Cxx->CI->getSourceManager();
    return sm.getLocForStartOfFile(sm.getMainFileID());
}

static Type *(*f_julia_type_to_llvm)(void *jt, bool *isboxed);

extern "C" {

extern void jl_error(const char *str);

// For initialization.jl
JL_DLLEXPORT void add_directory(CxxInstance *Cxx, int kind, int isFramework, const char *dirname)
{
  clang::SrcMgr::CharacteristicKind flag = (clang::SrcMgr::CharacteristicKind)kind;
  clang::FileManager &fm = Cxx->CI->getFileManager();
  clang::Preprocessor &pp = Cxx->Parser->getPreprocessor();
  auto dir = fm.getDirectory(dirname);
  if (dir == NULL)
    std::cout << "WARNING: Could not add directory " << dirname << " to clang search path!\n";
  else
    pp.getHeaderSearchInfo().AddSearchPath(clang::DirectoryLookup(dir,flag,isFramework),flag == clang::SrcMgr::C_System || flag == clang::SrcMgr::C_ExternCSystem);
}

JL_DLLEXPORT int isCCompiler(CxxInstance *Cxx)
{
    return Cxx->CI->getLangOpts().CPlusPlus == 0 &&
           Cxx->CI->getLangOpts().ObjC == 0;
}

JL_DLLEXPORT int _cxxparse(CxxInstance *Cxx)
{
    clang::Sema &S = Cxx->CI->getSema();
    clang::ASTConsumer *Consumer = &S.getASTConsumer();

    clang::Parser::DeclGroupPtrTy ADecl;

    while (!Cxx->Parser->ParseTopLevelDecl(ADecl)) {
      // If we got a null return and something *was* parsed, ignore it.  This
      // is due to a top-level semicolon, an action override, or a parse error
      // skipping something.
      if (ADecl && !Consumer->HandleTopLevelDecl(ADecl.get()))
        return 0;
    }

    S.DefineUsedVTables();
    S.PerformPendingInstantiations(false);
    Cxx->CGM->Release();
    Cxx->CI->getDiagnostics().Reset();
    Cxx->CI->getDiagnostics().setSuppressSystemWarnings(true);

    return 1;
}

JL_DLLEXPORT void *ParseDeclaration(CxxInstance *Cxx, clang::DeclContext *DCScope)
{
  auto  *P = Cxx->Parser;
  auto  *S = &Cxx->CI->getSema();
  if (P->getPreprocessor().isIncrementalProcessingEnabled() &&
     P->getCurToken().is(clang::tok::eof))
         P->ConsumeToken();
  clang::ParsingDeclSpec DS(*P);
  clang::AccessSpecifier AS;
  P->ParseDeclarationSpecifiers(DS, clang::Parser::ParsedTemplateInfo(), AS, clang::Parser::DeclSpecContext::DSC_top_level);
  clang::ParsingDeclarator D(*P, DS, clang::DeclaratorContext::FileContext);
  P->ParseDeclarator(D);
  D.setFunctionDefinitionKind(clang::FDK_Definition);
  clang::Scope *TheScope = DCScope ? S->getScopeForContext(DCScope) : P->getCurScope();
  assert(TheScope);
  return S->HandleDeclarator(TheScope, D, clang::MultiTemplateParamsArg());
}

JL_DLLEXPORT void ParseParameterList(CxxInstance *Cxx, void **params, size_t nparams) {
  auto  *P = Cxx->Parser;
  auto  *S = &Cxx->CI->getSema();
  if (P->getPreprocessor().isIncrementalProcessingEnabled() &&
     P->getCurToken().is(clang::tok::eof))
         P->ConsumeToken();
  clang::ParsingDeclSpec DS(*P);
  clang::AccessSpecifier AS;
  clang::ParsingDeclarator D(*P, DS, clang::DeclaratorContext::FileContext);

  clang::ParsedAttributes FirstArgAttrs(P->getAttrFactory());
  SmallVector<clang::DeclaratorChunk::ParamInfo, 16> ParamInfo;
  clang::SourceLocation EllipsisLoc;

  clang::Parser::ParseScope PrototypeScope(P,
                            clang::Scope::FunctionPrototypeScope |
                            clang::Scope::FunctionDeclarationScope |
                            clang::Scope::DeclScope);

  P->ParseParameterDeclarationClause(D,FirstArgAttrs,ParamInfo,EllipsisLoc);

  assert(ParamInfo.size() == nparams);
  for (size_t i = 0; i < nparams; ++i)
    params[i] = ParamInfo[i].Param;
}


JL_DLLEXPORT void *ParseTypeName(CxxInstance *Cxx, int ParseAlias = false)
{
  if (Cxx->Parser->getPreprocessor().isIncrementalProcessingEnabled() &&
    Cxx->Parser->getCurToken().is(clang::tok::eof))
    Cxx->Parser->ConsumeToken();
  auto result = Cxx->Parser->ParseTypeName(nullptr, ParseAlias ?
      clang::DeclaratorContext::AliasTemplateContext : clang::DeclaratorContext::TypeNameContext);
  if (result.isInvalid())
    return 0;
  clang::QualType QT = clang::Sema::GetTypeFromParser(result.get());
  return (void*)QT.getAsOpaquePtr();
}

JL_DLLEXPORT int cxxinclude(CxxInstance *Cxx, char *fname, int isAngled)
{
    const clang::DirectoryLookup *CurDir;
    clang::FileManager &fm = Cxx->CI->getFileManager();
    clang::Preprocessor &P = Cxx->CI->getPreprocessor();

    const clang::FileEntry *File = P.LookupFile(
      getTrivialSourceLocation(Cxx), fname,
      isAngled, P.GetCurDirLookup(), nullptr, CurDir, nullptr,nullptr, nullptr, nullptr, nullptr);

    if(!File)
      return 0;

    clang::SourceManager &sm = Cxx->CI->getSourceManager();

    clang::FileID FID = sm.createFileID(File, sm.getLocForStartOfFile(sm.getMainFileID()), P.getHeaderSearchInfo().getFileDirFlavor(File));

    P.EnterSourceFile(FID, CurDir, sm.getLocForStartOfFile(sm.getMainFileID()));
    return _cxxparse(Cxx);
}

#ifdef LLVM39
typedef llvm::IRBuilder<> CxxIRBuilder;
#else
typedef llvm::IRBuilder<true> CxxIRBuilder;
#endif

/*
 * Collect all global initializers into one llvm::Function, which
 * we can then call.
 */
JL_DLLEXPORT llvm::Function *CollectGlobalConstructors(CxxInstance *Cxx)
{
    clang::CodeGen::CodeGenModule::CtorList &ctors = Cxx->CGM->getGlobalCtors();
    GlobalVariable *GV = Cxx->shadow->getGlobalVariable("llvm.global_ctors");
    if (ctors.empty() && !GV) {
        return NULL;
    }

    // First create the function into which to collect
    llvm::Function *InitF = Function::Create(
      llvm::FunctionType::get(
          llvm::Type::getVoidTy(jl_LLVMContext),
          false),
      llvm::GlobalValue::ExternalLinkage,
      "test",
      Cxx->shadow
      );
    CxxIRBuilder builder(BasicBlock::Create(jl_LLVMContext, "top", InitF));

/*
    for (auto ctor : ctors) {
        builder.CreateCall(ctor.Initializer, {});
    }
*/

    llvm::ConstantArray *List = llvm::dyn_cast<llvm::ConstantArray>(GV->getInitializer());
    GV->eraseFromParent();

    if (List != nullptr) {
      for (auto &op : List->operands()) {
        if (!llvm::isa<llvm::ConstantStruct>(op.get()))
          continue;
        llvm::Constant *TheFunction = llvm::cast<llvm::ConstantStruct>(op.get())->getOperand(1);
        // Strip off constant expression casts.
        if (llvm::ConstantExpr *CE = llvm::dyn_cast<llvm::ConstantExpr>(TheFunction))
          if (CE->isCast())
            TheFunction = CE->getOperand(0);
        if (llvm::Function *F = llvm::dyn_cast<llvm::Function>(TheFunction)) {
          builder.CreateCall(F, {});
        }
      }
    }

    builder.CreateRetVoid();

    ctors.clear();

    return InitF;
}

JL_DLLEXPORT void EnterSourceFile(CxxInstance *Cxx, char *data, size_t length)
{
    const clang::DirectoryLookup *CurDir = nullptr;
    clang::FileManager &fm = Cxx->CI->getFileManager();
    clang::SourceManager &sm = Cxx->CI->getSourceManager();
    clang::FileID FID = sm.createFileID(llvm::MemoryBuffer::getMemBufferCopy(llvm::StringRef(data,length)),clang::SrcMgr::C_User,
      0,0,sm.getLocForStartOfFile(sm.getMainFileID()));
    clang::Preprocessor &P = Cxx->Parser->getPreprocessor();
    P.EnterSourceFile(FID, CurDir, sm.getLocForStartOfFile(sm.getMainFileID()));
}

JL_DLLEXPORT void EnterVirtualFile(CxxInstance *Cxx, char *data, size_t length, char *VirtualPath, size_t PathLength)
{
    const clang::DirectoryLookup *CurDir = nullptr;
    clang::FileManager &fm = Cxx->CI->getFileManager();
    clang::SourceManager &sm = Cxx->CI->getSourceManager();
    llvm::StringRef FileName(VirtualPath, PathLength);
    llvm::StringRef Code(data,length);
    std::unique_ptr<llvm::MemoryBuffer> Buf =
      llvm::MemoryBuffer::getMemBufferCopy(Code, FileName);
    const clang::FileEntry *Entry =
        fm.getVirtualFile(FileName, Buf->getBufferSize(), 0);
    sm.overrideFileContents(Entry, std::move(Buf));
    clang::FileID FID = sm.createFileID(Entry,sm.getLocForStartOfFile(sm.getMainFileID()),clang::SrcMgr::C_User);
    clang::Preprocessor &P = Cxx->Parser->getPreprocessor();
    P.EnterSourceFile(FID, CurDir, sm.getLocForStartOfFile(sm.getMainFileID()));
}

JL_DLLEXPORT int cxxparse(CxxInstance *Cxx, char *data, size_t length)
{
    EnterSourceFile(Cxx, data, length);
    return _cxxparse(Cxx);
}

JL_DLLEXPORT void defineMacro(CxxInstance *Cxx,const char *Name)
{
  clang::Preprocessor &PP = Cxx->Parser->getPreprocessor();
  // Get the identifier.
  clang::IdentifierInfo *Id = PP.getIdentifierInfo(Name);

  clang::MacroInfo *MI = PP.AllocateMacroInfo(getTrivialSourceLocation(Cxx));

  PP.appendDefMacroDirective(Id, MI);
}

// For typetranslation.jl
JL_DLLEXPORT bool BuildNNS(CxxInstance *Cxx, clang::CXXScopeSpec *spec, const char *Name)
{
  clang::Preprocessor &PP = Cxx->CI->getPreprocessor();
  // Get the identifier.
  clang::IdentifierInfo *Id = PP.getIdentifierInfo(Name);
#ifdef LLVM40
  clang::Sema::NestedNameSpecInfo NNSI(Id,
    getTrivialSourceLocation(Cxx),
    getTrivialSourceLocation(Cxx),
    clang::QualType());
    return Cxx->CI->getSema().BuildCXXNestedNameSpecifier(
    nullptr, NNSI,
    false,
    *spec,
    nullptr,
    false,
    nullptr
  );
#else
  return Cxx->CI->getSema().BuildCXXNestedNameSpecifier(
    nullptr, *Id,
    getTrivialSourceLocation(Cxx),
    getTrivialSourceLocation(Cxx),
    clang::QualType(),
    false,
    *spec,
    nullptr,
    false,
    nullptr
  );
#endif
}

JL_DLLEXPORT void *lookup_name(CxxInstance *Cxx, char *name, clang::DeclContext *ctx)
{
    clang::SourceManager &sm = Cxx->CI->getSourceManager();
    clang::CXXScopeSpec spec;
    spec.setBeginLoc(sm.getLocForStartOfFile(sm.getMainFileID()));
    spec.setEndLoc(sm.getLocForStartOfFile(sm.getMainFileID()));
    clang::DeclarationName DName(&Cxx->CI->getASTContext().Idents.get(name));
    clang::Sema &cs = Cxx->CI->getSema();
    cs.RequireCompleteDeclContext(spec,ctx);
    //return dctx->lookup(DName).front();
    clang::LookupResult R(cs, DName, getTrivialSourceLocation(Cxx), clang::Sema::LookupAnyName);
    if (isa<clang::TranslationUnitDecl>(ctx))
      cs.LookupName(R, cs.getCurScope(), false);
    else
      cs.LookupQualifiedName(R, ctx, false);
    return R.empty() ? NULL : R.getRepresentativeDecl();
}

JL_DLLEXPORT void *SpecializeClass(CxxInstance *Cxx, clang::ClassTemplateDecl *tmplt, void **types, uint64_t *integralValues,int8_t *integralValuePresent, size_t nargs)
{
  clang::TemplateArgument *targs = new clang::TemplateArgument[nargs];
  for (size_t i = 0; i < nargs; ++i) {
    if (integralValuePresent[i] == 1) {
      clang::QualType IntT = clang::QualType::getFromOpaquePtr(types[i]);
      size_t BitWidth = Cxx->CI->getASTContext().getTypeSize(IntT);
      llvm::APSInt Value(llvm::APInt(64,integralValues[i]));
      if (Value.getBitWidth() != BitWidth)
        Value = Value.extOrTrunc(BitWidth);
      Value.setIsSigned(IntT->isSignedIntegerOrEnumerationType());
      targs[i] = clang::TemplateArgument(Cxx->CI->getASTContext(),Value,IntT);
    } else {
      targs[i] = clang::TemplateArgument(clang::QualType::getFromOpaquePtr(types[i]));
    }
    targs[i] = Cxx->CI->getASTContext().getCanonicalTemplateArgument(targs[i]);
  }
  void *InsertPos;
  clang::ClassTemplateSpecializationDecl *ret =
    tmplt->findSpecialization(ArrayRef<clang::TemplateArgument>(targs,nargs),
    InsertPos);
  if (!ret)
  {
    ret = clang::ClassTemplateSpecializationDecl::Create(Cxx->CI->getASTContext(),
                            tmplt->getTemplatedDecl()->getTagKind(),
                            tmplt->getDeclContext(),
                            tmplt->getTemplatedDecl()->getBeginLoc(),
                            tmplt->getLocation(),
                            tmplt,
#ifndef LLVM39
                            targs,
                            nargs,
#else
                            ArrayRef<clang::TemplateArgument>{targs,nargs},
#endif
                            nullptr);
    tmplt->AddSpecialization(ret, InsertPos);
    if (tmplt->isOutOfLine())
      ret->setLexicalDeclContext(tmplt->getLexicalDeclContext());
  }
  delete[] targs;
  return ret;
}

JL_DLLEXPORT void *typeForDecl(clang::Decl *D)
{
    clang::TypeDecl *ty = dyn_cast<clang::TypeDecl>(D);
    if (ty == NULL)
      return NULL;
    return (void *)ty->getTypeForDecl();
}

JL_DLLEXPORT void *withConst(void *T)
{
    return clang::QualType::getFromOpaquePtr(T).withConst().getAsOpaquePtr();
}

JL_DLLEXPORT void *withVolatile(void *T)
{
    return clang::QualType::getFromOpaquePtr(T).withVolatile().getAsOpaquePtr();
}

JL_DLLEXPORT void *withRestrict(void *T)
{
    return clang::QualType::getFromOpaquePtr(T).withRestrict().getAsOpaquePtr();
}

JL_DLLEXPORT char *decl_name(clang::NamedDecl *decl)
{
    const clang::IdentifierInfo *II = decl->getIdentifier();
    const clang::TagDecl *TagD;
    if (!II && (TagD = dyn_cast<clang::TagDecl>(decl))) {
      decl = TagD->getTypedefNameForAnonDecl();
      if (!decl)
        return NULL;
    }
    std::string str = decl->getQualifiedNameAsString().data();
    char * cstr = (char*)malloc(str.length()+1);
    std::strcpy (cstr, str.c_str());
    return cstr;
}

JL_DLLEXPORT char *simple_decl_name(clang::NamedDecl *decl)
{
    std::string str = decl->getNameAsString().data();
    char * cstr = (char*)malloc(str.length()+1);
    std::strcpy (cstr, str.c_str());
    return cstr;
}

// For cxxstr
JL_DLLEXPORT void *createNamespace(CxxInstance *Cxx,char *name)
{
  clang::IdentifierInfo *Id = Cxx->CI->getPreprocessor().getIdentifierInfo(name);
  return (void*)clang::NamespaceDecl::Create(
        Cxx->CI->getASTContext(),
        Cxx->CI->getASTContext().getTranslationUnitDecl(),
        false,
        getTrivialSourceLocation(Cxx),
        getTrivialSourceLocation(Cxx),
        Id,
        nullptr
        );
}

JL_DLLEXPORT void SetDeclInitializer(CxxInstance *Cxx, clang::VarDecl *D, llvm::Constant *CI)
{
    llvm::Constant *Const = Cxx->CGM->GetAddrOfGlobalVar(D);
    if (!isa<llvm::GlobalVariable>(Const))
      jl_error("Clang did not create a global variable for the given VarDecl");
    llvm::GlobalVariable *GV = cast<llvm::GlobalVariable>(Const);
    GV->setInitializer(ConstantExpr::getBitCast(CI, GV->getType()->getElementType()));
    GV->setConstant(true);
}

JL_DLLEXPORT void *GetAddrOfFunction(CxxInstance *Cxx, clang::FunctionDecl *D)
{
  return (void*)Cxx->CGM->GetAddrOfFunction(D);
}

size_t cxxsizeofType(CxxInstance *Cxx, void *t);
typedef struct cppcall_state {
    // Save previous globals
    llvm::Module *module;
    llvm::Function *func;
    llvm::Function *CurFn;
    llvm::BasicBlock *block;
    llvm::BasicBlock::iterator point;
    llvm::Instruction *prev_alloca_bb_ptr;
    // Current state
    llvm::Instruction *alloca_bb_ptr;
} cppcall_state_t;

void *setup_cpp_env(CxxInstance *Cxx, void *jlfunc);
void cleanup_cpp_env(CxxInstance *Cxx, cppcall_state_t *);
extern void jl_(void*);
static Function *CloneFunctionAndAdjust(CxxInstance *Cxx, Function *F, FunctionType *FTy,
                              bool ModuleLevelChanges,
                              ClonedCodeInfo *CodeInfo,
                              const clang::CodeGen::CGFunctionInfo &FI,
                              clang::FunctionDecl *FD,
                              bool specsig, bool firstIsEnv,
                              bool *needsbox, void *jl_retty,
                              void **juliatypes,
                              bool newgc) {
  std::vector<Type*> ArgTypes;
  llvm::ValueToValueMapTy VMap;

  // Create the new function...
  Function *NewF = Function::Create(FTy, F->getLinkage(), F->getName(), Cxx->shadow);
  CxxIRBuilder builder(jl_LLVMContext);

  CallInst *Call;
  PointerType *T_pint8 = Type::getInt8PtrTy(jl_LLVMContext,0);
  Type *T_int32 = Type::getInt32Ty(jl_LLVMContext);
  Type *T_int64 = Type::getInt64Ty(jl_LLVMContext);
  Type *T_size;
  if (sizeof(size_t) == 8)
      T_size = T_int64;
  else
      T_size = T_int32;

  if (needsbox) {
    cppcall_state_t *state = (cppcall_state_t *)setup_cpp_env(Cxx,NewF);
    // Julia 0.7 Implementation
    if (newgc) {
      // Ok, we need to go through and box the arguments.
      // Let's first let's clang take care of the function prologue.
      builder.SetInsertPoint(Cxx->CGF->Builder.GetInsertBlock(),
        Cxx->CGF->Builder.GetInsertPoint());
      Cxx->CGF->CurGD = clang::GlobalDecl(FD);
      clang::CodeGen::FunctionArgList Args;
      const clang::CXXMethodDecl *MD = clang::dyn_cast<clang::CXXMethodDecl>(FD);
      if (MD && MD->isInstance()) {
        Cxx->CGM->getCXXABI().buildThisParam(*Cxx->CGF, Args);
      }
      for (auto *PVD : FD->parameters()) {
        Args.push_back(PVD);
      }
      Cxx->CGF->EmitFunctionProlog(FI, NewF, Args);
      Cxx->CGF->ReturnValue = Cxx->CGF->CreateIRTemp(FD->getReturnType(), "retval");
      builder.SetInsertPoint(Cxx->CGF->Builder.GetInsertBlock(),
        Cxx->CGF->Builder.GetInsertPoint());
      FunctionType *PTLSStates_func_fty = FunctionType::get(
                                            PointerType::get(
                                              PointerType::get(T_pjlvalue, 0),
                                              0),
                                            {}
                                          );
      Function *PTLSStates = Function::Create(PTLSStates_func_fty,
                                              Function::ExternalLinkage,
                                              "julia.ptls_states",
                                              Cxx->shadow);

      Function *jl_alloc_obj_func = Function::Create(FunctionType::get(T_prjlvalue,
                                            {T_pint8, T_size, T_prjlvalue}, false),
                                             Function::ExternalLinkage,
                                             "julia.gc_alloc_obj");
      Type *T_pdjlvalue = PointerType::get(
        cast<PointerType>(T_prjlvalue)->getElementType(), AddressSpace::Derived);
      FunctionType *pointer_from_objref_func_fty = FunctionType::get(T_pjlvalue, {T_pdjlvalue}, false);
      Function *pointer_from_objref_func = Function::Create(pointer_from_objref_func_fty,
                                                            Function::ExternalLinkage,
                                                            "julia.pointer_from_objref",
                                                            Cxx->shadow);

      Type *TokenTy = Type::getTokenTy(jl_LLVMContext);
      Type *VoidTy = Type::getVoidTy(jl_LLVMContext);
      FunctionType *gc_preserve_begin_func_fty = FunctionType::get(TokenTy, {T_prjlvalue}, true);
      Function *gc_preserve_begin_func = Function::Create(gc_preserve_begin_func_fty,
                                                          Function::ExternalLinkage,
                                                          "llvm.julia.gc_preserve_begin",
                                                          Cxx->shadow);
      FunctionType *gc_preserve_end_func_fty = FunctionType::get(VoidTy, {TokenTy}, false);
      Function *gc_preserve_end_func = Function::Create(gc_preserve_end_func_fty,
                                                        Function::ExternalLinkage,
                                                        "llvm.julia.gc_preserve_end",
                                                        Cxx->shadow);

      // Unconditionally emit the PTLSStates call into the entry block, otherwise
      // julia's passes may ignore it.
      Value *ptls_ptr = CallInst::Create(PTLSStates, {}, "", &*NewF->front().begin());

      std::vector<llvm::Value*> CallArgs;
      Function::arg_iterator DestI = F->arg_begin();
      size_t i = 0;
      for (auto *PVD : Args) {
        llvm::Value *ArgPtr = Cxx->CGF->GetAddrOfLocalVar(PVD).getPointer();
        if (needsbox[i]) {
          Instruction *InsertPt = cast<Instruction>(ArgPtr);
          Value *Allocation = CallInst::Create(jl_alloc_obj_func,
            {
             cast<Value>(CastInst::Create(Instruction::BitCast, ptls_ptr, T_pint8, "", InsertPt)),
             cast<Value>(Constant::getIntegerValue(T_size, APInt(8*sizeof(size_t), cxxsizeofType(Cxx,(void*)PVD->getType().getTypePtr())))),
             cast<Value>(Constant::getIntegerValue(T_prjlvalue,APInt(8*sizeof(void*),(uint64_t)juliatypes[i++])))
            }, "", InsertPt);
          // Preserve this until the current insert point (we might do
          // additional allocations in the middle)
          Value *Tok = CallInst::Create(gc_preserve_begin_func, {Allocation}, "", InsertPt);
          builder.CreateCall(gc_preserve_end_func, {Tok});
          Value *PFO = CallInst::Create(pointer_from_objref_func, {
              CastInst::CreatePointerBitCastOrAddrSpaceCast(
                Allocation, T_pdjlvalue, "", InsertPt)
            }, "", InsertPt);
          llvm::Value *Replacement = CastInst::Create(Instruction::BitCast,
            PFO, ArgPtr->getType(), "", InsertPt);
          ArgPtr->replaceAllUsesWith(Replacement);
          CallArgs.push_back(Allocation);
        } else {
          bool isboxed;
          bool isVoid = f_julia_type_to_llvm(juliatypes[i++], &isboxed)->isVoidTy();
          llvm::IRBuilderBase::InsertPoint IP = builder.saveIP();
          // Go to end of block
          builder.SetInsertPoint(builder.GetInsertBlock());
          if (specsig) {
            if (isVoid)
              continue;
            if (DestI->getType()->isPointerTy() && !cast<PointerType>(ArgPtr->getType())->getElementType()->isPointerTy())
              CallArgs.push_back(builder.CreateBitCast(ArgPtr,DestI->getType()));
            else
              CallArgs.push_back(builder.CreateLoad(builder.CreateBitCast(ArgPtr,PointerType::get(DestI->getType(),0))));
          } else {
            llvm::Value *Val = isVoid ? ConstantPointerNull::get(cast<PointerType>(T_prjlvalue)) :
              builder.CreatePointerBitCastOrAddrSpaceCast(builder.CreateLoad(ArgPtr),T_prjlvalue);
            CallArgs.push_back(Val);
          }
          builder.restoreIP(IP);
        }
        DestI++;
      }

      if (specsig) {
        Call = builder.CreateCall(F,CallArgs);
      } else {
        SmallVector<Type *, 3> argsT;
        for (size_t i = 0; i < CallArgs.size(); i++) {
            argsT.push_back(T_prjlvalue);
        }
        FunctionType *FTy = FunctionType::get(T_prjlvalue, argsT, false);
        Call = builder.CreateCall(FTy,
          builder.CreateBitCast(F, FTy->getPointerTo()),
          CallArgs);
        if (firstIsEnv)
            Call->setCallingConv(JLCALL_F_CC);
        else
            Call->setCallingConv(JLCALL_CC);
      }

    }
    Cxx->CGF->Builder.SetInsertPoint(builder.GetInsertBlock(),
        builder.GetInsertPoint());
    bool isboxed = false;
    Type *retty = f_julia_type_to_llvm(jl_retty, &isboxed);
    if (isboxed || (Call->getType()->isPointerTy() &&
        cast<PointerType>(Call->getType())->getElementType()->isAggregateType())) {
      clang::QualType type = FD->getReturnType();
      clang::CodeGen::LValue dest = Cxx->CGF->MakeAddrLValue(Cxx->CGF->ReturnValue, type);
      clang::CodeGen::LValue src = Cxx->CGF->MakeAddrLValue(clang::CodeGen::Address(Call, clang::CharUnits::fromQuantity(sizeof(void*))), type);
      Cxx->CGF->EmitAggregateCopy(dest, src, type, clang::CodeGen::AggValueSlot::DoesNotOverlap);
      Cxx->CGF->EmitFunctionEpilog(FI, false, clang::SourceLocation());
    } else {
      Value *Ret = Call;
      // Adjust the return value
      if (F->getReturnType() != FTy->getReturnType()) {
        assert(!F->hasStructRetAttr());
        Value *A = builder.CreateAlloca(FTy->getReturnType());
        builder.CreateStore(Call,builder.CreateBitCast(A,llvm::PointerType::get(Call->getType(),0)));
        Ret = builder.CreateLoad(A);
      }
      if (Call->getType()->isVoidTy())
        builder.CreateRetVoid();
      else
        builder.CreateRet(Ret);
    }

    cleanup_cpp_env(Cxx,state);
  } else {
    llvm::BasicBlock *BB = BasicBlock::Create(NewF->getContext(), "entry", NewF);
    builder.SetInsertPoint(BB);
    // Loop over the arguments, copying the names of the mapped arguments over...
    std::vector<Value*> args;
    assert(NewF->getFunctionType()->getNumParams() ==
      F->getFunctionType()->getNumParams());
    Function::arg_iterator DestI = NewF->arg_begin();
    for (Function::const_arg_iterator I = F->arg_begin(), E = F->arg_end();
         I != E; ++I) {
      DestI->setName(I->getName()); // Copy the name over...
      if (DestI->getType() != I->getType()) {
        assert(I->getType()->isPointerTy());
        llvm::Value *A = builder.CreateAlloca(cast<llvm::PointerType>(I->getType())->getElementType());
        builder.CreateStore(&*DestI,builder.CreateBitCast(A,llvm::PointerType::get(DestI->getType(),0)));
        args.push_back(A);
      }
      else {
        args.push_back(&*DestI);
      }
      DestI++;
    }

    Call = builder.CreateCall(F,args);
    Value *Ret = Call;

    // Adjust the return value
    if (F->getReturnType() != FTy->getReturnType()) {
      assert(!F->hasStructRetAttr());
      Value *A = builder.CreateAlloca(FTy->getReturnType());
      builder.CreateStore(Call,builder.CreateBitCast(A,llvm::PointerType::get(Call->getType(),0)));
      Ret = builder.CreateLoad(A);
    }

    if (Ret->getType()->isVoidTy())
      builder.CreateRetVoid();
    else
      builder.CreateRet(Ret);

  }

  InlineFunctionInfo IFI;
  llvm::InlineFunction(Call,IFI);

  return NewF;
}

JL_DLLEXPORT void *DeleteUnusedArguments(llvm::Function *F, uint64_t *dtodelete, size_t ntodelete)
{
  FunctionType *FTy = F->getFunctionType();
  std::vector<Type*> Params(FTy->param_begin(), FTy->param_end());
  std::vector<uint64_t> todelete;
  todelete.insert(todelete.end(), dtodelete, dtodelete+ntodelete);
  std::sort(todelete.begin(), todelete.end());
  // Delete from back to front to avoid invalidating indices
  for (auto i = todelete.rbegin(); i != todelete.rend(); ++i)
    Params.erase(Params.begin() + *i);
  FunctionType *NFTy = FunctionType::get(FTy->getReturnType(),
                                                Params, false);
  Function *NF = Function::Create(NFTy, F->getLinkage());
  NF->copyAttributesFrom(F);
#ifdef LLVM38
  F->getParent()->getFunctionList().insert(F->getIterator(), NF);
#else
  F->getParent()->getFunctionList().insert(F, NF);
#endif
  NF->takeName(F);

  NF->getBasicBlockList().splice(NF->begin(), F->getBasicBlockList());

  auto x = todelete.begin();
  size_t i = 0;
  for (Function::arg_iterator I = F->arg_begin(), E = F->arg_end(),
       I2 = NF->arg_begin(); I != E; ++i, ++I) {
    if (*x == i) {
      I->replaceAllUsesWith(UndefValue::get(I->getType()));
      ++x;
      continue;
    }
    // Move the name and users over to the new version.
    I->replaceAllUsesWith(&*I2);
    I2->takeName(&*I);
    ++I2;
  }

  F->eraseFromParent();

  return NF;
}


JL_DLLEXPORT void ReplaceFunctionForDecl(CxxInstance *Cxx,clang::FunctionDecl *D, llvm::Function *F, bool DoInline, bool specsig, bool firstIsEnv, bool *needsbox, void *retty, void **juliatypes, bool newgc)
{
  const clang::CodeGen::CGFunctionInfo &FI = Cxx->CGM->getTypes().arrangeGlobalDeclaration(D);
  llvm::FunctionType *Ty = Cxx->CGM->getTypes().GetFunctionType(FI);
  llvm::Constant *Const = Cxx->CGM->GetAddrOfFunction(D,Ty);
  if (!Const || !isa<llvm::Function>(Const))
    jl_error("Clang did not create function for the given FunctionDecl");
  assert(F);
  llvm::Function *OF = cast<llvm::Function>(Const);
  llvm::ValueToValueMapTy VMap;
  llvm::ClonedCodeInfo CCI;

  llvm::Function *NF = CloneFunctionAndAdjust(Cxx,F,Ty,true,&CCI,FI,D,specsig,firstIsEnv,needsbox,retty,juliatypes,newgc);
  // TODO: Ideally we would delete the cloned function
  // once we're done with the inlineing, but clang delays
  // emitting some functions (e.g. constructors) until
  // they're used.
  StringRef Name = OF->getName();
  //OF->dump();
  //NF->dump();
  OF->replaceAllUsesWith(NF);
  OF->removeFromParent();
  NF->setName(Name);
  if (DoInline) {
    while (true)
    {
      if (NF->getNumUses() == 0)
        return;
      Value::user_iterator I = NF->user_begin();
      if (llvm::isa<llvm::CallInst>(*I)) {
        llvm::InlineFunctionInfo IFI;
        llvm::InlineFunction(cast<llvm::CallInst>(*I),IFI,
#                                                     ifdef LLVM38
                                                      nullptr,
#                                                     endif
                                                      true);
      } else {
        I->print(llvm::errs(), false);
        jl_error("Tried to do something other than calling it to a julia expression");
      }
    }
  }
}

JL_DLLEXPORT void *ActOnStartOfFunction(CxxInstance *Cxx, clang::FunctionDecl *D, bool ScopeIsNull = false)
{
  clang::Sema &sema = Cxx->CI->getSema();
  //ContextRAII SavedContext(sema, DC);
  return (void*)sema.ActOnStartOfFunctionDef(ScopeIsNull ? nullptr : Cxx->Parser->getCurScope(), D);
}

JL_DLLEXPORT bool ParseFunctionStatementBody(CxxInstance *Cxx, clang::Decl *D)
{
  clang::Parser::ParseScope BodyScope(Cxx->Parser, clang::Scope::FnScope|clang::Scope::DeclScope);
  Cxx->Parser->ConsumeToken();

  clang::Sema &sema = Cxx->CI->getSema();

  // Slightly modified
  assert(Cxx->Parser->getCurToken().is(clang::tok::l_brace));
  clang::SourceLocation LBraceLoc = Cxx->Parser->getCurToken().getLocation();

  clang::PrettyDeclStackTraceEntry CrashInfo(Cxx->CI->getASTContext(), D, LBraceLoc, "parsing function body");

  // Do not enter a scope for the brace, as the arguments are in the same scope
  // (the function body) as the body itself.  Instead, just read the statement
  // list and put it into a CompoundStmt for safe keeping.
  clang::StmtResult FnBody(Cxx->Parser->ParseCompoundStatementBody(true));

  // If the function body could not be parsed, return an error
  if (!FnBody.isUsable()) {
    sema.ActOnFinishFunctionBody(D, nullptr);
    return false;
  }

  clang::CompoundStmt *Body = cast<clang::CompoundStmt>(FnBody.get());
  if (Body->body_empty()) {
    sema.ActOnFinishFunctionBody(D, nullptr);
    return false;
  }

  // If we don't yet have a return statement, implicitly return
  // the result of the last statement
  if (cast<clang::FunctionDecl>(D)->getReturnType()->isUndeducedType())
  {
    clang::Stmt *last = nullptr;
    // Ignore any trailing null statements in accordance with what
    // julia does. This still triggers a warning in parsing above,
    // but there isn't really a good way to get around that, so
    // we'll live with the warning and have it work anyway
    for (auto lit = Body->body_rbegin(); lit != Body->body_rend(); ++lit) {
      if (!isa<clang::NullStmt>(*lit)) {
        last = *lit;
        break;
      }
    }
    if (last && isa<clang::Expr>(last)) {
      clang::Expr *RetExpr = cast<clang::Expr>(last);
      clang::SourceLocation ReturnLoc = getTrivialSourceLocation(Cxx);
      sema.DeduceFunctionTypeFromReturnExpr(cast<clang::FunctionDecl>(D), ReturnLoc, RetExpr,
            cast<clang::FunctionDecl>(D)->getReturnType()->getContainedAutoType());
      clang::StmtResult RetStmt(sema.BuildReturnStmt(ReturnLoc, RetExpr));
      if (!RetStmt.isUsable()) {
        sema.ActOnFinishFunctionBody(D, nullptr);
        return false;
      }
      Body->body_begin()[Body->size() - 1] = RetStmt.get();
    }
  }

  BodyScope.Exit();
  sema.ActOnFinishFunctionBody(D, Body);
  return true;
}

JL_DLLEXPORT void *ActOnStartNamespaceDef(CxxInstance *Cxx, char *name)
{
  Cxx->Parser->EnterScope(clang::Scope::DeclScope);
  clang::ParsedAttributes attrs(Cxx->Parser->getAttrFactory());
  clang::UsingDirectiveDecl *UsingDecl = nullptr;
  return Cxx->CI->getSema().ActOnStartNamespaceDef(
      Cxx->Parser->getCurScope(),
      getTrivialSourceLocation(Cxx),
      getTrivialSourceLocation(Cxx),
      getTrivialSourceLocation(Cxx),
      Cxx->Parser->getPreprocessor().getIdentifierInfo(name),
      getTrivialSourceLocation(Cxx),
      attrs,
      UsingDecl
    );
}

JL_DLLEXPORT void ActOnFinishNamespaceDef(CxxInstance *Cxx, clang::Decl *D)
{
  Cxx->Parser->ExitScope();
  Cxx->CI->getSema().ActOnFinishNamespaceDef(
      D, getTrivialSourceLocation(Cxx)
      );
}

// For codegen.jl

JL_DLLEXPORT int typeconstruct(CxxInstance *Cxx,void *type, clang::Expr **rawexprs, size_t nexprs, void **ret)
{
    clang::QualType Ty = clang::QualType::getFromOpaquePtr(type);
    clang::MultiExprArg Exprs(rawexprs,nexprs);

    clang::Sema &sema = Cxx->CI->getSema();
    clang::TypeSourceInfo *TInfo = Cxx->CI->getASTContext().getTrivialTypeSourceInfo(Ty);

    if (Ty->isDependentType() || clang::CallExpr::hasAnyTypeDependentArguments(Exprs)) {
        *ret = clang::CXXUnresolvedConstructExpr::Create(Cxx->CI->getASTContext(), TInfo,
                                                      getTrivialSourceLocation(Cxx),
                                                      Exprs,
                                                      getTrivialSourceLocation(Cxx));
        return true;
    }

    clang::ExprResult Result;

    if (Exprs.size() == 1) {
        clang::Expr *Arg = Exprs[0];
        Result = sema.BuildCXXFunctionalCastExpr(TInfo, Ty, getTrivialSourceLocation(Cxx),
          Arg, getTrivialSourceLocation(Cxx));
        if (Result.isInvalid())
          return false;

        *ret = Result.get();
        return true;
    }

    if (!Ty->isVoidType() &&
        sema.RequireCompleteType(getTrivialSourceLocation(Cxx), Ty,
                            clang::diag::err_invalid_incomplete_type_use)) {
        return false;
    }

    if (sema.RequireNonAbstractType(getTrivialSourceLocation(Cxx), Ty,
                               clang::diag::err_allocation_of_abstract_type)) {
        return false;
    }

    clang::InitializedEntity Entity = clang::InitializedEntity::InitializeTemporary(TInfo);
    clang::InitializationKind Kind =
        Exprs.size() ?  clang::InitializationKind::CreateDirect(getTrivialSourceLocation(Cxx),
          getTrivialSourceLocation(Cxx), getTrivialSourceLocation(Cxx))
        : clang::InitializationKind::CreateValue(getTrivialSourceLocation(Cxx),
          getTrivialSourceLocation(Cxx), getTrivialSourceLocation(Cxx));
    clang::InitializationSequence InitSeq(sema, Entity, Kind, Exprs);
    Result = InitSeq.Perform(sema, Entity, Kind, Exprs);

    if (Result.isInvalid())
      return false;

    *ret = Result.get();
    return true;
}

JL_DLLEXPORT void *BuildCXXNewExpr(CxxInstance *Cxx, clang::Type *type, clang::Expr **exprs, size_t nexprs)
{
  clang::QualType Ty = clang::QualType::getFromOpaquePtr(type);
  clang::SourceManager &sm = Cxx->CI->getSourceManager();
  return (void*) Cxx->CI->getSema().BuildCXXNew(
                    clang::SourceRange(),
                    false,
                    getTrivialSourceLocation(Cxx),
                    clang::MultiExprArg(),
                    getTrivialSourceLocation(Cxx),
                    clang::SourceRange(),
                    Ty,
                    Cxx->CI->getASTContext().getTrivialTypeSourceInfo(Ty),
                    NULL,
                    clang::SourceRange(sm.getLocForStartOfFile(sm.getMainFileID()),
                                       sm.getLocForStartOfFile(sm.getMainFileID())),
                    clang::ParenListExpr::Create(
                        Cxx->CI->getASTContext(),
                        getTrivialSourceLocation(Cxx),
                        ArrayRef<clang::Expr*>(exprs, nexprs),
                        getTrivialSourceLocation(Cxx)
                      )
                  ).get();
  //return (clang_astcontext) new clang::CXXNewExpr(clang_astcontext, false, nE, dE, )
}

JL_DLLEXPORT void *EmitCXXNewExpr(CxxInstance *Cxx, clang::Expr *E)
{
  assert(isa<clang::CXXNewExpr>(E));
  return (void*)Cxx->CGF->EmitCXXNewExpr(cast<clang::CXXNewExpr>(E));
}

JL_DLLEXPORT void *build_call_to_member(CxxInstance *Cxx, clang::Expr *MemExprE, clang::Expr **exprs, size_t nexprs)
{
  if (MemExprE->getType() == Cxx->CI->getASTContext().BoundMemberTy ||
         MemExprE->getType() == Cxx->CI->getASTContext().OverloadTy)
    return (void*)Cxx->CI->getSema().BuildCallToMemberFunction(NULL,
      MemExprE,getTrivialSourceLocation(Cxx),clang::MultiExprArg(exprs,nexprs),getTrivialSourceLocation(Cxx)).get();
  else if(isa<clang::TypoExpr>(MemExprE)) {
    return NULL;
  }
  else {
    return (void*) clang::CXXMemberCallExpr::Create(
                      Cxx->CI->getASTContext(),
                      MemExprE,
                      ArrayRef<clang::Expr*>(exprs, nexprs),
                      cast<clang::CXXMethodDecl>(cast<clang::MemberExpr>(MemExprE)->getMemberDecl())->getReturnType(),
                      clang::VK_RValue,
                      getTrivialSourceLocation(Cxx)
                    );
  }
}

JL_DLLEXPORT void *PerformMoveOrCopyInitialization(CxxInstance *Cxx, void *rt, clang::Expr *expr)
{
  clang::InitializedEntity Entity = clang::InitializedEntity::InitializeTemporary(
    clang::QualType::getFromOpaquePtr(rt));
  return (void*)Cxx->CI->getSema().PerformMoveOrCopyInitialization(Entity, NULL,
    clang::QualType::getFromOpaquePtr(rt), expr, true).get();
}

// For CxxREPL
JL_DLLEXPORT void *clang_compiler(CxxInstance *Cxx)
{
  return (void*)Cxx->CI;
}
JL_DLLEXPORT void *clang_parser(CxxInstance *Cxx)
{
  return (void*)Cxx->Parser;
}

// Legacy

static llvm::Type *T_int32;

static bool in_cpp = false;


}

class ValidatingASTVisitor : public clang::DeclVisitor<ValidatingASTVisitor>,
                             public clang::StmtVisitor<ValidatingASTVisitor>
{
private:
  bool FoundInvalid;
  clang::Decl *CurrentDecl;

public:
  ValidatingASTVisitor() : FoundInvalid(false), CurrentDecl(0) {}
  operator bool() { return FoundInvalid; }
  void reset() { FoundInvalid = false; }

  typedef ValidatingASTVisitor ImplClass;
  typedef ValidatingASTVisitor Base;
  typedef clang::DeclVisitor<ImplClass> BaseDeclVisitor;
  typedef clang::StmtVisitor<ImplClass> BaseStmtVisitor;

  using BaseStmtVisitor::Visit;


  //===--------------------------------------------------------------------===//
  // DeclVisitor
  //===--------------------------------------------------------------------===//

  void Visit(clang::Decl *D) {
    clang::Decl *PrevDecl = CurrentDecl;
    CurrentDecl = D;
    BaseDeclVisitor::Visit(D);
    CurrentDecl = PrevDecl;
  }

  void VisitFunctionDecl(clang::FunctionDecl *D) {
    BaseDeclVisitor::VisitFunctionDecl(D);
    if (D->doesThisDeclarationHaveABody())
      Visit(D->getBody());
  }

  void VisitObjCMethodDecl(clang::ObjCMethodDecl *D) {
    BaseDeclVisitor::VisitObjCMethodDecl(D);
    if (D->getBody())
      Visit(D->getBody());
  }

  void VisitBlockDecl(clang::BlockDecl *D) {
    BaseDeclVisitor::VisitBlockDecl(D);
    Visit(D->getBody());
  }

  void VisitVarDecl(clang::VarDecl *D) {
    BaseDeclVisitor::VisitVarDecl(D);
    if (clang::Expr *Init = D->getInit())
      Visit(Init);
  }

  void VisitDecl(clang::Decl *D) {
    if (D->isInvalidDecl())
      FoundInvalid = true;

    if (isa<clang::FunctionDecl>(D) || isa<clang::ObjCMethodDecl>(D) || isa<clang::BlockDecl>(D))
      return;

    if (clang::DeclContext *DC = dyn_cast<clang::DeclContext>(D))
      static_cast<ImplClass*>(this)->VisitDeclContext(DC);
  }

  void VisitDeclContext(clang::DeclContext *DC) {
    for (clang::DeclContext::decl_iterator
           I = DC->decls_begin(), E = DC->decls_end(); I != E; ++I)
      Visit(*I);
  }

  //===--------------------------------------------------------------------===//
  // StmtVisitor
  //===--------------------------------------------------------------------===//

  void VisitDeclStmt(clang::DeclStmt *Node) {
    for (clang::DeclStmt::decl_iterator
           I = Node->decl_begin(), E = Node->decl_end(); I != E; ++I)
      Visit(*I);
  }

  void VisitBlockExpr(clang::BlockExpr *Node) {
    // The BlockDecl is also visited by 'VisitDeclContext()'.  No need to visit it twice.
  }

  void VisitStmt(clang::Stmt *Node) {
#ifdef LLVM38
    for (clang::StmtIterator I = Node->children().begin(); I != Node->children().end(); ++I)
#else
    for (clang::Stmt::child_range I = Node->children(); I; ++I)
#endif
      if (*I)
        Visit(*I);
  }

};


class JuliaCodeGenerator : public clang::ASTConsumer {
  public:
    JuliaCodeGenerator(CxxInstance *Cxx) : Cxx(*Cxx) {}
    CxxInstance Cxx;
    ValidatingASTVisitor Visitor;

    virtual ~JuliaCodeGenerator() {}

    virtual void HandleCXXStaticMemberVarInstantiation(clang::VarDecl *VD) {
      Cxx.CGM->HandleCXXStaticMemberVarInstantiation(VD);
    }

    bool EmitTopLevelDecl(clang::Decl *D)
    {
      Visitor.Visit(D);
      bool HadErrors = (bool)Visitor;
      if (!HadErrors)
        Cxx.CGM->EmitTopLevelDecl(D);
      Visitor.reset();
      return HadErrors;
    }

    virtual bool HandleTopLevelDecl(clang::DeclGroupRef DG) {
      // Make sure to emit all elements of a Decl.
      for (clang::DeclGroupRef::iterator I = DG.begin(), E = DG.end(); I != E; ++I)
        EmitTopLevelDecl(*I);
      return true;
    }

    /// HandleTagDeclDefinition - This callback is invoked each time a TagDecl
    /// to (e.g. struct, union, enum, class) is completed. This allows the
    /// client hack on the type, which can occur at any point in the file
    /// (because these can be defined in declspecs).
    virtual void HandleTagDeclDefinition(clang::TagDecl *D) {
      Cxx.CGM->UpdateCompletedType(D);

      // In C++, we may have member functions that need to be emitted at this
      // point.
      if (Cxx.CI->getASTContext().getLangOpts().CPlusPlus && !D->isDependentContext()) {
        for (clang::DeclContext::decl_iterator M = D->decls_begin(),
                                     MEnd = D->decls_end();
             M != MEnd; ++M)
          if (clang::CXXMethodDecl *Method = dyn_cast<clang::CXXMethodDecl>(*M))
            if (Method->doesThisDeclarationHaveABody() &&
                (Method->hasAttr<clang::UsedAttr>() ||
                 Method->hasAttr<clang::ConstructorAttr>()))
              Cxx.CGM->EmitTopLevelDecl(Method);
      }
    }

    virtual void CompleteTentativeDefinition(clang::VarDecl *D) {
      Cxx.CGM->EmitTentativeDefinition(D);
    }

    virtual void HandleVTable(clang::CXXRecordDecl *RD) {
      Cxx.CGM->EmitVTable(RD);
    }
};


extern "C" {
 JL_DLLEXPORT void *julia_namespace = 0;
}

class JuliaSemaSource : public clang::ExternalSemaSource
{
public:
    JuliaSemaSource() {}
    virtual ~JuliaSemaSource() {}

    virtual bool LookupUnqualified (clang::LookupResult &R, clang::Scope *S)
    {
        if (R.getLookupName().getAsString() == "__julia" && julia_namespace != nullptr) {
            R.addDecl((clang::NamespaceDecl*)julia_namespace);
            return true;
        }
        return false;
    }

};

class JuliaPCHGenerator : public clang::PCHGenerator
{
public:
  JuliaPCHGenerator(
    const clang::Preprocessor &PP,
    clang::InMemoryModuleCache &ModuleCache,
    StringRef OutputFile,
    StringRef isysroot,
    std::shared_ptr<clang::PCHBuffer> Buffer,
    ArrayRef<std::shared_ptr<clang::ModuleFileExtension>> Extensions,
    bool IncludeTimestamps = true,
    bool AllowASTWithErrors = false) :
  PCHGenerator(PP, ModuleCache, OutputFile, isysroot, Buffer, Extensions, AllowASTWithErrors, IncludeTimestamps){}

  void HandleTranslationUnit(clang::ASTContext &Ctx) {
    PCHGenerator::HandleTranslationUnit(Ctx);
  }

  size_t getPCHSize() {
    return getPCH().size();
  }

  void getPCHData(char *data) {
    memcpy(data, getPCH().data(), getPCH().size());
  }
};

extern "C" {




static void set_common_options(CxxInstance *Cxx)
{
  Cxx->CI->getDiagnosticOpts().ShowColors = 1;
  Cxx->CI->getDiagnosticOpts().ShowPresumedLoc = 1;
  Cxx->CI->createDiagnostics();
  Cxx->CI->getCodeGenOpts().setDebugInfo(
#ifdef LLVM39
    clang::codegenoptions::NoDebugInfo
#else
    clang::CodeGenOptions::NoDebugInfo
#endif
  );
}

static void set_default_clang_options(CxxInstance *Cxx, bool CCompiler, const char *Triple, const char *CPU, const char *SysRoot, Type *_T_pvalue_llvmt)
{
    T_pvalue_llvmt = _T_pvalue_llvmt;
    T_pjlvalue = PointerType::get(
      cast<PointerType>(T_pvalue_llvmt)->getElementType(), 0);
    T_prjlvalue = PointerType::get(
      cast<PointerType>(T_pvalue_llvmt)->getElementType(), AddressSpace::Tracked);

    llvm::Triple target = llvm::Triple(Triple == NULL ?
        llvm::Triple::normalize(llvm::sys::getProcessTriple()) : llvm::Triple::normalize(Triple));
    bool isnvptx = (target.getArch() == Triple::ArchType::nvptx) ||
                   (target.getArch() == Triple::ArchType::nvptx64);

    Cxx->CI->getPreprocessorOpts().UsePredefines = 1;
    Cxx->CI->getHeaderSearchOpts().UseBuiltinIncludes = 1;

    clang::CompilerInvocation::setLangDefaults(Cxx->CI->getLangOpts(),
        CCompiler ? CKind : clang::InputKind::CXX,
        target, Cxx->CI->getPreprocessorOpts());

    Cxx->CI->getLangOpts().LineComment = 1;
    Cxx->CI->getLangOpts().Bool = 1;
    Cxx->CI->getLangOpts().WChar = 1;
    Cxx->CI->getLangOpts().C99 = 1;
    if (!CCompiler) {
        bool use_rtti = false;
        const char* rtti_env_setting = getenv("JULIA_CXX_RTTI");
        if (rtti_env_setting != nullptr) use_rtti = (atoi(rtti_env_setting) > 0);

        Cxx->CI->getLangOpts().CPlusPlus = 1;
        Cxx->CI->getLangOpts().CPlusPlus11 = 1;
        Cxx->CI->getLangOpts().CPlusPlus14 = 1;
        Cxx->CI->getLangOpts().CPlusPlus17 = 0;
        Cxx->CI->getLangOpts().MicrosoftExt = 0;
        Cxx->CI->getLangOpts().RTTI = use_rtti;
        Cxx->CI->getLangOpts().RTTIData = use_rtti;
        Cxx->CI->getLangOpts().Exceptions = 1;          // exception handling
        Cxx->CI->getLangOpts().ObjCExceptions = 1;  //  Objective-C exceptions
        Cxx->CI->getLangOpts().CXXExceptions = 1;   // C++ exceptions
#ifdef _OS_WINDOWS_
	Cxx->CI->getLangOpts().SEHExceptions = 1; // Julia uses SEH exception handling on Windows
#endif
        Cxx->CI->getLangOpts().CXXOperatorNames = 1;
        Cxx->CI->getLangOpts().DoubleSquareBracketAttributes = 1;
        Cxx->CI->getHeaderSearchOpts().UseLibcxx = 1;
        Cxx->CI->getHeaderSearchOpts().UseStandardSystemIncludes = 1;
        Cxx->CI->getHeaderSearchOpts().UseStandardCXXIncludes = 1;
    }
    Cxx->CI->getLangOpts().ImplicitInt = 0;
    Cxx->CI->getLangOpts().PICLevel = 2;
    if (isnvptx) {
        Cxx->CI->getLangOpts().CUDA = 1;
        Cxx->CI->getLangOpts().CUDAIsDevice = 1;
#if defined(LLVM38)
        Cxx->CI->getLangOpts().DeclSpecKeyword = 1;
#endif
#if defined(LLVM38) && !defined(LLVM39)
        Cxx->CI->getLangOpts().CUDAAllowHostCallsFromHostDevice = 1;
        Cxx->CI->getLangOpts().CUDATargetOverloads = 1;
        Cxx->CI->getLangOpts().CUDADisableTargetCallChecks = 1;
#endif
    }

    // TODO: Decide how we want to handle this
    // clang_compiler->getLangOpts().AccessControl = 0;
    if (SysRoot)
      Cxx->CI->getHeaderSearchOpts().Sysroot = SysRoot;
    Cxx->CI->getCodeGenOpts().DwarfVersion = 2;
    Cxx->CI->getCodeGenOpts().StackRealignment = 1;
    Cxx->CI->getTargetOpts().Triple = target.normalize();
    Cxx->CI->getTargetOpts().CPU = CPU == NULL ? llvm::sys::getHostCPUName() : CPU;
    StringMap< bool > ActiveFeatures;
    std::vector< std::string > Features;
    if (isnvptx) {
      Features.push_back("+ptx42");
      Cxx->CI->getTargetOpts().Features = Features;
    } else if (llvm::sys::getHostCPUFeatures(ActiveFeatures)) {
      for (auto &F : ActiveFeatures)
        Features.push_back(std::string(F.second ? "+" : "-") +
                                              std::string(F.first()));
      Cxx->CI->getTargetOpts().Features = Features;
    }
}

JL_DLLEXPORT int set_access_control_enabled(CxxInstance *Cxx, int enabled) {
    int enabled_before = Cxx->CI->getLangOpts().AccessControl;
    Cxx->CI->getLangOpts().AccessControl = enabled;
    return enabled_before;
}

static void finish_clang_init(CxxInstance *Cxx, bool EmitPCH, const char *PCHBuffer, size_t PCHBufferSize, time_t PCHTime) {
    Cxx->CI->setTarget(clang::TargetInfo::CreateTargetInfo(
      Cxx->CI->getDiagnostics(),
      std::make_shared<clang::TargetOptions>(Cxx->CI->getTargetOpts())));
    clang::TargetInfo &tin = Cxx->CI->getTarget();
    if (PCHBuffer) {
        llvm::IntrusiveRefCntPtr<llvm::vfs::OverlayFileSystem> Overlay(
           new llvm::vfs::OverlayFileSystem(llvm::vfs::getRealFileSystem()));
        llvm::IntrusiveRefCntPtr<llvm::vfs::InMemoryFileSystem> IMFS(new llvm::vfs::InMemoryFileSystem);
        IMFS->addFile(
            "/Cxx.pch",
            PCHTime,
            llvm::MemoryBuffer::getMemBuffer(StringRef(PCHBuffer, PCHBufferSize), "Cxx.pch", false)
          );
        Overlay->pushOverlay(IMFS);
        Cxx->CI->createFileManager(Overlay);
    } else {
        Cxx->CI->createFileManager();
    }
    Cxx->CI->createSourceManager(Cxx->CI->getFileManager());
    if (PCHBuffer) {
        Cxx->CI->getPreprocessorOpts().ImplicitPCHInclude = "/Cxx.pch";
    }
    Cxx->CI->createPreprocessor(clang::TU_Prefix);
    Cxx->CI->createASTContext();
    Cxx->shadow = new llvm::Module("clangShadow",jl_LLVMContext);
#ifdef LLVM39
    Cxx->shadow->setDataLayout(tin.getDataLayout());
#elif defined(LLVM38)
    Cxx->shadow->setDataLayout(tin.getDataLayoutString());
#else
    Cxx->shadow->setDataLayout(tin.getTargetDescription());
#endif
    Cxx->CGM = new clang::CodeGen::CodeGenModule(
        Cxx->CI->getASTContext(),
        Cxx->CI->getHeaderSearchOpts(),
        Cxx->CI->getPreprocessorOpts(),
        Cxx->CI->getCodeGenOpts(),
        *Cxx->shadow,
#ifndef LLVM38
        Cxx->shadow->getDataLayout(),
#endif
        Cxx->CI->getDiagnostics());
    Cxx->CGF = new clang::CodeGen::CodeGenFunction(*Cxx->CGM);
    Cxx->CGF->CurFuncDecl = NULL;
    Cxx->CGF->CurCodeDecl = NULL;

    // Cxx isn't fully initialized yet, but that's fine since JuliaCodeGenerator does
    // not need the parser
    Cxx->JCodeGen = new JuliaCodeGenerator(Cxx);

    if (EmitPCH) {
      assert(&Cxx->CI->getPreprocessor() != NULL);
      assert(&Cxx->CI->getPreprocessor().getModuleLoader() != NULL);
      StringRef OutputFile = "Cxx.pch";
      auto Buffer = std::make_shared<clang::PCHBuffer>();
      Cxx->PCHGenerator = new JuliaPCHGenerator(
                        Cxx->CI->getPreprocessor(),
                        Cxx->CI->getModuleCache(),
                        OutputFile,
                        Cxx->CI->getHeaderSearchOpts().Sysroot,
                        Buffer,
                        Cxx->CI->getFrontendOpts().ModuleFileExtensions,
                        true);
      std::vector<std::unique_ptr<clang::ASTConsumer>> Consumers;
      Consumers.push_back(std::unique_ptr<clang::ASTConsumer>(Cxx->JCodeGen));
      Consumers.push_back(std::unique_ptr<clang::ASTConsumer>(Cxx->PCHGenerator));
      Cxx->CI->setASTConsumer(
        llvm::make_unique<clang::MultiplexConsumer>(std::move(Consumers)));
    } else {
      Cxx->CI->setASTConsumer(std::unique_ptr<clang::ASTConsumer>(Cxx->JCodeGen));
    }

    if (PCHBuffer) {
        clang::ASTDeserializationListener *DeserialListener =
            Cxx->CI->getASTConsumer().GetASTDeserializationListener();
        bool DeleteDeserialListener = false;
        Cxx->CI->createPCHExternalASTSource(
          "/Cxx.pch",
          Cxx->CI->getPreprocessorOpts().DisablePCHValidation,
          Cxx->CI->getPreprocessorOpts().AllowPCHWithCompilerErrors, DeserialListener,
          DeleteDeserialListener);
    }

    Cxx->CI->createSema(clang::TU_Prefix,NULL);
    Cxx->CI->getSema().addExternalSource(new JuliaSemaSource());

    T_int32 = Type::getInt32Ty(jl_LLVMContext);

    clang::Sema &sema = Cxx->CI->getSema();
    clang::Preprocessor &pp = Cxx->CI->getPreprocessor();
    Cxx->Parser = new clang::Parser(pp, sema, false);

    Cxx->CI->getDiagnosticClient().BeginSourceFile(Cxx->Parser->getLangOpts(), 0);
#ifdef LLVM38
    pp.getBuiltinInfo().initializeBuiltins(pp.getIdentifierTable(),
                                           Cxx->Parser->getLangOpts());
#else
    pp.getBuiltinInfo().InitializeBuiltins(pp.getIdentifierTable(),
                                           Cxx->Parser->getLangOpts());
#endif
    pp.enableIncrementalProcessing();

    clang::SourceManager &sm = Cxx->CI->getSourceManager();
    const char *fname = PCHBuffer ? "/Cxx.cpp" : "/Cxx.h";
    const clang::FileEntry *MainFile = Cxx->CI->getFileManager().getVirtualFile(fname, 0, time(0));
    sm.overrideFileContents(MainFile, llvm::WritableMemoryBuffer::getNewMemBuffer(0, fname));
    sm.setMainFileID(sm.createFileID(MainFile, clang::SourceLocation(), clang::SrcMgr::C_User));

    sema.getPreprocessor().EnterMainSourceFile();
    Cxx->Parser->Initialize();

    clang::ExternalASTSource *External = Cxx->CI->getASTContext().getExternalSource();
    if (External)
        External->StartTranslationUnit(&Cxx->CI->getASTConsumer());

    _cxxparse(Cxx);

    f_julia_type_to_llvm = (llvm::Type *(*)(void *, bool *))dlsym(RTLD_DEFAULT, "jl_type_to_llvm");

    assert(f_julia_type_to_llvm);
}

JL_DLLEXPORT void init_clang_instance(CxxInstance *Cxx, const char *Triple, const char *CPU, const char *SysRoot, bool EmitPCH,
  bool CCompiler, const char *PCHBuffer, size_t PCHBufferSize, struct tm *PCHTime, Type *_T_pvalue_llvmt) {
    Cxx->CI = new clang::CompilerInstance;
    set_common_options(Cxx);
    set_default_clang_options(Cxx, CCompiler, Triple, CPU, SysRoot, _T_pvalue_llvmt);
    time_t t = time(0);
    if (PCHTime)
        t = mktime(PCHTime);
    finish_clang_init(Cxx, EmitPCH, PCHBuffer, PCHBufferSize, t);
}

JL_DLLEXPORT void init_clang_instance_from_invocation(CxxInstance *Cxx, clang::CompilerInvocation *Inv)
{
    Cxx->CI = new clang::CompilerInstance;
#ifdef LLVM40
    Cxx->CI->setInvocation(std::shared_ptr<clang::CompilerInvocation>(Inv));
#else
    Cxx->CI->setInvocation(Inv);
#endif
    set_common_options(Cxx);
    time_t t(0);
    finish_clang_init(Cxx, false, nullptr, 0, t);
}

#define xstringify(s) stringify(s)
#define stringify(s) #s
JL_DLLEXPORT void apply_default_abi(CxxInstance *Cxx)
{
#if defined(_GLIBCXX_USE_CXX11_ABI)
    char define[] = "#define _GLIBCXX_USE_CXX11_ABI " xstringify(_GLIBCXX_USE_CXX11_ABI);
    cxxparse(Cxx, define, sizeof(define)-1);
#endif
}

JL_DLLEXPORT size_t getPCHSize(CxxInstance *Cxx) {
  Cxx->PCHGenerator->HandleTranslationUnit(Cxx->CI->getASTContext());
  return Cxx->PCHGenerator->getPCHSize();
}

JL_DLLEXPORT void decouple_pch(CxxInstance *Cxx, char *data)
{
  Cxx->PCHGenerator->getPCHData(data);
  Cxx->JCodeGen = new JuliaCodeGenerator(Cxx);
  Cxx->CI->setASTConsumer(std::unique_ptr<clang::ASTConsumer>(Cxx->JCodeGen));
  Cxx->CI->getSema().Consumer = Cxx->CI->getASTConsumer();
}

static llvm::Module *cur_module = NULL;
static llvm::Function *cur_func = NULL;


JL_DLLEXPORT void *setup_cpp_env(CxxInstance *Cxx, void *jlfunc)
{
    //assert(in_cpp == false);
    //in_cpp = true;

    assert(Cxx->CGF != NULL);

    cppcall_state_t *state = new cppcall_state_t;
    state->module = NULL;
    state->func = cur_func;
    state->CurFn = Cxx->CGF->CurFn;
    state->block = Cxx->CGF->Builder.GetInsertBlock();
    state->point = Cxx->CGF->Builder.GetInsertPoint();
    state->prev_alloca_bb_ptr = Cxx->CGF->AllocaInsertPt;

    llvm::Function *w = (Function *)jlfunc;
    assert(w != NULL);
    cur_module = NULL;
    cur_func = w;

    Function *ShadowF = (llvm::Function *)jlfunc;

    BasicBlock *b0 = BasicBlock::Create(Cxx->shadow->getContext(), "top", ShadowF);

    Cxx->CGF->ReturnBlock = Cxx->CGF->getJumpDestInCurrentScope("return");

    // setup the environment to clang's expecations
    Cxx->CGF->Builder.SetInsertPoint( b0 );
    // clang expects to alloca memory before the AllocaInsertPt
    // typically, clang would create this pointer when it started emitting the function
    // instead, we create a dummy reference here
    // for efficiency, we avoid creating a new placehold instruction if possible
    llvm::Instruction *alloca_bb_ptr = NULL;
    if (b0->empty()) {
        llvm::Value *Undef = llvm::UndefValue::get(T_int32);
        Cxx->CGF->AllocaInsertPt = alloca_bb_ptr = new llvm::BitCastInst(Undef, T_int32, "", b0);
    } else {
        Cxx->CGF->AllocaInsertPt = &(b0->front());
    }

    Cxx->CGF->PrologueCleanupDepth = Cxx->CGF->EHStack.stable_begin();

    Cxx->CGF->CurFn = ShadowF;
    state->alloca_bb_ptr = alloca_bb_ptr;

    return state;
}

JL_DLLEXPORT bool EmitTopLevelDecl(CxxInstance *Cxx, clang::Decl *D)
{
    return Cxx->JCodeGen->EmitTopLevelDecl(D);
}

JL_DLLEXPORT void cleanup_cpp_env(CxxInstance *Cxx, cppcall_state_t *state)
{
    //assert(in_cpp == true);
    //in_cpp = false;
#ifdef LLVM38
    Cxx->CGF->ReturnValue = clang::CodeGen::Address(nullptr,clang::CharUnits());
#else
    Cxx->CGF->ReturnValue = nullptr;
#endif
    Cxx->CGF->Builder.ClearInsertionPoint();
    clang::CodeGen::CallArgList args;
    const clang::CodeGen::CGFunctionInfo &fnInfo =
      Cxx->CGM->getTypes().arrangeBuiltinFunctionCall(Cxx->CI->getASTContext().VoidTy, args);
    Cxx->CGF->CurFnInfo = &fnInfo;
    Cxx->CGF->FinishFunction(getTrivialSourceLocation(Cxx));
    Cxx->CGF->ReturnBlock.getBlock()->eraseFromParent();
    Cxx->CGF->ReturnBlock = Cxx->CGF->getJumpDestInCurrentScope(
      Cxx->CGF->createBasicBlock("return"));

    Cxx->CI->getSema().DefineUsedVTables();
    Cxx->CI->getSema().PerformPendingInstantiations(false);
    Cxx->CGM->Release();

    // Set all functions and globals to external linkage (MCJIT needs this ugh)
    auto &jl_Module = Cxx->CGM->getModule();
    for(auto I = jl_Module.global_begin(), E = jl_Module.global_end(); I != E; ++I) {
       I->setLinkage(llvm::GlobalVariable::ExternalLinkage);
    }

    Function *F = Cxx->CGF->CurFn;

    // cleanup the environment
    Cxx->CGF->EHResumeBlock = nullptr;
    Cxx->CGF->TerminateLandingPad = nullptr;
    Cxx->CGF->TerminateHandler = nullptr;
    Cxx->CGF->UnreachableBlock = nullptr;
    Cxx->CGF->ExceptionSlot = nullptr;
    Cxx->CGF->EHSelectorSlot = nullptr;

    //copy_into(F,cur_func);

    //F->eraseFromParent();
    // Hack: MaybeBindToTemporary can cause this to be
    // set if the allocated type has a constructor.
    // For now, ignore.
#ifndef LLVM39
    Cxx->CI->getSema().ExprNeedsCleanups = false;
#endif

    cur_module = state->module;
    cur_func = state->func;
    Cxx->CGF->CurFn = state->CurFn;
    if (state->block != nullptr)
      Cxx->CGF->Builder.SetInsertPoint(state->block,state->point);
    Cxx->CGF->AllocaInsertPt = state->prev_alloca_bb_ptr;
    delete state;
}

/*
ActOnCallExpr(Scope *S, Expr *Fn, SourceLocation LParenLoc,
04467                     MultiExprArg ArgExprs, SourceLocation RParenLoc,
04468                     Expr *ExecConfig, bool IsExecConfig) {
04469   // Since this might be a postfix expression, get rid of Pare
*/
JL_DLLEXPORT void *CreateCallExpr(CxxInstance *Cxx, clang::Expr *Fn,clang::Expr **exprs, size_t nexprs)
{
    return Cxx->CI->getSema().ActOnCallExpr(NULL, Fn, getTrivialSourceLocation(Cxx),
      clang::MultiExprArg(exprs,nexprs), getTrivialSourceLocation(Cxx), nullptr).get();
}

JL_DLLEXPORT void *CreateVarDecl(CxxInstance *Cxx, void *DC, char* name, void *type)
{
  clang::QualType T = clang::QualType::getFromOpaquePtr(type);
  clang::VarDecl *D = clang::VarDecl::Create(Cxx->CI->getASTContext(), (clang::DeclContext *)DC,
    getTrivialSourceLocation(Cxx), getTrivialSourceLocation(Cxx),
      Cxx->CI->getPreprocessor().getIdentifierInfo(name),
      T, Cxx->CI->getASTContext().getTrivialTypeSourceInfo(T), clang::SC_Extern);
  return D;
}

JL_DLLEXPORT void *CreateFunctionDecl(CxxInstance *Cxx, void *DC, char* name, void *type, int isextern)
{
  clang::QualType T = clang::QualType::getFromOpaquePtr(type);
  clang::FunctionDecl *D = clang::FunctionDecl::Create(Cxx->CI->getASTContext(), (clang::DeclContext *)DC,
    getTrivialSourceLocation(Cxx), getTrivialSourceLocation(Cxx),
      clang::DeclarationName(Cxx->CI->getPreprocessor().getIdentifierInfo(name)),
      T, Cxx->CI->getASTContext().getTrivialTypeSourceInfo(T), isextern ? clang::SC_Extern : clang::SC_None);

  // check if we are compiling for a device
  if (Cxx->CI->getLangOpts().CUDAIsDevice == 1) {
    D->addAttr(clang::CUDADeviceAttr::CreateImplicit(Cxx->CI->getASTContext(), D->getLocation()));
  }
  return D;
}

JL_DLLEXPORT void *CreateCxxCallMethodDecl(CxxInstance *Cxx, clang::CXXRecordDecl *TheClass, void *QT)
{
  clang::DeclarationName MethodName
    = Cxx->CI->getASTContext().DeclarationNames.getCXXOperatorName(clang::OO_Call);
  clang::DeclarationNameLoc MethodNameLoc;
  clang::QualType T = clang::QualType::getFromOpaquePtr(QT);
  clang::CXXMethodDecl *Method
    = clang::CXXMethodDecl::Create(Cxx->CI->getASTContext(), TheClass,
                            getTrivialSourceLocation(Cxx),
                            clang::DeclarationNameInfo(MethodName,
                                                getTrivialSourceLocation(Cxx),
                                                MethodNameLoc),
                            T, Cxx->CI->getASTContext().getTrivialTypeSourceInfo(T),
                            clang::SC_None,
                            /*isInline=*/true,
                            /*isConstExpr=*/clang::CSK_unspecified,
                            getTrivialSourceLocation(Cxx));
  Method->setAccess(clang::AS_public);
  return Method;
}

JL_DLLEXPORT void *CreateParmVarDecl(CxxInstance *Cxx, void *type, char *name, int used)
{
    clang::QualType T = clang::QualType::getFromOpaquePtr(type);
    clang::ParmVarDecl *d = clang::ParmVarDecl::Create(
        Cxx->CI->getASTContext(),
        Cxx->CI->getASTContext().getTranslationUnitDecl(), // This is wrong, hopefully it doesn't matter
        getTrivialSourceLocation(Cxx),
        getTrivialSourceLocation(Cxx),
        &Cxx->CI->getPreprocessor().getIdentifierTable().getOwn(name),
        T,
        Cxx->CI->getASTContext().getTrivialTypeSourceInfo(T),
        clang::SC_None,NULL);
    if (used)
        d->setIsUsed();
    return (void*)d;
}

JL_DLLEXPORT void *CreateTypeDefDecl(CxxInstance *Cxx, clang::DeclContext *DC, char *name, void *type)
{
    clang::QualType T = clang::QualType::getFromOpaquePtr(type);
    return (void*)clang::TypedefDecl::Create(Cxx->CI->getASTContext(),DC,getTrivialSourceLocation(Cxx),
      getTrivialSourceLocation(Cxx),
        &Cxx->CI->getPreprocessor().getIdentifierTable().getOwn(name),
        Cxx->CI->getASTContext().getTrivialTypeSourceInfo(T));
}

JL_DLLEXPORT void SetFDParams(clang::FunctionDecl *FD, clang::ParmVarDecl **PVDs, size_t npvds)
{
    FD->setParams(ArrayRef<clang::ParmVarDecl*>(PVDs,npvds));
    clang::TypeSourceInfo *TInfo = FD->getTypeSourceInfo();
    if (clang::FunctionProtoTypeLoc Proto =
          TInfo->getTypeLoc().IgnoreParens().getAs<clang::FunctionProtoTypeLoc>()) {
      for (size_t i = 0; i < npvds; ++i) {
        Proto.setParam(i, PVDs[i]);
        PVDs[i]->setScopeInfo(0,i);
      }
    }
}

JL_DLLEXPORT void AssociateValue(CxxInstance *Cxx, clang::Decl *d, void *type, llvm::Value *V)
{
    clang::VarDecl *vd = dyn_cast<clang::VarDecl>(d);
    clang::QualType T = clang::QualType::getFromOpaquePtr(type);
    llvm::Type *Ty = Cxx->CGF->ConvertTypeForMem(T);
    if (type == cT_int1(Cxx))
      V = Cxx->CGF->Builder.CreateZExt(V, Ty);
    // Associate the value with this decl
#ifdef LLVM38
    Cxx->CGF->EmitParmDecl(*vd,
      clang::CodeGen::CodeGenFunction::ParamValue::forDirect(Cxx->CGF->Builder.CreateBitCast(V, Ty)), 0);
#else
    Cxx->CGF->EmitParmDecl(*vd, Cxx->CGF->Builder.CreateBitCast(V, Ty), false, 0);
#endif
}

JL_DLLEXPORT void AddDeclToDeclCtx(clang::DeclContext *DC, clang::Decl *D)
{
    DC->addDecl(D);
}

JL_DLLEXPORT void AddTopLevelDecl(CxxInstance *Cxx, clang::NamedDecl *D)
{
    if (Cxx->CI->getSema().IdResolver.tryAddTopLevelDecl(D, D->getDeclName()) &&
        Cxx->CI->getSema().TUScope)
      Cxx->CI->getSema().TUScope->AddDecl(D);
}

JL_DLLEXPORT void *CreateDeclRefExpr(CxxInstance *Cxx,clang::ValueDecl *D, clang::CXXScopeSpec *scope, int islvalue)
{
    clang::QualType T = D->getType();
    return (void*)clang::DeclRefExpr::Create(Cxx->CI->getASTContext(), scope ?
            scope->getWithLocInContext(Cxx->CI->getASTContext()) : clang::NestedNameSpecifierLoc(NULL,NULL),
            getTrivialSourceLocation(Cxx), D, false, getTrivialSourceLocation(Cxx),
            T.getNonReferenceType(), islvalue ? clang::VK_LValue : clang::VK_RValue);
}

JL_DLLEXPORT void *EmitDeclRef(CxxInstance *Cxx, clang::DeclRefExpr *DRE)
{
#ifdef LLVM38
    return Cxx->CGF->EmitDeclRefLValue(DRE).getPointer();
#else
    return Cxx->CGF->EmitDeclRefLValue(DRE).getAddress();
#endif
}

JL_DLLEXPORT void *DeduceReturnType(clang::Expr *expr)
{
    return expr->getType().getAsOpaquePtr();
}

JL_DLLEXPORT void *CreateFunction(CxxInstance *Cxx, llvm::Type *rt, llvm::Type** argt, size_t nargs)
{
  llvm::FunctionType *ft = llvm::FunctionType::get(rt,llvm::ArrayRef<llvm::Type*>(argt,nargs),false);
  return (void*)llvm::Function::Create(ft, llvm::GlobalValue::ExternalLinkage, "cxxjl", Cxx->shadow);
}

JL_DLLEXPORT void *tovdecl(clang::Decl *D)
{
    return dyn_cast<clang::ValueDecl>(D);
}

JL_DLLEXPORT void *cxxtmplt(clang::Decl *D)
{
    return dyn_cast<clang::ClassTemplateDecl>(D);
}


JL_DLLEXPORT void *extractTypePtr(void *QT)
{
    return (void*)clang::QualType::getFromOpaquePtr(QT).getTypePtr();
}

JL_DLLEXPORT unsigned extractCVR(void *QT)
{
    return clang::QualType::getFromOpaquePtr(QT).getCVRQualifiers();
}

JL_DLLEXPORT void *emitcallexpr(CxxInstance *Cxx, clang::Expr *E, llvm::Value *rslot)
{
    if (isa<clang::CXXBindTemporaryExpr>(E))
      E = cast<clang::CXXBindTemporaryExpr>(E)->getSubExpr();

    clang::CallExpr *CE = dyn_cast<clang::CallExpr>(E);
    assert(CE != NULL);

    clang::CodeGen::RValue ret = Cxx->CGF->EmitCallExpr(CE,clang::CodeGen::ReturnValueSlot(
#ifdef LLVM38
      clang::CodeGen::Address(rslot,clang::CharUnits::One()),
#else
      rslot,
#endif
      false));
    if (ret.isScalar())
      return ret.getScalarVal();
    else
#ifdef LLVM38
      return ret.getAggregateAddress().getPointer();
#else
      return ret.getAggregateAddr();
#endif
}

JL_DLLEXPORT void emitexprtomem(CxxInstance *Cxx,clang::Expr *E, llvm::Value *addr, int isInit)
{
    Cxx->CGF->EmitAnyExprToMem(E,
#ifdef LLVM38
      clang::CodeGen::Address(addr,clang::CharUnits::One()),
#else
      addr,
#endif
      clang::Qualifiers(), isInit);
}

JL_DLLEXPORT void *EmitAnyExpr(CxxInstance *Cxx, clang::Expr *E, llvm::Value *rslot)
{
    clang::CodeGen::RValue ret = Cxx->CGF->EmitAnyExpr(E);
    if (ret.isScalar())
      return ret.getScalarVal();
    else
#ifdef LLVM38
      return ret.getAggregateAddress().getPointer();
#else
      return ret.getAggregateAddr();
#endif
}

JL_DLLEXPORT void *get_nth_argument(Function *f, size_t n)
{
    size_t i = 0;
    Function::arg_iterator AI = f->arg_begin();
    for (; AI != f->arg_end(); ++i, ++AI)
    {
        if (i == n)
            return (void*)((Value*)&*AI++);
    }
    return NULL;
}

JL_DLLEXPORT void *create_extract_value(CxxInstance *Cxx, Value *agg, size_t idx)
{
    return Cxx->CGF->Builder.CreateExtractValue(agg,ArrayRef<unsigned>((unsigned)idx));
}

JL_DLLEXPORT void *create_insert_value(CxxIRBuilder *builder, Value *agg, Value *val, size_t idx)
{
    return builder->CreateInsertValue(agg,val,ArrayRef<unsigned>((unsigned)idx));
}

JL_DLLEXPORT void *CreateIntToPtr(CxxIRBuilder *builder, Value *TheInt, Type *Ty)
{
    return builder->CreateIntToPtr(TheInt, Ty);
}

JL_DLLEXPORT void *CreatePtrToInt(CxxIRBuilder *builder, Value *TheInt, Type *Ty)
{
    return builder->CreatePtrToInt(TheInt, Ty);
}
JL_DLLEXPORT void *tu_decl(CxxInstance *Cxx)
{
    return Cxx->CI->getASTContext().getTranslationUnitDecl();
}

JL_DLLEXPORT void *get_primary_dc(clang::DeclContext *dc)
{
    return dc->getPrimaryContext();
}

JL_DLLEXPORT void *decl_context(clang::Decl *decl)
{
    if(isa<clang::TypedefNameDecl>(decl))
    {
        decl = dyn_cast<clang::TypedefNameDecl>(decl)->getUnderlyingType().getTypePtr()->getAsCXXRecordDecl();
    }
    if (decl == NULL)
      return decl;
    /*
    if(isa<clang::ClassTemplateSpecializationDecl>(decl))
    {
        auto ptr = cast<clang::ClassTemplateSpecializationDecl>(decl)->getSpecializedTemplateOrPartial();
        if (ptr.is<clang::ClassTemplateDecl*>())
            decl = ptr.get<clang::ClassTemplateDecl*>();
        else
            decl = ptr.get<clang::ClassTemplatePartialSpecializationDecl*>();
    }*/
    return dyn_cast<clang::DeclContext>(decl);
}

JL_DLLEXPORT void *to_decl(clang::DeclContext *decl)
{
    return dyn_cast<clang::Decl>(decl);
}

JL_DLLEXPORT void *to_cxxdecl(clang::Decl *decl)
{
    return dyn_cast<clang::CXXRecordDecl>(decl);
}

JL_DLLEXPORT char *getTypeNameAsString(void *T)
{
    const clang::LangOptions LO;
    const clang::PrintingPolicy PP(LO);
    clang::QualType QT = clang::QualType::getFromOpaquePtr(T);
    std::string name = QT.getAsString(PP);
    char *cname = (char*)malloc(name.size()+1);
    memcpy(cname, name.c_str(), name.size()+1);
    return cname;
}

JL_DLLEXPORT void *GetFunctionReturnType(clang::FunctionDecl *FD)
{
    return FD->getReturnType().getAsOpaquePtr();
}

JL_DLLEXPORT void *BuildDecltypeType(CxxInstance *Cxx, clang::Expr *E)
{
    clang::QualType T = Cxx->CI->getSema().BuildDecltypeType(E,E->getBeginLoc());
    return Cxx->CI->getASTContext().getCanonicalType(T).getAsOpaquePtr();
}

JL_DLLEXPORT void *getTemplateArgs(clang::ClassTemplateSpecializationDecl *tmplt)
{
    return (void*)&tmplt->getTemplateArgs();
}

JL_DLLEXPORT size_t getTargsSize(clang::TemplateArgumentList *targs)
{
    return targs->size();
}

JL_DLLEXPORT size_t getTSTTargsSize(clang::TemplateSpecializationType *TST)
{
    return TST->getNumArgs();
}

JL_DLLEXPORT size_t getTDNumParameters(clang::TemplateDecl *TD)
{
    return TD->getTemplateParameters()->size();
}

JL_DLLEXPORT void *getTargsPointer(clang::TemplateArgumentList *targs)
{
    return (void*)targs->data();
}

JL_DLLEXPORT void *getTargType(const clang::TemplateArgument *targ)
{
    return (void*)targ->getAsType().getAsOpaquePtr();
}

JL_DLLEXPORT void *getTDParamAtIdx(clang::TemplateDecl *TD, int i)
{
    return (void*)TD->getTemplateParameters()->getParam(i);
}

JL_DLLEXPORT void *getTargTypeAtIdx(clang::TemplateArgumentList *targs, size_t i)
{
    return getTargType(&targs->get(i));
}

JL_DLLEXPORT void *getTSTTargTypeAtIdx(clang::TemplateSpecializationType *targs, size_t i)
{
    return getTargType(&targs->getArg(i));
}

JL_DLLEXPORT void *getTargIntegralType(const clang::TemplateArgument *targ)
{
    return targ->getIntegralType().getAsOpaquePtr();
}

JL_DLLEXPORT void *getTargIntegralTypeAtIdx(clang::TemplateArgumentList *targs, size_t i)
{
    return getTargIntegralType(&targs->get(i));
}

JL_DLLEXPORT int getTargKind(const clang::TemplateArgument *targ)
{
    return targ->getKind();
}

JL_DLLEXPORT int getTargKindAtIdx(clang::TemplateArgumentList *targs, size_t i)
{
    return getTargKind(&targs->get(i));
}

JL_DLLEXPORT int getTSTTargKindAtIdx(clang::TemplateSpecializationType *TST, size_t i)
{
    return getTargKind(&TST->getArg(i));
}

JL_DLLEXPORT size_t getTargPackAtIdxSize(clang::TemplateArgumentList *targs, size_t i)
{
    return targs->get(i).getPackAsArray().size();
}

JL_DLLEXPORT void *getTargPackAtIdxTargAtIdx(clang::TemplateArgumentList *targs, size_t i, size_t j)
{
    return (void*)&targs->get(i).getPackAsArray()[j];
}

JL_DLLEXPORT int64_t getTargAsIntegralAtIdx(clang::TemplateArgumentList *targs, size_t i)
{
    return targs->get(i).getAsIntegral().getSExtValue();
}

void *getTargPackBegin(clang::TemplateArgument *targ)
{
    return (void*)targ->pack_begin();
}

size_t getTargPackSize(clang::TemplateArgument *targ)
{
    return targ->pack_size();
}

JL_DLLEXPORT void *getPointeeType(clang::Type *t)
{
    return t->getPointeeType().getAsOpaquePtr();
}

JL_DLLEXPORT void *getArrayElementType(clang::Type *t)
{
    return cast<clang::ArrayType>(t)->getElementType().getAsOpaquePtr();
}

JL_DLLEXPORT void *getOriginalType(clang::ParmVarDecl *d)
{
  return (void*)d->getOriginalType().getAsOpaquePtr();
}

JL_DLLEXPORT void *getPointerTo(CxxInstance *Cxx, void *T)
{
    return Cxx->CI->getASTContext().getPointerType(clang::QualType::getFromOpaquePtr(T)).getAsOpaquePtr();
}

JL_DLLEXPORT void *getReferenceTo(CxxInstance *Cxx, void *T)
{
    return Cxx->CI->getASTContext().getLValueReferenceType(clang::QualType::getFromOpaquePtr(T)).getAsOpaquePtr();
}

JL_DLLEXPORT void *getRvalueReferenceTo(CxxInstance *Cxx, void *T)
{
    return Cxx->CI->getASTContext().getRValueReferenceType(clang::QualType::getFromOpaquePtr(T)).getAsOpaquePtr();
}

JL_DLLEXPORT void *getIncompleteArrayType(CxxInstance *Cxx, void *T)
{
    return Cxx->CI->getASTContext().getIncompleteArrayType(
      clang::QualType::getFromOpaquePtr(T),
      clang::ArrayType::Normal, 0).getAsOpaquePtr();
}

JL_DLLEXPORT void *createDerefExpr(CxxInstance *Cxx, clang::Expr *expr)
{
  return (void*)Cxx->CI->getSema().CreateBuiltinUnaryOp(getTrivialSourceLocation(Cxx),clang::UO_Deref,expr).get();
}

JL_DLLEXPORT void *createAddrOfExpr(CxxInstance *Cxx, clang::Expr *expr)
{
  return (void*)Cxx->CI->getSema().CreateBuiltinUnaryOp(getTrivialSourceLocation(Cxx),clang::UO_AddrOf,expr).get();
}

JL_DLLEXPORT void *createCast(CxxInstance *Cxx,clang::Expr *expr, clang::Type *t, int kind)
{
  return clang::ImplicitCastExpr::Create(Cxx->CI->getASTContext(),clang::QualType(t,0),
    (clang::CastKind)kind,expr,NULL,clang::VK_RValue);
}

JL_DLLEXPORT void *CreateBinOp(CxxInstance *Cxx, clang::Scope *S, int opc, clang::Expr *LHS, clang::Expr *RHS)
{
  return (void*)Cxx->CI->getSema().BuildBinOp(S,clang::SourceLocation(),(clang::BinaryOperatorKind)opc,LHS,RHS).get();
}

JL_DLLEXPORT void *BuildMemberReference(CxxInstance *Cxx, clang::Expr *base, clang::Type *t, int IsArrow, char *name)
{
    clang::DeclarationName DName(&Cxx->CI->getASTContext().Idents.get(name));
    clang::Sema &sema = Cxx->CI->getSema();
    clang::CXXScopeSpec scope;
    return (void*)sema.BuildMemberReferenceExpr(base,clang::QualType(t,0), getTrivialSourceLocation(Cxx), IsArrow, scope,
      getTrivialSourceLocation(Cxx), nullptr, clang::DeclarationNameInfo(DName, getTrivialSourceLocation(Cxx)), nullptr, nullptr).get();
}

JL_DLLEXPORT void *BuildDeclarationNameExpr(CxxInstance *Cxx, char *name, clang::DeclContext *ctx)
{
    clang::Sema &sema = Cxx->CI->getSema();
    clang::SourceManager &sm = Cxx->CI->getSourceManager();
    clang::CXXScopeSpec spec;
    spec.setBeginLoc(sm.getLocForStartOfFile(sm.getMainFileID()));
    spec.setEndLoc(sm.getLocForStartOfFile(sm.getMainFileID()));
    clang::DeclarationName DName(&Cxx->CI->getASTContext().Idents.get(name));
    sema.RequireCompleteDeclContext(spec,ctx);
    clang::LookupResult R(sema, DName, getTrivialSourceLocation(Cxx), clang::Sema::LookupAnyName);
    sema.LookupQualifiedName(R, ctx, false);
    return (void*)sema.BuildDeclarationNameExpr(spec,R,false).get();
}

JL_DLLEXPORT void *clang_get_builder(CxxInstance *Cxx)
{
    return (void*)&Cxx->CGF->Builder;
}

JL_DLLEXPORT void *jl_get_llvmc()
{
    return &jl_LLVMContext;
}

JL_DLLEXPORT void cdump(void *decl)
{
    ((clang::Decl*) decl)->dump();
}

JL_DLLEXPORT void dcdump(clang::DeclContext *DC)
{
    DC->dumpDeclContext();
}

JL_DLLEXPORT void exprdump(void *expr)
{
    ((clang::Expr*) expr)->dump();
}

JL_DLLEXPORT void typedump(void *t)
{
    ((clang::Type*) t)->dump();
}

JL_DLLEXPORT void llvmdump(void *t)
{
    ((llvm::Value*) t)->print(llvm::errs(), false);
}

JL_DLLEXPORT void llvmtdump(void *t)
{
    ((llvm::Type*) t)->print(llvm::errs(), false);
}

JL_DLLEXPORT void *createLoad(CxxIRBuilder *builder, llvm::Value *val)
{
    return builder->CreateLoad(val);
}

JL_DLLEXPORT void *CreateConstGEP1_32(CxxIRBuilder *builder, llvm::Value *val, uint32_t idx)
{
    return (void*)builder->CreateConstGEP1_32(val,idx);
}

#define TMember(s)              \
JL_DLLEXPORT int s(clang::Type *t) \
{                               \
  return t->s();                \
}

TMember(isVoidType)
TMember(isBooleanType)
TMember(isPointerType)
TMember(isFunctionPointerType)
TMember(isFunctionType)
TMember(isFunctionProtoType)
TMember(isMemberFunctionPointerType)
TMember(isReferenceType)
TMember(isCharType)
TMember(isIntegerType)
TMember(isEnumeralType)
TMember(isFloatingType)
TMember(isDependentType)
TMember(isTemplateTypeParmType)
TMember(isArrayType)

JL_DLLEXPORT int isTemplateSpecializationType(clang::Type *t) {
  return isa<clang::TemplateSpecializationType>(t);
}

JL_DLLEXPORT int isElaboratedType(clang::Type *t) {
  return isa<clang::ElaboratedType>(t);
}

JL_DLLEXPORT void *isIncompleteType(clang::Type *t)
{
    clang::NamedDecl *ND = NULL;
    t->isIncompleteType(&ND);
    return ND;
}

#define W(M,ARG)              \
JL_DLLEXPORT void *M(ARG *p)     \
{                             \
  return (void *)p->M();      \
}

W(getPointeeCXXRecordDecl, clang::Type)
W(getAsCXXRecordDecl, clang::Type)

#define ISAD(NS,T,ARGT)             \
JL_DLLEXPORT int isa ## T(ARGT *p)      \
{                                   \
  return llvm::isa<NS::T>(p);       \
}                                   \
JL_DLLEXPORT void *dcast ## T(ARGT *p)  \
{                                   \
  return llvm::dyn_cast<NS::T>(p);  \
}

ISAD(clang,ClassTemplateSpecializationDecl,clang::Decl)
ISAD(clang,CXXRecordDecl,clang::Decl)
ISAD(clang,NamespaceDecl,clang::Decl)
ISAD(clang,VarDecl,clang::Decl)
ISAD(clang,ValueDecl,clang::Decl)
ISAD(clang,FunctionDecl,clang::Decl)
ISAD(clang,TypeDecl,clang::Decl)
ISAD(clang,CXXMethodDecl,clang::Decl)
ISAD(clang,CXXConstructorDecl,clang::Decl)

JL_DLLEXPORT int isVoidTy(llvm::Type *t)
{
  return t->isVoidTy();
}

JL_DLLEXPORT void *getI8PtrTy()
{
  return Type::getInt8PtrTy(jl_LLVMContext, 0);
}

JL_DLLEXPORT void *getPRJLValueTy()
{
  return T_prjlvalue;
}

JL_DLLEXPORT void *getUndefValue(llvm::Type *t)
{
  return (void*)llvm::UndefValue::get(t);
}

JL_DLLEXPORT void *getStructElementType(llvm::Type *t, uint32_t i)
{
  return (void*)t->getStructElementType(i);
}

JL_DLLEXPORT void *CreateRet(CxxIRBuilder *builder, llvm::Value *ret)
{
  return (void*)builder->CreateRet(ret);
}

JL_DLLEXPORT void *CreateRetVoid(CxxIRBuilder *builder)
{
  return (void*)builder->CreateRetVoid();
}

JL_DLLEXPORT void *CreateBitCast(CxxIRBuilder *builder, llvm::Value *val, llvm::Type *type)
{
  return (void*)builder->CreateBitCast(val,type);
}

JL_DLLEXPORT void *CreatePointerFromObjref(CxxInstance *Cxx, CxxIRBuilder *builder, llvm::Value *val)
{
  Type *T_pdjlvalue = PointerType::get(
    cast<PointerType>(T_prjlvalue)->getElementType(), AddressSpace::Derived);
  FunctionType *PFO_fty = FunctionType::get(T_pjlvalue, {T_pdjlvalue}, false);
  Function *PFO = Function::Create(PFO_fty, Function::ExternalLinkage,
                                   "julia.pointer_from_objref", Cxx->shadow);
  return (void*)builder->CreateCall(PFO, {
    builder->CreateAddrSpaceCast(val, T_pdjlvalue)});
}

JL_DLLEXPORT void *CreateZext(CxxIRBuilder *builder, llvm::Value *val, llvm::Type *type)
{
  return (void*)builder->CreateZExt(val,type);
}

JL_DLLEXPORT void *CreateTrunc(CxxIRBuilder *builder, llvm::Value *val, llvm::Type *type)
{
  return (void*)builder->CreateTrunc(val,type);
}

JL_DLLEXPORT void *getConstantIntToPtr(llvm::Constant *CC, llvm::Type *type)
{
  return (void*)ConstantExpr::getIntToPtr(CC,type);
}

JL_DLLEXPORT size_t cxxsizeof(CxxInstance *Cxx, clang::CXXRecordDecl *decl)
{
  clang::CodeGen::CodeGenTypes *cgt = &Cxx->CGM->getTypes();
#ifdef LLVM38
  auto dl = Cxx->shadow->getDataLayout();
#else
  auto dl = Cxx->shadow->getDataLayout();
#endif
  Cxx->CI->getSema().RequireCompleteType(getTrivialSourceLocation(Cxx),
    clang::QualType(decl->getTypeForDecl(),0),0);
  auto t = cgt->ConvertRecordDeclType(decl);
  return dl.getTypeSizeInBits(t)/8;
}

JL_DLLEXPORT size_t cxxsizeofType(CxxInstance *Cxx, void *t)
{
  auto dl = Cxx->shadow->getDataLayout();
  clang::CodeGen::CodeGenTypes *cgt = &Cxx->CGM->getTypes();
  return dl.getTypeSizeInBits(
      cgt->ConvertTypeForMem(clang::QualType::getFromOpaquePtr(t)))/8;
}

JL_DLLEXPORT void *ConvertTypeForMem(CxxInstance *Cxx, void *t)
{
  return (void*)Cxx->CGM->getTypes().ConvertTypeForMem(clang::QualType::getFromOpaquePtr(t));
}

JL_DLLEXPORT void *getValueType(llvm::Value *val)
{
  return (void*)val->getType();
}

JL_DLLEXPORT int isLLVMPointerType(llvm::Type *t)
{
  return t->isPointerTy();
}

JL_DLLEXPORT void *getLLVMPointerTo(llvm::Type *t)
{
  return (void*)t->getPointerTo();
}

JL_DLLEXPORT void *getContext(clang::Decl *d)
{
  return (void*)d->getDeclContext();
}

JL_DLLEXPORT void *getParentContext(clang::DeclContext *DC)
{
  return (void*)DC->getParent();
}

JL_DLLEXPORT void *getCxxMDParent(clang::CXXMethodDecl *CxxMD)
{
  return CxxMD->getParent();
}

JL_DLLEXPORT uint64_t getDCDeclKind(clang::DeclContext *DC)
{
  return (uint64_t)DC->getDeclKind();
}

JL_DLLEXPORT void *getDirectCallee(clang::CallExpr *e)
{
  return (void*)e->getDirectCallee();
}

JL_DLLEXPORT void *getCalleeReturnType(clang::CallExpr *e)
{
  clang::FunctionDecl *fd = e->getDirectCallee();
  if (fd == NULL)
    return NULL;
  return (void*)fd->getReturnType().getAsOpaquePtr();
}

JL_DLLEXPORT void *newCXXScopeSpec(CxxInstance *Cxx)
{
  clang::CXXScopeSpec *scope = new clang::CXXScopeSpec();
  scope->MakeGlobal(Cxx->CI->getASTContext(),getTrivialSourceLocation(Cxx));
  return (void*)scope;
}

JL_DLLEXPORT void deleteCXXScopeSpec(clang::CXXScopeSpec *spec)
{
  delete spec;
}

JL_DLLEXPORT void ExtendNNS(CxxInstance *Cxx,clang::NestedNameSpecifierLocBuilder *builder, clang::NamespaceDecl *d)
{
  builder->Extend(Cxx->CI->getASTContext(),d,getTrivialSourceLocation(Cxx),getTrivialSourceLocation(Cxx));
}

JL_DLLEXPORT void ExtendNNSIdentifier(CxxInstance *Cxx,clang::NestedNameSpecifierLocBuilder *builder, const char *Name)
{
  clang::Preprocessor &PP = Cxx->Parser->getPreprocessor();
  // Get the identifier.
  clang::IdentifierInfo *Id = PP.getIdentifierInfo(Name);
  builder->Extend(Cxx->CI->getASTContext(),Id,getTrivialSourceLocation(Cxx),getTrivialSourceLocation(Cxx));
}

JL_DLLEXPORT void ExtendNNSType(CxxInstance *Cxx,clang::NestedNameSpecifierLocBuilder *builder, void *t)
{
  clang::TypeLocBuilder TLBuilder;
  clang::QualType T = clang::QualType::getFromOpaquePtr(t);
  TLBuilder.push<clang::QualifiedTypeLoc>(T);
  builder->Extend(Cxx->CI->getASTContext(),clang::SourceLocation(),
    TLBuilder.getTypeLocInContext(
      Cxx->CI->getASTContext(),
      T),
    getTrivialSourceLocation(Cxx));
}

JL_DLLEXPORT void *makeFunctionType(CxxInstance *Cxx, void *rt, void **argts, size_t nargs)
{
  clang::QualType T;
  if (rt == NULL) {
    T = Cxx->CI->getASTContext().getAutoType(clang::QualType(),
#ifdef LLVM38
                                             clang::AutoTypeKeyword::DecltypeAuto,
#else
                                 /*decltype(auto)*/true,
#endif
                                 /*IsDependent*/   false);
  } else {
    T = clang::QualType::getFromOpaquePtr(rt);
  }
  clang::QualType *qargs = (clang::QualType *)__builtin_alloca(nargs*sizeof(clang::QualType));
  for (size_t i = 0; i < nargs; ++i)
    qargs[i] = clang::QualType::getFromOpaquePtr(argts[i]);
  clang::FunctionProtoType::ExtProtoInfo EPI;
  return Cxx->CI->getASTContext().getFunctionType(T, llvm::ArrayRef<clang::QualType>(qargs, nargs), EPI).getAsOpaquePtr();
}

JL_DLLEXPORT void *makeMemberFunctionType(CxxInstance *Cxx, void *FT, clang::Type *cls)
{
  return Cxx->CI->getASTContext().getMemberPointerType(clang::QualType::getFromOpaquePtr(FT), cls).getAsOpaquePtr();
}

JL_DLLEXPORT void *getMemberPointerClass(clang::Type *mptr)
{
  return (void*)cast<clang::MemberPointerType>(mptr)->getClass();
}

JL_DLLEXPORT void *getMemberPointerPointee(clang::Type *mptr)
{
  return cast<clang::MemberPointerType>(mptr)->getPointeeType().getAsOpaquePtr();
}

JL_DLLEXPORT void *getFPTReturnType(clang::FunctionProtoType *fpt)
{
  return fpt->getReturnType().getAsOpaquePtr();
}

JL_DLLEXPORT void *getFDReturnType(clang::FunctionDecl *FD)
{
  return FD->getReturnType().getAsOpaquePtr();
}

JL_DLLEXPORT size_t getFPTNumParams(clang::FunctionProtoType *fpt)
{
  return fpt->getNumParams();
}

JL_DLLEXPORT size_t getFDNumParams(clang::FunctionDecl *FD)
{
  return FD->getNumParams();
}

JL_DLLEXPORT void *getFPTParam(clang::FunctionProtoType *fpt, size_t idx)
{
  return fpt->getParamType(idx).getAsOpaquePtr();
}

JL_DLLEXPORT void *getLLVMStructType(llvm::Type **ts, size_t nts)
{
  return (void*)llvm::StructType::get(jl_LLVMContext,ArrayRef<llvm::Type*>(ts,nts));
}

JL_DLLEXPORT void MarkDeclarationsReferencedInExpr(CxxInstance *Cxx,clang::Expr *e)
{
  clang::Sema &sema = Cxx->CI->getSema();
  sema.MarkDeclarationsReferencedInExpr(e, true);
}

JL_DLLEXPORT void *getConstantFloat(llvm::Type *llvmt, double x)
{
  return ConstantFP::get(llvmt,x);
}
JL_DLLEXPORT void *getConstantInt(llvm::Type *llvmt, uint64_t x)
{
  return ConstantInt::get(llvmt,x);
}
JL_DLLEXPORT void *getConstantStruct(llvm::Type *llvmt, llvm::Constant **vals, size_t nvals)
{
  return ConstantStruct::get(cast<StructType>(llvmt),ArrayRef<llvm::Constant*>(vals,nvals));
}

JL_DLLEXPORT const clang::Type *canonicalType(clang::Type *t)
{
  return t->getCanonicalTypeInternal().getTypePtr();
}

JL_DLLEXPORT int builtinKind(clang::Type *t)
{
    assert(isa<clang::BuiltinType>(t));
    return cast<clang::BuiltinType>(t)->getKind();
}

JL_DLLEXPORT int isDeclInvalid(clang::Decl *D)
{
  return D->isInvalidDecl();
}

// Test Support
JL_DLLEXPORT void *clang_get_cgt(CxxInstance *Cxx)
{
  return (void*)&Cxx->CGM->getTypes();
}

JL_DLLEXPORT void *clang_shadow_module(CxxInstance *Cxx)
{
  return (void*)Cxx->shadow;
}

JL_DLLEXPORT int RequireCompleteType(CxxInstance *Cxx,clang::Type *t)
{
  clang::Sema &sema = Cxx->CI->getSema();
  return sema.RequireCompleteType(getTrivialSourceLocation(Cxx),clang::QualType(t,0),0);
}

JL_DLLEXPORT void *CreateTemplatedFunction(CxxInstance *Cxx, char *Name, clang::TemplateParameterList** args, size_t nargs)
{
  clang::DeclSpec DS(Cxx->Parser->getAttrFactory());
  clang::Declarator D(DS, clang::DeclaratorContext::PrototypeContext);
  clang::Preprocessor &PP = Cxx->Parser->getPreprocessor();
  D.getName().setIdentifier(PP.getIdentifierInfo(Name),clang::SourceLocation());
  clang::Sema &sema = Cxx->CI->getSema();
  return sema.ActOnTemplateDeclarator(nullptr,clang::MultiTemplateParamsArg(args,nargs),D);
}

JL_DLLEXPORT void *ActOnTypeParameter(CxxInstance *Cxx, char *Name, unsigned Position)
{
  clang::Sema &sema = Cxx->CI->getSema();
  clang::ParsedType DefaultArg;
  clang::Preprocessor &PP = Cxx->Parser->getPreprocessor();
  clang::Scope S(nullptr,clang::Scope::TemplateParamScope,Cxx->CI->getDiagnostics());
  void *ret = (void*)sema.ActOnTypeParameter(&S, false, clang::SourceLocation(),
                                    clang::SourceLocation(), PP.getIdentifierInfo(Name), clang::SourceLocation(), 0, Position,
                                    clang::SourceLocation(), DefaultArg);
  //sema.ActOnPopScope(clang::SourceLocation(),&S);
  return ret;
}

JL_DLLEXPORT void *CreateAnonymousClass(CxxInstance *Cxx, clang::Decl *Scope)
{
  clang::CXXRecordDecl *RD = clang::CXXRecordDecl::Create(
    Cxx->CI->getASTContext(), clang::TTK_Class,
    clang::dyn_cast<clang::DeclContext>(Scope),
    clang::SourceLocation(), clang::SourceLocation(),
    nullptr);
  RD->setImplicit(true);
  RD->startDefinition();
  return (void*)RD;
}

JL_DLLEXPORT void *AddCallOpToClass(clang::CXXRecordDecl *TheClass, clang::CXXMethodDecl *Method)
{
  TheClass->addDecl(Method);
  return Method;
}

JL_DLLEXPORT void FinalizeAnonClass(CxxInstance *Cxx, clang::CXXRecordDecl *TheClass)
{
  llvm::SmallVector<clang::Decl *, 0> Fields;
  Cxx->CI->getSema().ActOnFields(nullptr, clang::SourceLocation(), TheClass,
                       Fields, clang::SourceLocation(), clang::SourceLocation(), clang::ParsedAttributesView());
  Cxx->CI->getSema().CheckCompletedCXXClass(TheClass);
}


JL_DLLEXPORT void EnterParserScope(CxxInstance *Cxx)
{
  Cxx->Parser->EnterScope(clang::Scope::TemplateParamScope);
}

JL_DLLEXPORT void *ActOnTypeParameterParserScope(CxxInstance *Cxx, char *Name, unsigned Position)
{
  clang::Sema &sema = Cxx->CI->getSema();
  clang::ParsedType DefaultArg;
  clang::Preprocessor &PP = Cxx->Parser->getPreprocessor();
  void *ret = (void*)sema.ActOnTypeParameter(Cxx->Parser->getCurScope(), false, clang::SourceLocation(),
                                    clang::SourceLocation(), PP.getIdentifierInfo(Name), clang::SourceLocation(), 0, Position,
                                    clang::SourceLocation(), DefaultArg);
  //sema.ActOnPopScope(clang::SourceLocation(),&S);
  return ret;
}

JL_DLLEXPORT void ExitParserScope(CxxInstance *Cxx)
{
  Cxx->Parser->ExitScope();
}

JL_DLLEXPORT void *CreateTemplateParameterList(CxxInstance *Cxx, clang::NamedDecl **D, size_t ND)
{
#ifdef LLVM38
  return (void*)clang::TemplateParameterList::Create(Cxx->CI->getASTContext(), clang::SourceLocation(),
    clang::SourceLocation(), ArrayRef<clang::NamedDecl*>(D, ND), clang::SourceLocation()
#ifdef LLVM40
    , nullptr
#endif
    );
#else
  return (void*)clang::TemplateParameterList::Create(Cxx->CI->getASTContext(), clang::SourceLocation(), clang::SourceLocation(), D, ND, clang::SourceLocation());
#endif
}

JL_DLLEXPORT void *CreateFunctionTemplateDecl(CxxInstance *Cxx, clang::DeclContext *DC, clang::TemplateParameterList *Params, clang::FunctionDecl *FD)
{
  clang::FunctionTemplateDecl *FTD = clang::FunctionTemplateDecl::Create(
      Cxx->CI->getASTContext(), DC, clang::SourceLocation(),
      FD->getNameInfo().getName(), Params, FD);
  FD->setDescribedFunctionTemplate(FTD);
  FTD->setAccess(clang::AS_public);
  return (void*)FTD;
}

JL_DLLEXPORT void *GetDescribedFunctionTemplate(clang::FunctionDecl *FD)
{
  return (void*)FD->getDescribedFunctionTemplate();
}

JL_DLLEXPORT void *newFDVector() { return (void*)new std::vector<clang::FunctionDecl*>; }
JL_DLLEXPORT void deleteFDVector(void *v) { delete ((std::vector<clang::FunctionDecl*>*) v); }
JL_DLLEXPORT void copyFDVector(void *to, std::vector<clang::FunctionDecl*> *from)
{
  memcpy(to, from->data(), sizeof(clang::FunctionDecl*)*from->size());
}
JL_DLLEXPORT size_t getFDVectorSize(std::vector<clang::FunctionDecl*> *v) {return v->size(); }

JL_DLLEXPORT void getSpecializations(clang::FunctionTemplateDecl *FTD, std::vector<clang::FunctionDecl*> *specs) {
  for (auto it : FTD->specializations())
    specs->push_back(it);
}

JL_DLLEXPORT const char *getMangledFunctionName(CxxInstance *Cxx,clang::FunctionDecl *D)
{
  return Cxx->CGM->getMangledName(clang::GlobalDecl(D)).data();
}

JL_DLLEXPORT const void *getTemplateSpecializationArgs(clang::FunctionDecl *FD)
{
  return (const void*)FD->getTemplateSpecializationArgs();
}

JL_DLLEXPORT void *getLambdaCallOperator(clang::CXXRecordDecl *R)
{
  return R->getLambdaCallOperator();
}

JL_DLLEXPORT void *getCallOperator(CxxInstance *Cxx, clang::CXXRecordDecl *R)
{
  clang::DeclarationName Name =
    Cxx->CI->getASTContext().DeclarationNames.getCXXOperatorName(clang::OO_Call);
  clang::DeclContext::lookup_result Calls = R->lookup(Name);

  assert(!Calls.empty() && "Missing lambda call operator!");
  assert(Calls.size() == 1 && "More than one lambda call operator!");

  clang::NamedDecl *CallOp = Calls.front();
  if (clang::FunctionTemplateDecl *CallOpTmpl =
                    dyn_cast<clang::FunctionTemplateDecl>(CallOp))
    return cast<clang::CXXMethodDecl>(CallOpTmpl->getTemplatedDecl());

  return cast<clang::CXXMethodDecl>(CallOp);
}

JL_DLLEXPORT bool isCxxDLambda(clang::CXXRecordDecl *R)
{
  return R->isLambda();
}

JL_DLLEXPORT void *getFunctionTypeReturnType(void *T)
{
  return ((clang::FunctionType*)T)->getReturnType().getAsOpaquePtr();
}

/// From SemaOverload.cpp
/// A convenience routine for creating a decayed reference to a function.
static clang::ExprResult
CreateFunctionRefExpr(clang::Sema &S, clang::FunctionDecl *Fn, clang::NamedDecl *FoundDecl,
                      bool HadMultipleCandidates,
                      clang::SourceLocation Loc = clang::SourceLocation(),
                      const clang::DeclarationNameLoc &LocInfo = clang::DeclarationNameLoc()){
  if (S.DiagnoseUseOfDecl(FoundDecl, Loc))
    return clang::ExprError();
  // If FoundDecl is different from Fn (such as if one is a template
  // and the other a specialization), make sure DiagnoseUseOfDecl is
  // called on both.
  // FIXME: This would be more comprehensively addressed by modifying
  // DiagnoseUseOfDecl to accept both the FoundDecl and the decl
  // being used.
  if (FoundDecl != Fn && S.DiagnoseUseOfDecl(Fn, Loc))
    return clang::ExprError();
  clang::DeclRefExpr *DRE = new (S.Context) clang::DeclRefExpr(
                                              S.Context,
                                              Fn,
                                              false,
                                              Fn->getType(),
                                              clang::VK_LValue,
                                              Loc,
                                              LocInfo
                                            );
  if (HadMultipleCandidates)
    DRE->setHadMultipleCandidates(true);

  S.MarkDeclRefReferenced(DRE);

  clang::ExprResult E = DRE;
  E = S.DefaultFunctionArrayConversion(E.get());
  if (E.isInvalid())
    return clang::ExprError();
  return E;
}

JL_DLLEXPORT void *CreateCStyleCast(CxxInstance *Cxx, clang::Expr *E, clang::Type *T)
{
  clang::QualType QT(T,0);
  return (void*)clang::CStyleCastExpr::Create(Cxx->CI->getASTContext(), QT, clang::VK_RValue, clang::CK_BitCast,
    E, nullptr, Cxx->CI->getASTContext().getTrivialTypeSourceInfo(QT), clang::SourceLocation(), clang::SourceLocation());
}

JL_DLLEXPORT void *CreateReturnStmt(CxxInstance *Cxx, clang::Expr *E)
{
  return (void*) clang::ReturnStmt::Create(Cxx->CI->getASTContext(), clang::SourceLocation(), E, nullptr);
}

JL_DLLEXPORT void *CreateThisExpr(CxxInstance *Cxx, void *T)
{
  return (void*)new (Cxx->CI->getASTContext()) clang::CXXThisExpr(
    clang::SourceLocation(), clang::QualType::getFromOpaquePtr(T),
    false);
}

JL_DLLEXPORT void *CreateFunctionRefExprFD(CxxInstance *Cxx, clang::FunctionDecl *FD)
{
  return (void*)CreateFunctionRefExpr(Cxx->CI->getSema(),FD,FD,false).get();
}

JL_DLLEXPORT void *CreateFunctionRefExprFDTemplate(CxxInstance *Cxx, clang::FunctionTemplateDecl *FTD)
{
  return (void*)CreateFunctionRefExpr(Cxx->CI->getSema(),FTD->getTemplatedDecl(),FTD,false).get();
}


JL_DLLEXPORT void SetFDBody(clang::FunctionDecl *FD, clang::Stmt *body)
{
  FD->setBody(body);
}

JL_DLLEXPORT void ActOnFinishFunctionBody(CxxInstance *Cxx,clang::FunctionDecl *FD, clang::Stmt *Body)
{
  Cxx->CI->getSema().ActOnFinishFunctionBody(FD,Body,true);
}

JL_DLLEXPORT void *CreateLinkageSpec(CxxInstance *Cxx, clang::DeclContext *DC, unsigned kind)
{
  return (void *)(clang::DeclContext *)clang::LinkageSpecDecl::Create(Cxx->CI->getASTContext(), DC,
    clang::SourceLocation(), clang::SourceLocation(), (clang::LinkageSpecDecl::LanguageIDs) kind,
    true);
}

JL_DLLEXPORT const char *getLLVMValueName(llvm::Value *V)
{
  return V->getName().data();
}

JL_DLLEXPORT const char *getNDName(clang::NamedDecl *ND)
{
  return ND->getName().data();
}

JL_DLLEXPORT void *getParmVarDecl(clang::FunctionDecl *FD, unsigned i)
{
  return (void *)FD->getParamDecl(i);
}

JL_DLLEXPORT void SetDeclUsed(CxxInstance *Cxx,clang::Decl *D)
{
  D->markUsed(Cxx->CI->getASTContext());
}

JL_DLLEXPORT int IsDeclUsed(clang::Decl *D)
{
  return D->isUsed();
}

JL_DLLEXPORT void *getPointerElementType(llvm::Type *T)
{
  return (void*)T->getPointerElementType ();
}

JL_DLLEXPORT void emitDestroyCXXObject(CxxInstance *Cxx, llvm::Value *x, clang::Type *T)
{
  clang::CXXRecordDecl *RD = T->getAsCXXRecordDecl();
  clang::CXXDestructorDecl *Destructor = Cxx->CI->getSema().LookupDestructor(RD);
  Cxx->CI->getSema().MarkFunctionReferenced(clang::SourceLocation(), Destructor);
  Cxx->CI->getSema().DefineUsedVTables();
  Cxx->CI->getSema().PerformPendingInstantiations(false);
  Cxx->CGF->destroyCXXObject(*Cxx->CGF,
#ifdef LLVM38
                             clang::CodeGen::Address(x,clang::CharUnits::One()),
#else
                             x,
#endif
                             clang::QualType(T,0));
}

JL_DLLEXPORT bool hasTrivialDestructor(CxxInstance *Cxx, clang::CXXRecordDecl *RD)
{
  clang::CXXScopeSpec spec;
  spec.setBeginLoc(getTrivialSourceLocation(Cxx));
  clang::Sema &cs = Cxx->CI->getSema();
  cs.RequireCompleteDeclContext(spec,RD);
  return RD->hasTrivialDestructor();
}

JL_DLLEXPORT void setPersonality(llvm::Function *F, llvm::Function *PersonalityF)
{
  F->setPersonalityFn(PersonalityF);
}

JL_DLLEXPORT void *getFunction(CxxInstance *Cxx, char *name, size_t length)
{
  return Cxx->shadow->getFunction(llvm::StringRef(name,length));
}

JL_DLLEXPORT int hasFDBody(clang::FunctionDecl *FD)
{
  return FD->hasBody();
}

JL_DLLEXPORT void *getUnderlyingTemplateDecl(clang::TemplateSpecializationType *TST)
{
  return (void*)TST->getTemplateName().getAsTemplateDecl();
}

JL_DLLEXPORT void *getOrCreateTemplateSpecialization(CxxInstance *Cxx, clang::FunctionTemplateDecl *FTD, void **T, size_t nargs)
{
  clang::TemplateArgumentListInfo TALI;
  clang::sema::TemplateDeductionInfo Info(clang::SourceLocation{});
  clang::FunctionDecl *FD;
  for (int i = 0; i < nargs; ++i) {
    clang::QualType QT = clang::QualType::getFromOpaquePtr(T[i]);
    clang::TemplateArgumentLoc TAL(
        clang::TemplateArgument{QT},
        Cxx->CI->getASTContext().getTrivialTypeSourceInfo(QT));
    TALI.addArgument(TAL);
  }
  Cxx->CI->getSema().DeduceTemplateArguments(FTD, &TALI, FD, Info, false);
  return FD;
}

JL_DLLEXPORT void *CreateIntegerLiteral(CxxInstance *Cxx, uint64_t val, void *T)
{
  clang::QualType QT = clang::QualType::getFromOpaquePtr(T);
  return (void*)clang::IntegerLiteral::Create(Cxx->CI->getASTContext(),
    llvm::APInt(8*sizeof(uint64_t),val), QT, clang::SourceLocation());
}

JL_DLLEXPORT void *desugarElaboratedType(clang::ElaboratedType *T)
{
  return (void *)T->desugar().getAsOpaquePtr();
}

JL_DLLEXPORT unsigned getTTPTIndex(clang::TemplateTypeParmType *TTPT)
{
  return TTPT->getIndex();
}

JL_DLLEXPORT void *getTemplatedDecl(clang::TemplateDecl *TD)
{
  return TD->getTemplatedDecl();
}

JL_DLLEXPORT void *getEmptyStructType()
{
  return (void*)StructType::get(jl_LLVMContext);
}

JL_DLLEXPORT void *getUnderlyingTypeOfEnum(clang::Type *T)
{
  return (void*)clang::cast<clang::EnumType>(T)->getDecl()->getIntegerType().getAsOpaquePtr();
}

JL_DLLEXPORT void SetVarDeclInit(clang::VarDecl *VD, clang::Expr *Init)
{
  return VD->setInit(Init);
}

JL_DLLEXPORT void SetConstexpr(clang::VarDecl *VD)
{
  VD->setConstexpr(true);
}

JL_DLLEXPORT void InsertIntoShadowModule(CxxInstance *Cxx, llvm::Function *F)
{
  // Copy the declaration characteristics of the Function (not the body)
  Function *NewF = Function::Create(F->getFunctionType(),
                                    Function::ExternalLinkage,
                                    F->getName(), Cxx->shadow);
  // FunctionType does not include any attributes. Copy them over manually
  // as codegen may make decisions based on the presence of certain attributes
  NewF->copyAttributesFrom(F);

#ifdef LLVM37
  // Declarations are not allowed to have personality routines, but
  // copyAttributesFrom sets them anyway, so clear them again manually
  NewF->setPersonalityFn(nullptr);
#endif

#ifdef LLVM35
  // DLLImport only needs to be set for the shadow module
  // it just gets annoying in the JIT
  NewF->setDLLStorageClass(GlobalValue::DefaultStorageClass);
#endif
}

extern void *jl_pchar_to_string(const char *str, size_t len);
JL_DLLEXPORT void *getTypeName(CxxInstance *Cxx, void *Ty)
{
  SmallString<256> OutName;
  llvm::raw_svector_ostream Out(OutName);
  Cxx->CGM->getCXXABI().
    getMangleContext().mangleCXXRTTIName(clang::QualType::getFromOpaquePtr(Ty), Out);
  StringRef Name = OutName.str();
  StringRef ActualName = Name.substr(4);
  return jl_pchar_to_string(ActualName.data(), ActualName.size());
}

// Exception handling
extern void jl_error(const char *str);

#include "unwind.h"
void __attribute__((noreturn)) (*process_cxx_exception)(uint64_t exceptionClass, _Unwind_Exception* unwind_exception);
_Unwind_Reason_Code __cxxjl_personality_v0
                    (int version, _Unwind_Action actions, uint64_t exceptionClass,
                     _Unwind_Exception* unwind_exception, _Unwind_Context* context)
{
  // Catch all exceptions
  if (actions & _UA_SEARCH_PHASE)
    return _URC_HANDLER_FOUND;

  (*process_cxx_exception)(exceptionClass,unwind_exception);
}

} // extern "C"

/*
 * Yes, yes, I know. Once Cxx settles down, I'll try to get this into clang.
 * Until then, yay templates
 */

template <class Tag>
struct stowed
{
     static typename Tag::type value;
};
template <class Tag>
typename Tag::type stowed<Tag>::value;

template <class Tag, typename Tag::type x>
struct stow_private
{
     stow_private() { stowed<Tag>::value = x; }
     static stow_private instance;
};
template <class Tag, typename Tag::type x>
stow_private<Tag,x> stow_private<Tag,x>::instance;


typedef llvm::DenseMap<const clang::Type*, llvm::StructType *> TMap;
typedef llvm::DenseMap<const clang::Type*, clang::CodeGen::CGRecordLayout *> CGRMap;

extern "C" {

// A tag type for A::x.  Each distinct private member you need to
// access should have its own tag.  Each tag should contain a
// nested ::type that is the corresponding pointer-to-member type.
struct CodeGenTypes_RecordDeclTypes { typedef TMap (clang::CodeGen::CodeGenTypes::*type); };
struct CodeGenTypes_CGRecordLayouts { typedef CGRMap (clang::CodeGen::CodeGenTypes::*type); };
template class stow_private<CodeGenTypes_RecordDeclTypes,&clang::CodeGen::CodeGenTypes::RecordDeclTypes>;
template class stow_private<CodeGenTypes_CGRecordLayouts,&clang::CodeGen::CodeGenTypes::CGRecordLayouts>;

void RegisterType(CxxInstance *Cxx, clang::TagDecl *D, llvm::StructType *ST)
{
  clang::RecordDecl *RD;
  if(isa<clang::TypedefNameDecl>(D))
  {
    RD = dyn_cast<clang::RecordDecl>(
      dyn_cast<clang::TypedefNameDecl>(D)->getUnderlyingType()->getAsTagDecl());
  } else {
    RD = cast<clang::RecordDecl>(D);
  }
  const clang::Type *Key = Cxx->CI->getASTContext().getTagDeclType(RD).getCanonicalType().getTypePtr();
  (Cxx->CGM->getTypes().*stowed<CodeGenTypes_RecordDeclTypes>::value)[Key] = ST;
  llvm::StructType *FakeST = llvm::StructType::create(jl_LLVMContext);
  (Cxx->CGM->getTypes().*stowed<CodeGenTypes_CGRecordLayouts>::value)[Key] =
    Cxx->CGM->getTypes().ComputeRecordLayout(RD,FakeST);
}

JL_DLLEXPORT bool isDCComplete(clang::DeclContext *DC) {
  return (!clang::isa<clang::TagDecl>(DC) || DC->isDependentContext() || clang::cast<clang::TagDecl>(DC)->isCompleteDefinition() || clang::cast<clang::TagDecl>(DC)->isBeingDefined());
}

} // extern "C"

#ifndef _OS_WINDOWS_
#include <signal.h>
static void jl_unblock_signal(int sig)
{
    // Put in a separate function to save some stack space since
    // sigset_t can be pretty big.
    sigset_t sset;
    sigemptyset(&sset);
    sigaddset(&sset, sig);
    sigprocmask(SIG_UNBLOCK, &sset, NULL);
}

extern "C" {
void *theexception;
extern void jl_throw(void *);
void abrt_handler(int sig, siginfo_t *info, void *)
{
  jl_unblock_signal(sig);
  jl_throw(theexception);
}

JL_DLLEXPORT void InstallSIGABRTHandler(void *exception)
{
  theexception = exception;
  struct sigaction act;
  memset(&act, 0, sizeof(struct sigaction));
  sigemptyset(&act.sa_mask);
  act.sa_sigaction = abrt_handler;
  act.sa_flags = SA_ONSTACK | SA_SIGINFO;
  if (sigaction(SIGABRT, &act, NULL) < 0) {
    abort(); // hah
  }
}
} // extern "C"
#endif // _OS_WINDOWS_

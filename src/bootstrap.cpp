#undef B0 //rom termios
#define __STDC_LIMIT_MACROS
#define __STDC_CONSTANT_MACROS

#include <iostream>

// LLVM includes
#include "llvm/ADT/DenseMapInfo.h"
#include "llvm/Bitcode/ReaderWriter.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/Support/Host.h"
#include <llvm/ExecutionEngine/ExecutionEngine.h>
#include "llvm/IR/ValueMap.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/IR/IRBuilder.h"


// Clang includes
#include "clang/Sema/ScopeInfo.h"
#include "clang/AST/ASTContext.h"
// Well, yes this is cheating
#define private public
#include "clang/Parse/Parser.h"
#undef private
#include "clang/Parse/ParseDiagnostic.h"
#include "clang/AST/RecursiveASTVisitor.h"
#include "clang/AST/StmtVisitor.h"
#include "clang/AST/DeclVisitor.h"
#include "clang/AST/ASTConsumer.h"
#include "clang/Frontend/ASTUnit.h"
#include "clang/Analysis/DomainSpecific/CocoaConventions.h"
#include "clang/Basic/Diagnostic.h"
#include "clang/Basic/SourceManager.h"
#include "clang/Basic/TargetInfo.h"
#include "clang/Lex/Preprocessor.h"
#include "clang/Lex/HeaderSearch.h"
#include "clang/Parse/ParseAST.h"
#include "clang/Lex/Lexer.h"
#include "clang/Sema/Sema.h"
#include "clang/Frontend/FrontendAction.h"
#include "clang/Sema/SemaDiagnostic.h"
#include "clang/Sema/Lookup.h"
#include "clang/Sema/Initialization.h"
#include "clang/Sema/PrettyDeclStackTrace.h"
#include "Sema/TypeLocBuilder.h"
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Frontend/CodeGenOptions.h>
#include <clang/AST/Type.h>
#include <clang/AST/ASTContext.h>
#include <clang/AST/DeclTemplate.h>
#include <clang/Basic/Specifiers.h>

#include "CodeGen/CodeGenModule.h"
#include <CodeGen/CodeGenTypes.h>
#define private public
#include <CodeGen/CodeGenFunction.h>
#undef private
#include "CodeGen/CGCXXABI.h"

#include "dtypes.h"

#if defined(LLVM_VERSION_MAJOR) && LLVM_VERSION_MAJOR == 3 && LLVM_VERSION_MINOR >= 6
#define LLVM36 1
#endif

// From julia
using namespace llvm;
extern ExecutionEngine *jl_ExecutionEngine;
extern llvm::LLVMContext &jl_LLVMContext;

static DataLayout *TD;

class JuliaCodeGenerator;

struct CxxInstance {
  llvm::Module *shadow;
  clang::CompilerInstance *CI;
  clang::CodeGen::CodeGenModule *CGM;
  clang::CodeGen::CodeGenFunction *CGF;
  clang::Parser *Parser;
  JuliaCodeGenerator *JCodeGen;
};
#define C CxxInstance *Cxx

extern "C" {
  #define TYPE_ACCESS(EX,IN)                                    \
  DLLEXPORT const clang::Type *EX(C) {                          \
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
  TYPE_ACCESS(cT_int64,LongLongTy)
  TYPE_ACCESS(cT_uint64,UnsignedLongLongTy)
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
clang::SourceLocation getTrivialSourceLocation(C)
{
    clang::SourceManager &sm = Cxx->CI->getSourceManager();
    return sm.getLocForStartOfFile(sm.getMainFileID());
}

extern "C" {

extern void jl_error(const char *str);

// For initialization.jl
DLLEXPORT void add_directory(C, int kind, int isFramework, const char *dirname)
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

DLLEXPORT int _cxxparse(C)
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

    return 1;
}

DLLEXPORT void *ParseTypeName(C, int ParseAlias = false)
{
  if (Cxx->Parser->getPreprocessor().isIncrementalProcessingEnabled() &&
    Cxx->Parser->getCurToken().is(clang::tok::eof))
    Cxx->Parser->ConsumeToken();
  return (void*)Cxx->Parser->ParseTypeName(nullptr, ParseAlias ?
      clang::Declarator::AliasTemplateContext : clang::Declarator::TypeNameContext).get().getAsOpaquePtr();
}

DLLEXPORT int cxxinclude(C, char *fname, int isAngled)
{
    const clang::DirectoryLookup *CurDir;
    clang::FileManager &fm = Cxx->CI->getFileManager();
    clang::Preprocessor &P = Cxx->CI->getPreprocessor();

    const clang::FileEntry *File = P.LookupFile(
      getTrivialSourceLocation(Cxx), fname,
      isAngled, P.GetCurDirLookup(), nullptr, CurDir, nullptr,nullptr, nullptr);

    if(!File)
      return 0;

    clang::SourceManager &sm = Cxx->CI->getSourceManager();

    clang::FileID FID = sm.createFileID(File, sm.getLocForStartOfFile(sm.getMainFileID()), P.getHeaderSearchInfo().getFileDirFlavor(File));

    P.EnterSourceFile(FID, CurDir, sm.getLocForStartOfFile(sm.getMainFileID()));
    return _cxxparse(Cxx);
}

/*
 * Collect all global initializers into one llvm::Function, which
 * we can then call.
 */
DLLEXPORT llvm::Function *CollectGlobalConstructors(C)
{
    clang::CodeGen::CodeGenModule::CtorList &ctors = Cxx->CGM->getGlobalCtors();
    if (ctors.empty()) {
        return NULL;
    }

    // First create the function into which to collect
    llvm::Function *InitF = Function::Create(
      llvm::FunctionType::get(
          llvm::Type::getVoidTy(jl_LLVMContext),
          false),
      llvm::GlobalValue::ExternalLinkage,
      "",
      Cxx->shadow
      );
    llvm::IRBuilder<true> builder(BasicBlock::Create(jl_LLVMContext, "top", InitF));

    for (auto ctor : ctors) {
        builder.CreateCall(ctor.Initializer, {});
    }

    builder.CreateRetVoid();

    ctors.clear();

    return InitF;
}

DLLEXPORT void EnterSourceFile(C, char *data, size_t length)
{
    const clang::DirectoryLookup *CurDir = nullptr;
    clang::FileManager &fm = Cxx->CI->getFileManager();
    clang::SourceManager &sm = Cxx->CI->getSourceManager();
    clang::FileID FID = sm.createFileID(llvm::MemoryBuffer::getMemBuffer(llvm::StringRef(data,length)),clang::SrcMgr::C_User,
      0,0,sm.getLocForStartOfFile(sm.getMainFileID()));
    clang::Preprocessor &P = Cxx->Parser->getPreprocessor();
    P.EnterSourceFile(FID, CurDir, sm.getLocForStartOfFile(sm.getMainFileID()));
}

DLLEXPORT void EnterVirtualFile(C, char *data, size_t length, char *VirtualPath, size_t PathLength)
{
    const clang::DirectoryLookup *CurDir = nullptr;
    clang::FileManager &fm = Cxx->CI->getFileManager();
    clang::SourceManager &sm = Cxx->CI->getSourceManager();
    llvm::StringRef FileName(VirtualPath, PathLength);
    llvm::StringRef Code(data,length);
    std::unique_ptr<llvm::MemoryBuffer> Buf =
      llvm::MemoryBuffer::getMemBuffer(Code, FileName);
    const clang::FileEntry *Entry =
        fm.getVirtualFile(FileName, Buf->getBufferSize(), 0);
    sm.overrideFileContents(Entry, std::move(Buf));
    clang::FileID FID = sm.createFileID(Entry,sm.getLocForStartOfFile(sm.getMainFileID()),clang::SrcMgr::C_User);
    clang::Preprocessor &P = Cxx->Parser->getPreprocessor();
    P.EnterSourceFile(FID, CurDir, sm.getLocForStartOfFile(sm.getMainFileID()));
}

DLLEXPORT int cxxparse(C, char *data, size_t length)
{
    EnterSourceFile(Cxx, data, length);
    return _cxxparse(Cxx);
}

DLLEXPORT void defineMacro(C,const char *Name)
{
  clang::Preprocessor &PP = Cxx->Parser->getPreprocessor();
  // Get the identifier.
  clang::IdentifierInfo *Id = PP.getIdentifierInfo(Name);

  clang::MacroInfo *MI = PP.AllocateMacroInfo(getTrivialSourceLocation(Cxx));

  PP.appendDefMacroDirective(Id, MI);
}

// For typetranslation.jl
DLLEXPORT bool BuildNNS(C, clang::CXXScopeSpec *spec, const char *Name)
{
  clang::Preprocessor &PP = Cxx->CI->getPreprocessor();
  // Get the identifier.
  clang::IdentifierInfo *Id = PP.getIdentifierInfo(Name);
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
}

DLLEXPORT void *lookup_name(C, char *name, clang::DeclContext *ctx)
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
    cs.LookupQualifiedName(R, ctx, false);
    return R.empty() ? NULL : R.getRepresentativeDecl();
}

DLLEXPORT void *SpecializeClass(C, clang::ClassTemplateDecl *tmplt, void **types, uint64_t *integralValues,int8_t *integralValuePresent, size_t nargs)
{
  clang::TemplateArgument *targs = new clang::TemplateArgument[nargs];
  for (size_t i = 0; i < nargs; ++i) {
    if (integralValuePresent[i] == 1)
      targs[i] = clang::TemplateArgument(Cxx->CI->getASTContext(),
        llvm::APSInt(llvm::APInt(8,integralValues[i])),clang::QualType::getFromOpaquePtr(types[i]));
    else
      targs[i] = clang::TemplateArgument(clang::QualType::getFromOpaquePtr(types[i]));
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
                            tmplt->getTemplatedDecl()->getLocStart(),
                            tmplt->getLocation(),
                            tmplt,
                            targs,
                            nargs, nullptr);
    tmplt->AddSpecialization(ret, InsertPos);
    if (tmplt->isOutOfLine())
      ret->setLexicalDeclContext(tmplt->getLexicalDeclContext());
  }
  delete[] targs;
  return ret;
}

DLLEXPORT void *typeForDecl(clang::Decl *D)
{
    clang::TypeDecl *ty = dyn_cast<clang::TypeDecl>(D);
    if (ty == NULL)
      return NULL;
    return (void *)ty->getTypeForDecl();
}

DLLEXPORT void *withConst(void *T)
{
    return clang::QualType::getFromOpaquePtr(T).withConst().getAsOpaquePtr();
}

DLLEXPORT void *withVolatile(void *T)
{
    return clang::QualType::getFromOpaquePtr(T).withVolatile().getAsOpaquePtr();
}

DLLEXPORT void *withRestrict(void *T)
{
    return clang::QualType::getFromOpaquePtr(T).withRestrict().getAsOpaquePtr();
}

DLLEXPORT char *decl_name(clang::NamedDecl *decl)
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

DLLEXPORT char *simple_decl_name(clang::NamedDecl *decl)
{
    std::string str = decl->getNameAsString().data();
    char * cstr = (char*)malloc(str.length()+1);
    std::strcpy (cstr, str.c_str());
    return cstr;
}

// For cxxstr
DLLEXPORT void *createNamespace(C,char *name)
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

DLLEXPORT void SetDeclInitializer(C, clang::VarDecl *D, llvm::Constant *CI)
{
    llvm::Constant *Const = Cxx->CGM->GetAddrOfGlobalVar(D);
    if (!isa<llvm::GlobalVariable>(Const))
      jl_error("Clang did not create a global variable for the given VarDecl");
    llvm::GlobalVariable *GV = cast<llvm::GlobalVariable>(Const);
    GV->setInitializer(ConstantExpr::getBitCast(CI, GV->getType()->getElementType()));
    GV->setConstant(true);
}

DLLEXPORT void *GetAddrOfFunction(C, clang::FunctionDecl *D)
{
  return (void*)Cxx->CGM->GetAddrOfFunction(D);
}

DLLEXPORT void ReplaceFunctionForDecl(C,clang::FunctionDecl *D, llvm::Function *F)
{
  llvm::Constant *Const = Cxx->CGM->GetAddrOfFunction(D);
  if (!isa<llvm::Function>(Const))
    jl_error("Clang did not create function for the given FunctionDecl");
  llvm::Function *OF = cast<llvm::Function>(Const);
  llvm::ValueToValueMapTy VMap;
  llvm::ClonedCodeInfo CCI;
  llvm::Function *NF = llvm::CloneFunction(F,VMap,true,&CCI);
  // TODO: Ideally we would delete the cloned function
  // once we're done with the inlineing, but clang delays
  // emitting some functions (e.g. constructors) until
  // they're used.
  Cxx->shadow->getFunctionList().push_back(NF);
  StringRef Name = OF->getName();
  OF->replaceAllUsesWith(NF);
  OF->removeFromParent();
  NF->setName(Name);
  while (true)
  {
    if (NF->getNumUses() == 0)
      return;
    Value::user_iterator I = NF->user_begin();
    if (llvm::isa<llvm::CallInst>(*I)) {
      llvm::InlineFunctionInfo IFI;
      llvm::InlineFunction(cast<llvm::CallInst>(*I),IFI,true);
    } else {
      jl_error("Tried to do something other than calling it to a julia expression");
    }
  }
}

DLLEXPORT void *ActOnStartOfFunction(C, clang::FunctionDecl *D, bool ScopeIsNull = false)
{
  clang::Sema &sema = Cxx->CI->getSema();
  //ContextRAII SavedContext(sema, DC);
  return (void*)sema.ActOnStartOfFunctionDef(ScopeIsNull ? nullptr : Cxx->Parser->getCurScope(), D);
}

DLLEXPORT bool ParseFunctionStatementBody(C, clang::Decl *D)
{
  clang::Parser::ParseScope BodyScope(Cxx->Parser, clang::Scope::FnScope|clang::Scope::DeclScope);
  Cxx->Parser->ConsumeToken();

  clang::Sema &sema = Cxx->CI->getSema();

  // Slightly modified
  assert(Cxx->Parser->getCurToken().is(clang::tok::l_brace));
  clang::SourceLocation LBraceLoc = Cxx->Parser->getCurToken().getLocation();

  clang::PrettyDeclStackTraceEntry CrashInfo(sema, D, LBraceLoc,
                                      "parsing function body");

  // Do not enter a scope for the brace, as the arguments are in the same scope
  // (the function body) as the body itself.  Instead, just read the statement
  // list and put it into a CompoundStmt for safe keeping.
  clang::StmtResult FnBody(Cxx->Parser->ParseCompoundStatementBody(true));

  // If the function body could not be parsed, return an error
  if (FnBody.isInvalid()) {
    return false;
  }

  clang::CompoundStmt *Body = cast<clang::CompoundStmt>(FnBody.get());

  // If we don't yet have a return statement, implicitly return
  // the result of the last statement
  if (cast<clang::FunctionDecl>(D)->getReturnType()->isUndeducedType())
  {
    clang::Stmt *last = Body->body_back();
    if (last && isa<clang::Expr>(last))
      Body->setLastStmt(
        sema.BuildReturnStmt(getTrivialSourceLocation(Cxx), cast<clang::Expr>(last)).get());
  }

  BodyScope.Exit();
  sema.ActOnFinishFunctionBody(D, Body);
  return true;
}

DLLEXPORT void *ActOnStartNamespaceDef(C, char *name)
{
  Cxx->Parser->EnterScope(clang::Scope::DeclScope);
  clang::ParsedAttributes attrs(Cxx->Parser->getAttrFactory());
  return Cxx->CI->getSema().ActOnStartNamespaceDef(
      Cxx->Parser->getCurScope(),
      getTrivialSourceLocation(Cxx),
      getTrivialSourceLocation(Cxx),
      getTrivialSourceLocation(Cxx),
      Cxx->Parser->getPreprocessor().getIdentifierInfo(name),
      getTrivialSourceLocation(Cxx),
      attrs.getList()
      );
}

DLLEXPORT void ActOnFinishNamespaceDef(C, clang::Decl *D)
{
  Cxx->Parser->ExitScope();
  Cxx->CI->getSema().ActOnFinishNamespaceDef(
      D, getTrivialSourceLocation(Cxx)
      );
}

// For codegen.jl

DLLEXPORT int typeconstruct(C,void *type, clang::Expr **rawexprs, size_t nexprs, void **ret)
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
        Result = sema.BuildCXXFunctionalCastExpr(TInfo, getTrivialSourceLocation(Cxx),
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

DLLEXPORT void *BuildCXXNewExpr(C, clang::Type *type, clang::Expr **exprs, size_t nexprs)
{
  clang::QualType Ty = clang::QualType::getFromOpaquePtr(type);
    clang::SourceManager &sm = Cxx->CI->getSourceManager();
  return (void*) Cxx->CI->getSema().BuildCXXNew(clang::SourceRange(),
    false, getTrivialSourceLocation(Cxx),
    clang::MultiExprArg(), getTrivialSourceLocation(Cxx), clang::SourceRange(),
    Ty, Cxx->CI->getASTContext().getTrivialTypeSourceInfo(Ty),
    NULL, clang::SourceRange(sm.getLocForStartOfFile(sm.getMainFileID()),
      sm.getLocForStartOfFile(sm.getMainFileID())),
    new (Cxx->CI->getASTContext()) clang::ParenListExpr(Cxx->CI->getASTContext(),getTrivialSourceLocation(Cxx),
      ArrayRef<clang::Expr*>(exprs, nexprs), getTrivialSourceLocation(Cxx)), false).get();
  //return (clang_astcontext) new clang::CXXNewExpr(clang_astcontext, false, nE, dE, )
}

DLLEXPORT void *EmitCXXNewExpr(C, clang::Expr *E)
{
  assert(isa<clang::CXXNewExpr>(E));
  return (void*)Cxx->CGF->EmitCXXNewExpr(cast<clang::CXXNewExpr>(E));
}

DLLEXPORT void *build_call_to_member(C, clang::Expr *MemExprE,clang::Expr **exprs, size_t nexprs)
{
  if (MemExprE->getType() == Cxx->CI->getASTContext().BoundMemberTy ||
         MemExprE->getType() == Cxx->CI->getASTContext().OverloadTy)
    return (void*)Cxx->CI->getSema().BuildCallToMemberFunction(NULL,
      MemExprE,getTrivialSourceLocation(Cxx),clang::MultiExprArg(exprs,nexprs),getTrivialSourceLocation(Cxx)).get();
  else if(isa<clang::TypoExpr>(MemExprE)) {
    return NULL;
  }
  else {
    return (void*) new (&Cxx->CI->getASTContext()) clang::CXXMemberCallExpr(Cxx->CI->getASTContext(),
        MemExprE,ArrayRef<clang::Expr*>(exprs,nexprs),
        cast<clang::CXXMethodDecl>(cast<clang::MemberExpr>(MemExprE)->getMemberDecl())->getReturnType(),
        clang::VK_RValue,getTrivialSourceLocation(Cxx));
  }
}

DLLEXPORT void *PerformMoveOrCopyInitialization(C, void *rt, clang::Expr *expr)
{
  clang::InitializedEntity Entity = clang::InitializedEntity::InitializeTemporary(
    clang::QualType::getFromOpaquePtr(rt));
  return (void*)Cxx->CI->getSema().PerformMoveOrCopyInitialization(Entity, NULL,
    clang::QualType::getFromOpaquePtr(rt), expr, true).get();
}

// For CxxREPL
DLLEXPORT void *clang_compiler(C)
{
  return (void*)Cxx->CI;
}
DLLEXPORT void *clang_parser(C)
{
  return (void*)Cxx->Parser;
}


// Legacy

static llvm::Type *T_int32;

static bool in_cpp = false;

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
    for (clang::StmtIterator I = Node->children().begin(); I != Node->children().end(); ++I)
      if (*I)
        Visit(*I);
  }

};


class JuliaCodeGenerator : public clang::ASTConsumer {
  public:
    JuliaCodeGenerator(C) : Cxx(*Cxx) {}
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
 DLLEXPORT void *julia_namespace = 0;
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

extern "C" {


DLLEXPORT void init_clang_instance(C, const char *Triple) {
    //copied from http://www.ibm.com/developerworks/library/os-createcompilerllvm2/index.html
    Cxx->CI = new clang::CompilerInstance;
    Cxx->CI->getDiagnosticOpts().ShowColors = 1;
    Cxx->CI->getDiagnosticOpts().ShowPresumedLoc = 1;
    Cxx->CI->createDiagnostics();
    Cxx->CI->getLangOpts().CPlusPlus = 1;
    Cxx->CI->getLangOpts().CPlusPlus11 = 1;
    Cxx->CI->getLangOpts().CPlusPlus14 = 1;
    Cxx->CI->getLangOpts().LineComment = 1;
    Cxx->CI->getLangOpts().Bool = 1;
    Cxx->CI->getLangOpts().WChar = 1;
    Cxx->CI->getLangOpts().C99 = 1;
    Cxx->CI->getLangOpts().RTTI = 1;
    Cxx->CI->getLangOpts().RTTIData = 1;
    Cxx->CI->getLangOpts().ImplicitInt = 0;
    Cxx->CI->getLangOpts().PICLevel = 2;
    Cxx->CI->getLangOpts().Exceptions = 1;          // exception handling
    Cxx->CI->getLangOpts().ObjCExceptions = 1;  //  Objective-C exceptions
    Cxx->CI->getLangOpts().CXXExceptions = 1;   // C++ exceptions

    // TODO: Decide how we want to handle this
    // clang_compiler->getLangOpts().AccessControl = 0;
    Cxx->CI->getPreprocessorOpts().UsePredefines = 1;
    Cxx->CI->getHeaderSearchOpts().UseBuiltinIncludes = 1;
    Cxx->CI->getHeaderSearchOpts().UseLibcxx = 1;
    Cxx->CI->getHeaderSearchOpts().UseStandardSystemIncludes = 1;
    Cxx->CI->getHeaderSearchOpts().UseStandardCXXIncludes = 1;
    Cxx->CI->getCodeGenOpts().setDebugInfo(clang::CodeGenOptions::NoDebugInfo);
    Cxx->CI->getCodeGenOpts().DwarfVersion = 2;
    Cxx->CI->getCodeGenOpts().StackRealignment = 1;
    Cxx->CI->getTargetOpts().Triple = Triple == NULL ? llvm::Triple::normalize(llvm::sys::getProcessTriple()) : Triple;
    Cxx->CI->getTargetOpts().CPU = llvm::sys::getHostCPUName ();
    StringMap< bool > ActiveFeatures;
    std::vector< std::string > Features;
    if (llvm::sys::getHostCPUFeatures(ActiveFeatures)) {
      for (auto &F : ActiveFeatures)
        Features.push_back(std::string(F.second ? "+" : "-") +
                                              std::string(F.first()));
      Cxx->CI->getTargetOpts().Features = Features;
    }
    Cxx->CI->setTarget(clang::TargetInfo::CreateTargetInfo(
      Cxx->CI->getDiagnostics(),
      std::make_shared<clang::TargetOptions>(Cxx->CI->getTargetOpts())));
    clang::TargetInfo &tin = Cxx->CI->getTarget();
    Cxx->CI->createFileManager();
    Cxx->CI->createSourceManager(Cxx->CI->getFileManager());
    Cxx->CI->createPreprocessor(clang::TU_Prefix);
    Cxx->CI->createASTContext();
    Cxx->shadow = new llvm::Module("clangShadow",jl_LLVMContext);
    TD = new DataLayout(tin.getDataLayoutString());
    Cxx->CGM = new clang::CodeGen::CodeGenModule(
        Cxx->CI->getASTContext(),
        Cxx->CI->getHeaderSearchOpts(),
        Cxx->CI->getPreprocessorOpts(),
        Cxx->CI->getCodeGenOpts(),
        *Cxx->shadow,
        Cxx->CI->getDiagnostics());
    Cxx->CGF = new clang::CodeGen::CodeGenFunction(*Cxx->CGM);
    Cxx->CGF->CurFuncDecl = NULL;
    Cxx->CGF->CurCodeDecl = NULL;

    // Cxx isn't fully initialized yet, but that's fine since JuliaCodeGenerator does
    // not need the parser
    Cxx->JCodeGen = new JuliaCodeGenerator(Cxx);
    Cxx->CI->setASTConsumer(std::unique_ptr<clang::ASTConsumer>(Cxx->JCodeGen));

    Cxx->CI->createSema(clang::TU_Prefix,NULL);
    Cxx->CI->getSema().addExternalSource(new JuliaSemaSource());

    T_int32 = Type::getInt32Ty(jl_LLVMContext);

    clang::Sema &sema = Cxx->CI->getSema();
    clang::Preprocessor &pp = Cxx->CI->getPreprocessor();
    Cxx->Parser = new clang::Parser(pp, sema, false);

    Cxx->CI->getDiagnosticClient().BeginSourceFile(Cxx->Parser->getLangOpts(), 0);
    pp.getBuiltinInfo().initializeBuiltins(pp.getIdentifierTable(),
                                           Cxx->Parser->getLangOpts());
    pp.enableIncrementalProcessing();

    clang::SourceManager &sm = Cxx->CI->getSourceManager();
    sm.setMainFileID(sm.createFileID(llvm::MemoryBuffer::getNewMemBuffer(0), clang::SrcMgr::C_User));

    sema.getPreprocessor().EnterMainSourceFile();
    Cxx->Parser->Initialize();
}

static llvm::Module *cur_module = NULL;
static llvm::Function *cur_func = NULL;


DLLEXPORT void *setup_cpp_env(C, void *jlfunc)
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

DLLEXPORT bool EmitTopLevelDecl(C, clang::Decl *D)
{
    return Cxx->JCodeGen->EmitTopLevelDecl(D);
}

DLLEXPORT void cleanup_cpp_env(C, cppcall_state_t *state)
{
    //assert(in_cpp == true);
    //in_cpp = false;

    Cxx->CGF->ReturnValue = nullptr;
    Cxx->CGF->Builder.ClearInsertionPoint();
    Cxx->CGF->FinishFunction(getTrivialSourceLocation(Cxx));
    Cxx->CGF->ReturnBlock.getBlock()->eraseFromParent();
    Cxx->CGF->ReturnBlock = Cxx->CGF->getJumpDestInCurrentScope(
      Cxx->CGF->createBasicBlock("return"));

    Cxx->CI->getSema().DefineUsedVTables();
    Cxx->CI->getSema().PerformPendingInstantiations(false);
    Cxx->CGM->Release();

    // Set all functions and globals to external linkage (MCJIT needs this ugh)
    //for(Module::global_iterator I = jl_Module->global_begin(),
    //        E = jl_Module->global_end(); I != E; ++I) {
    //    I->setLinkage(llvm::GlobalVariable::ExternalLinkage);
    //}

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
    Cxx->CI->getSema().ExprNeedsCleanups = false;

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
DLLEXPORT void *CreateCallExpr(C, clang::Expr *Fn,clang::Expr **exprs, size_t nexprs)
{
    return Cxx->CI->getSema().ActOnCallExpr(NULL, Fn, getTrivialSourceLocation(Cxx),
      clang::MultiExprArg(exprs,nexprs), getTrivialSourceLocation(Cxx), NULL, false).get();
}

DLLEXPORT void *CreateVarDecl(C, void *DC, char* name, void *type)
{
  clang::QualType T = clang::QualType::getFromOpaquePtr(type);
  clang::VarDecl *D = clang::VarDecl::Create(Cxx->CI->getASTContext(), (clang::DeclContext *)DC,
    getTrivialSourceLocation(Cxx), getTrivialSourceLocation(Cxx),
      Cxx->CI->getPreprocessor().getIdentifierInfo(name),
      T, Cxx->CI->getASTContext().getTrivialTypeSourceInfo(T), clang::SC_Extern);
  return D;
}

DLLEXPORT void *CreateFunctionDecl(C, void *DC, char* name, void *type, int isextern)
{
  clang::QualType T = clang::QualType::getFromOpaquePtr(type);
  clang::FunctionDecl *D = clang::FunctionDecl::Create(Cxx->CI->getASTContext(), (clang::DeclContext *)DC,
    getTrivialSourceLocation(Cxx), getTrivialSourceLocation(Cxx),
      clang::DeclarationName(Cxx->CI->getPreprocessor().getIdentifierInfo(name)),
      T, Cxx->CI->getASTContext().getTrivialTypeSourceInfo(T), isextern ? clang::SC_Extern : clang::SC_None);
  return D;
}


DLLEXPORT void *CreateParmVarDecl(C, void *type, char *name)
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
    d->setIsUsed();
    return (void*)d;
}

DLLEXPORT void *CreateTypeDefDecl(C, clang::DeclContext *DC, char *name, void *type)
{
    clang::QualType T = clang::QualType::getFromOpaquePtr(type);
    return (void*)clang::TypedefDecl::Create(Cxx->CI->getASTContext(),DC,getTrivialSourceLocation(Cxx),
      getTrivialSourceLocation(Cxx),
        &Cxx->CI->getPreprocessor().getIdentifierTable().getOwn(name),
        Cxx->CI->getASTContext().getTrivialTypeSourceInfo(T));
}

DLLEXPORT void SetFDParams(clang::FunctionDecl *FD, clang::ParmVarDecl **PVDs, size_t npvds)
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

DLLEXPORT void AssociateValue(C, clang::Decl *d, void *type, llvm::Value *V)
{
    clang::VarDecl *vd = dyn_cast<clang::VarDecl>(d);
    clang::QualType T = clang::QualType::getFromOpaquePtr(type);
    llvm::Type *Ty = Cxx->CGF->ConvertTypeForMem(T);
    if (type == cT_int1(Cxx))
      V = Cxx->CGF->Builder.CreateZExt(V, Ty);
    // Associate the value with this decl
    Cxx->CGF->EmitParmDecl(*vd, Cxx->CGF->Builder.CreateBitCast(V, Ty), false, 0);
}

DLLEXPORT void AddDeclToDeclCtx(clang::DeclContext *DC, clang::Decl *D)
{
    DC->addDecl(D);
}

DLLEXPORT void *CreateDeclRefExpr(C,clang::ValueDecl *D, clang::CXXScopeSpec *scope, int islvalue)
{
    clang::QualType T = D->getType();
    return (void*)clang::DeclRefExpr::Create(Cxx->CI->getASTContext(), scope ?
            scope->getWithLocInContext(Cxx->CI->getASTContext()) : clang::NestedNameSpecifierLoc(NULL,NULL),
            getTrivialSourceLocation(Cxx), D, false, getTrivialSourceLocation(Cxx),
            T.getNonReferenceType(), islvalue ? clang::VK_LValue : clang::VK_RValue);
}

DLLEXPORT void *DeduceReturnType(clang::Expr *expr)
{
    return expr->getType().getAsOpaquePtr();
}

DLLEXPORT void *CreateFunction(C, llvm::Type *rt, llvm::Type** argt, size_t nargs)
{
  llvm::FunctionType *ft = llvm::FunctionType::get(rt,llvm::ArrayRef<llvm::Type*>(argt,nargs),false);
  return (void*)llvm::Function::Create(ft, llvm::GlobalValue::ExternalLinkage, "", Cxx->shadow);
}

DLLEXPORT void *tovdecl(clang::Decl *D)
{
    return dyn_cast<clang::ValueDecl>(D);
}

DLLEXPORT void *cxxtmplt(clang::Decl *D)
{
    return dyn_cast<clang::ClassTemplateDecl>(D);
}


DLLEXPORT void *extractTypePtr(void *QT)
{
    return (void*)clang::QualType::getFromOpaquePtr(QT).getTypePtr();
}

DLLEXPORT unsigned extractCVR(void *QT)
{
    return clang::QualType::getFromOpaquePtr(QT).getCVRQualifiers();
}

DLLEXPORT void *emitcallexpr(C, clang::Expr *E, llvm::Value *rslot)
{
    if (isa<clang::CXXBindTemporaryExpr>(E))
      E = cast<clang::CXXBindTemporaryExpr>(E)->getSubExpr();

    clang::CallExpr *CE = dyn_cast<clang::CallExpr>(E);
    assert(CE != NULL);

    clang::CodeGen::RValue ret = Cxx->CGF->EmitCallExpr(CE,clang::CodeGen::ReturnValueSlot(rslot,false));
    if (ret.isScalar())
      return ret.getScalarVal();
    else
      return ret.getAggregateAddr();
}

DLLEXPORT void emitexprtomem(C,clang::Expr *E, llvm::Value *addr, int isInit)
{
    Cxx->CGF->EmitAnyExprToMem(E, addr, clang::Qualifiers(), isInit);
}

DLLEXPORT void *EmitAnyExpr(C, clang::Expr *E, llvm::Value *rslot)
{
    clang::CodeGen::RValue ret = Cxx->CGF->EmitAnyExpr(E);
    if (ret.isScalar())
      return ret.getScalarVal();
    else
      return ret.getAggregateAddr();
}

DLLEXPORT void *get_nth_argument(Function *f, size_t n)
{
    size_t i = 0;
    Function::arg_iterator AI = f->arg_begin();
    for (; AI != f->arg_end(); ++i, ++AI)
    {
        if (i == n)
            return (void*)((Value*)AI++);
    }
    return NULL;
}

DLLEXPORT void *create_extract_value(C, Value *agg, size_t idx)
{
    return Cxx->CGF->Builder.CreateExtractValue(agg,ArrayRef<unsigned>((unsigned)idx));
}

DLLEXPORT void *create_insert_value(llvm::IRBuilder<false> *builder, Value *agg, Value *val, size_t idx)
{
    return builder->CreateInsertValue(agg,val,ArrayRef<unsigned>((unsigned)idx));
}

DLLEXPORT void *tu_decl(C)
{
    return Cxx->CI->getASTContext().getTranslationUnitDecl();
}

DLLEXPORT void *get_primary_dc(clang::DeclContext *dc)
{
    return dc->getPrimaryContext();
}

DLLEXPORT void *decl_context(clang::Decl *decl)
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

DLLEXPORT void *to_decl(clang::DeclContext *decl)
{
    return dyn_cast<clang::Decl>(decl);
}

DLLEXPORT void *to_cxxdecl(clang::Decl *decl)
{
    return dyn_cast<clang::CXXRecordDecl>(decl);
}

DLLEXPORT void *GetFunctionReturnType(clang::FunctionDecl *FD)
{
    return FD->getReturnType().getAsOpaquePtr();
}

DLLEXPORT void *BuildDecltypeType(C, clang::Expr *E)
{
    clang::QualType T = Cxx->CI->getSema().BuildDecltypeType(E,E->getLocStart());
    return Cxx->CI->getASTContext().getCanonicalType(T).getAsOpaquePtr();
}

DLLEXPORT void *getTemplateArgs(clang::ClassTemplateSpecializationDecl *tmplt)
{
    return (void*)&tmplt->getTemplateArgs();
}

DLLEXPORT size_t getTargsSize(clang::TemplateArgumentList *targs)
{
    return targs->size();
}

DLLEXPORT size_t getTSTTargsSize(clang::TemplateSpecializationType *TST)
{
    return TST->getNumArgs();
}

DLLEXPORT size_t getTDNumParameters(clang::TemplateDecl *TD)
{
    return TD->getTemplateParameters()->size();
}

DLLEXPORT void *getTargsPointer(clang::TemplateArgumentList *targs)
{
    return (void*)targs->data();
}

DLLEXPORT void *getTargType(const clang::TemplateArgument *targ)
{
    return (void*)targ->getAsType().getAsOpaquePtr();
}

DLLEXPORT void *getTDParamAtIdx(clang::TemplateDecl *TD, int i)
{
    return (void*)TD->getTemplateParameters()->getParam(i);
}

DLLEXPORT void *getTargTypeAtIdx(clang::TemplateArgumentList *targs, size_t i)
{
    return getTargType(&targs->get(i));
}

DLLEXPORT void *getTSTTargTypeAtIdx(clang::TemplateSpecializationType *targs, size_t i)
{
    return getTargType(&targs->getArg(i));
}

DLLEXPORT void *getTargIntegralType(const clang::TemplateArgument *targ)
{
    return targ->getIntegralType().getAsOpaquePtr();
}

DLLEXPORT void *getTargIntegralTypeAtIdx(clang::TemplateArgumentList *targs, size_t i)
{
    return getTargIntegralType(&targs->get(i));
}

DLLEXPORT int getTargKind(const clang::TemplateArgument *targ)
{
    return targ->getKind();
}

DLLEXPORT int getTargKindAtIdx(clang::TemplateArgumentList *targs, size_t i)
{
    return getTargKind(&targs->get(i));
}

DLLEXPORT int getTSTTargKindAtIdx(clang::TemplateSpecializationType *TST, size_t i)
{
    return getTargKind(&TST->getArg(i));
}

DLLEXPORT size_t getTargPackAtIdxSize(clang::TemplateArgumentList *targs, size_t i)
{
    return targs->get(i).getPackAsArray().size();
}

DLLEXPORT void *getTargPackAtIdxTargAtIdx(clang::TemplateArgumentList *targs, size_t i, size_t j)
{
    return (void*)&targs->get(i).getPackAsArray()[j];
}

DLLEXPORT int64_t getTargAsIntegralAtIdx(clang::TemplateArgumentList *targs, size_t i)
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

DLLEXPORT void *getPointeeType(clang::Type *t)
{
    return t->getPointeeType().getAsOpaquePtr();
}

DLLEXPORT void *getArrayElementType(clang::Type *t)
{
    return cast<clang::ArrayType>(t)->getElementType().getAsOpaquePtr();
}

DLLEXPORT void *getOriginalTypePtr(clang::ParmVarDecl *d)
{
  return (void*)d->getOriginalType().getTypePtr();
}

DLLEXPORT void *getPointerTo(C, void *T)
{
    return Cxx->CI->getASTContext().getPointerType(clang::QualType::getFromOpaquePtr(T)).getAsOpaquePtr();
}

DLLEXPORT void *getReferenceTo(C, void *T)
{
    return Cxx->CI->getASTContext().getLValueReferenceType(clang::QualType::getFromOpaquePtr(T)).getAsOpaquePtr();
}

DLLEXPORT void *getRvalueReferenceTo(C, void *T)
{
    return Cxx->CI->getASTContext().getRValueReferenceType(clang::QualType::getFromOpaquePtr(T)).getAsOpaquePtr();
}

DLLEXPORT void *getIncompleteArrayType(C, void *T)
{
    return Cxx->CI->getASTContext().getIncompleteArrayType(
      clang::QualType::getFromOpaquePtr(T),
      clang::ArrayType::Normal, 0).getAsOpaquePtr();
}

DLLEXPORT void *createDerefExpr(C, clang::Expr *expr)
{
  return (void*)Cxx->CI->getSema().CreateBuiltinUnaryOp(getTrivialSourceLocation(Cxx),clang::UO_Deref,expr).get();
}

DLLEXPORT void *createAddrOfExpr(C, clang::Expr *expr)
{
  return (void*)Cxx->CI->getSema().CreateBuiltinUnaryOp(getTrivialSourceLocation(Cxx),clang::UO_AddrOf,expr).get();
}

DLLEXPORT void *createCast(C,clang::Expr *expr, clang::Type *t, int kind)
{
  return clang::ImplicitCastExpr::Create(Cxx->CI->getASTContext(),clang::QualType(t,0),
    (clang::CastKind)kind,expr,NULL,clang::VK_RValue);
}

DLLEXPORT void *CreateBinOp(C, clang::Scope *S, int opc, clang::Expr *LHS, clang::Expr *RHS)
{
  return (void*)Cxx->CI->getSema().BuildBinOp(S,clang::SourceLocation(),(clang::BinaryOperatorKind)opc,LHS,RHS).get();
}

DLLEXPORT void *BuildMemberReference(C, clang::Expr *base, clang::Type *t, int IsArrow, char *name)
{
    clang::DeclarationName DName(&Cxx->CI->getASTContext().Idents.get(name));
    clang::Sema &sema = Cxx->CI->getSema();
    clang::CXXScopeSpec scope;
    return (void*)sema.BuildMemberReferenceExpr(base,clang::QualType(t,0), getTrivialSourceLocation(Cxx), IsArrow, scope,
      getTrivialSourceLocation(Cxx), nullptr, clang::DeclarationNameInfo(DName, getTrivialSourceLocation(Cxx)), nullptr).get();
}

DLLEXPORT void *BuildDeclarationNameExpr(C, char *name, clang::DeclContext *ctx)
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

DLLEXPORT void *clang_get_builder(C)
{
    return (void*)&Cxx->CGF->Builder;
}

DLLEXPORT void *jl_get_llvm_ee()
{
    return jl_ExecutionEngine;
}

DLLEXPORT void *jl_get_llvmc()
{
    return &jl_LLVMContext;
}

DLLEXPORT void cdump(void *decl)
{
    ((clang::Decl*) decl)->dump();
}

DLLEXPORT void exprdump(void *expr)
{
    ((clang::Expr*) expr)->dump();
}

DLLEXPORT void typedump(void *t)
{
    ((clang::Type*) t)->dump();
}

DLLEXPORT void llvmdump(void *t)
{
    ((llvm::Value*) t)->dump();
}

DLLEXPORT void llvmtdump(void *t)
{
    ((llvm::Type*) t)->dump();
}

DLLEXPORT void *createLoad(llvm::IRBuilder<false> *builder, llvm::Value *val)
{
    return builder->CreateLoad(val);
}

DLLEXPORT void *CreateConstGEP1_32(llvm::IRBuilder<false> *builder, llvm::Value *val, uint32_t idx)
{
    return (void*)builder->CreateConstGEP1_32(val,idx);
}

#define TMember(s)              \
DLLEXPORT int s(clang::Type *t) \
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

DLLEXPORT int isTemplateSpecializationType(clang::Type *t) {
  return isa<clang::TemplateSpecializationType>(t);
}

DLLEXPORT int isElaboratedType(clang::Type *t) {
  return isa<clang::ElaboratedType>(t);
}

DLLEXPORT void *isIncompleteType(clang::Type *t)
{
    clang::NamedDecl *ND = NULL;
    t->isIncompleteType(&ND);
    return ND;
}

#define W(M,ARG)              \
DLLEXPORT void *M(ARG *p)     \
{                             \
  return (void *)p->M();      \
}

W(getPointeeCXXRecordDecl, clang::Type)
W(getAsCXXRecordDecl, clang::Type)

#define ISAD(NS,T,ARGT)             \
DLLEXPORT int isa ## T(ARGT *p)      \
{                                   \
  return llvm::isa<NS::T>(p);       \
}                                   \
DLLEXPORT void *dcast ## T(ARGT *p)  \
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

DLLEXPORT void *getUndefValue(llvm::Type *t)
{
  return (void*)llvm::UndefValue::get(t);
}

DLLEXPORT void *getStructElementType(llvm::Type *t, uint32_t i)
{
  return (void*)t->getStructElementType(i);
}

DLLEXPORT void *CreateRet(llvm::IRBuilder<false> *builder, llvm::Value *ret)
{
  return (void*)builder->CreateRet(ret);
}

DLLEXPORT void *CreateRetVoid(llvm::IRBuilder<false> *builder)
{
  return (void*)builder->CreateRetVoid();
}

DLLEXPORT void *CreateBitCast(llvm::IRBuilder<false> *builder, llvm::Value *val, llvm::Type *type)
{
  return (void*)builder->CreateBitCast(val,type);
}

DLLEXPORT void *getConstantIntToPtr(llvm::Constant *CC, llvm::Type *type)
{
  return (void*)ConstantExpr::getIntToPtr(CC,type);
}

DLLEXPORT size_t cxxsizeof(C, clang::CXXRecordDecl *decl)
{
  llvm::ExecutionEngine *ee = (llvm::ExecutionEngine *)jl_get_llvm_ee();
  clang::CodeGen::CodeGenTypes *cgt = &Cxx->CGM->getTypes();
  auto dl = ee->getDataLayout();
  Cxx->CI->getSema().RequireCompleteType(getTrivialSourceLocation(Cxx),
    clang::QualType(decl->getTypeForDecl(),0),0);
  auto t = cgt->ConvertRecordDeclType(decl);
  return dl.getTypeSizeInBits(t)/8;
}

DLLEXPORT size_t cxxsizeofType(C, void *t)
{
  llvm::ExecutionEngine *ee = (llvm::ExecutionEngine *)jl_get_llvm_ee();
  auto dl = ee->getDataLayout();
  clang::CodeGen::CodeGenTypes *cgt = &Cxx->CGM->getTypes();
  return dl.getTypeSizeInBits(
    cgt->ConvertTypeForMem(clang::QualType::getFromOpaquePtr(t)))/8;
}

DLLEXPORT void *ConvertTypeForMem(C, void *t)
{
  return (void*)Cxx->CGM->getTypes().ConvertTypeForMem(clang::QualType::getFromOpaquePtr(t));
}

DLLEXPORT void *getValueType(llvm::Value *val)
{
  return (void*)val->getType();
}

DLLEXPORT int isLLVMPointerType(llvm::Type *t)
{
  return t->isPointerTy();
}

DLLEXPORT void *getLLVMPointerTo(llvm::Type *t)
{
  return (void*)t->getPointerTo();
}

DLLEXPORT void *getContext(clang::Decl *d)
{
  return (void*)d->getDeclContext();
}

DLLEXPORT void *getParentContext(clang::DeclContext *DC)
{
  return (void*)DC->getParent();
}

DLLEXPORT uint64_t getDCDeclKind(clang::DeclContext *DC)
{
  return (uint64_t)DC->getDeclKind();
}

DLLEXPORT void *getDirectCallee(clang::CallExpr *e)
{
  return (void*)e->getDirectCallee();
}

DLLEXPORT void *getCalleeReturnType(clang::CallExpr *e)
{
  clang::FunctionDecl *fd = e->getDirectCallee();
  if (fd == NULL)
    return NULL;
  return (void*)fd->getReturnType().getAsOpaquePtr();
}

DLLEXPORT void *newCXXScopeSpec(C)
{
  clang::CXXScopeSpec *scope = new clang::CXXScopeSpec();
  scope->MakeGlobal(Cxx->CI->getASTContext(),getTrivialSourceLocation(Cxx));
  return (void*)scope;
}

DLLEXPORT void deleteCXXScopeSpec(clang::CXXScopeSpec *spec)
{
  delete spec;
}

DLLEXPORT void ExtendNNS(C,clang::NestedNameSpecifierLocBuilder *builder, clang::NamespaceDecl *d)
{
  builder->Extend(Cxx->CI->getASTContext(),d,getTrivialSourceLocation(Cxx),getTrivialSourceLocation(Cxx));
}

DLLEXPORT void ExtendNNSIdentifier(C,clang::NestedNameSpecifierLocBuilder *builder, const char *Name)
{
  clang::Preprocessor &PP = Cxx->Parser->getPreprocessor();
  // Get the identifier.
  clang::IdentifierInfo *Id = PP.getIdentifierInfo(Name);
  builder->Extend(Cxx->CI->getASTContext(),Id,getTrivialSourceLocation(Cxx),getTrivialSourceLocation(Cxx));
}

DLLEXPORT void ExtendNNSType(C,clang::NestedNameSpecifierLocBuilder *builder, void *t)
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

DLLEXPORT void *makeFunctionType(C, void *rt, void **argts, size_t nargs)
{
  clang::QualType T;
  if (rt == NULL) {
    T = Cxx->CI->getASTContext().getAutoType(clang::QualType(),
                                 /*decltype(auto)*/true,
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

DLLEXPORT void *makeMemberFunctionType(C, void *FT, clang::Type *cls)
{
  return Cxx->CI->getASTContext().getMemberPointerType(clang::QualType::getFromOpaquePtr(FT), cls).getAsOpaquePtr();
}

DLLEXPORT void *getMemberPointerClass(clang::Type *mptr)
{
  return (void*)cast<clang::MemberPointerType>(mptr)->getClass();
}

DLLEXPORT void *getMemberPointerPointee(clang::Type *mptr)
{
  return cast<clang::MemberPointerType>(mptr)->getPointeeType().getAsOpaquePtr();
}

DLLEXPORT void *getFPTReturnType(clang::FunctionProtoType *fpt)
{
  return fpt->getReturnType().getAsOpaquePtr();
}

DLLEXPORT size_t getFPTNumParams(clang::FunctionProtoType *fpt)
{
  return fpt->getNumParams();
}

DLLEXPORT void *getFPTParam(clang::FunctionProtoType *fpt, size_t idx)
{
  return fpt->getParamType(idx).getAsOpaquePtr();
}

DLLEXPORT void *getLLVMStructType(llvm::Type **ts, size_t nts)
{
  return (void*)llvm::StructType::get(jl_LLVMContext,ArrayRef<llvm::Type*>(ts,nts));
}

DLLEXPORT void MarkDeclarationsReferencedInExpr(C,clang::Expr *e)
{
  clang::Sema &sema = Cxx->CI->getSema();
  sema.MarkDeclarationsReferencedInExpr(e, true);
}

DLLEXPORT void *getConstantFloat(llvm::Type *llvmt, double x)
{
  return ConstantFP::get(llvmt,x);
}
DLLEXPORT void *getConstantInt(llvm::Type *llvmt, uint64_t x)
{
  return ConstantInt::get(llvmt,x);
}
DLLEXPORT void *getConstantStruct(llvm::Type *llvmt, llvm::Constant **vals, size_t nvals)
{
  return ConstantStruct::get(cast<StructType>(llvmt),ArrayRef<llvm::Constant*>(vals,nvals));
}

DLLEXPORT const clang::Type *canonicalType(clang::Type *t)
{
  return t->getCanonicalTypeInternal().getTypePtr();
}

DLLEXPORT int builtinKind(clang::Type *t)
{
    assert(isa<clang::BuiltinType>(t));
    return cast<clang::BuiltinType>(t)->getKind();
}

DLLEXPORT int isDeclInvalid(clang::Decl *D)
{
  return D->isInvalidDecl();
}

// Test Support
DLLEXPORT void *clang_get_cgt(C)
{
  return (void*)&Cxx->CGM->getTypes();
}

DLLEXPORT void *clang_shadow_module(C)
{
  return (void*)Cxx->shadow;
}

DLLEXPORT int RequireCompleteType(C,clang::Type *t)
{
  clang::Sema &sema = Cxx->CI->getSema();
  return sema.RequireCompleteType(getTrivialSourceLocation(Cxx),clang::QualType(t,0),0);
}

DLLEXPORT void *CreateTemplatedFunction(C, char *Name, clang::TemplateParameterList** args, size_t nargs)
{
  clang::DeclSpec DS(Cxx->Parser->getAttrFactory());
  clang::Declarator D(DS, clang::Declarator::PrototypeContext);
  clang::Preprocessor &PP = Cxx->Parser->getPreprocessor();
  D.getName().setIdentifier(PP.getIdentifierInfo(Name),clang::SourceLocation());
  clang::Sema &sema = Cxx->CI->getSema();
  return sema.ActOnTemplateDeclarator(nullptr,clang::MultiTemplateParamsArg(args,nargs),D);
}

DLLEXPORT void *ActOnTypeParameter(C, char *Name, unsigned Position)
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

DLLEXPORT void EnterParserScope(C)
{
  Cxx->Parser->EnterScope(clang::Scope::TemplateParamScope);
}

DLLEXPORT void *ActOnTypeParameterParserScope(C, char *Name, unsigned Position)
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

DLLEXPORT void ExitParserScope(C)
{
  Cxx->Parser->ExitScope();
}

DLLEXPORT void *CreateTemplateParameterList(C, clang::NamedDecl **D, size_t ND)
{
  return (void*)clang::TemplateParameterList::Create(Cxx->CI->getASTContext(), clang::SourceLocation(), clang::SourceLocation(), D, ND, clang::SourceLocation());
}

DLLEXPORT void *CreateFunctionTemplateDecl(C, clang::DeclContext *DC, clang::TemplateParameterList *Params, clang::FunctionDecl *FD)
{
  clang::FunctionTemplateDecl *FTD = clang::FunctionTemplateDecl::Create(
      Cxx->CI->getASTContext(), DC, clang::SourceLocation(),
      FD->getNameInfo().getName(), Params, FD);
  FD->setDescribedFunctionTemplate(FTD);
  return (void*)FTD;
}

DLLEXPORT void *newFDVector() { return (void*)new std::vector<clang::FunctionDecl*>; }
DLLEXPORT void deleteFDVector(void *v) { delete ((std::vector<clang::FunctionDecl*>*) v); }
DLLEXPORT void copyFDVector(void *to, std::vector<clang::FunctionDecl*> *from)
{
  memcpy(to, from->data(), sizeof(clang::FunctionDecl*)*from->size());
}
DLLEXPORT size_t getFDVectorSize(std::vector<clang::FunctionDecl*> *v) {return v->size(); }

DLLEXPORT void getSpecializations(clang::FunctionTemplateDecl *FTD, std::vector<clang::FunctionDecl*> *specs) {
  for (auto it : FTD->specializations())
    specs->push_back(it);
}

DLLEXPORT const char *getMangledFunctionName(C,clang::FunctionDecl *D)
{
  return Cxx->CGM->getMangledName(clang::GlobalDecl(D)).data();
}

DLLEXPORT const void *getTemplateSpecializationArgs(clang::FunctionDecl *FD)
{
  return (const void*)FD->getTemplateSpecializationArgs();
}

DLLEXPORT void *getLambdaCallOperator(clang::CXXRecordDecl *R)
{
  return R->getLambdaCallOperator();
}

DLLEXPORT void *getFunctionTypeReturnType(void *T)
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
  clang::DeclRefExpr *DRE = new (S.Context) clang::DeclRefExpr(Fn, false, Fn->getType(),
                                                 clang::VK_LValue, Loc, LocInfo);
  if (HadMultipleCandidates)
    DRE->setHadMultipleCandidates(true);

  S.MarkDeclRefReferenced(DRE);

  clang::ExprResult E = DRE;
  E = S.DefaultFunctionArrayConversion(E.get());
  if (E.isInvalid())
    return clang::ExprError();
  return E;
}

DLLEXPORT void *CreateCStyleCast(C, clang::Expr *E, clang::Type *T)
{
  clang::QualType QT(T,0);
  return (void*)clang::CStyleCastExpr::Create (Cxx->CI->getASTContext(), QT, clang::VK_RValue, clang::CK_BitCast,
    E, nullptr, Cxx->CI->getASTContext().getTrivialTypeSourceInfo(QT), clang::SourceLocation(), clang::SourceLocation());
}

DLLEXPORT void *CreateReturnStmt(C, clang::Expr *E)
{
  return (void*)new (Cxx->CI->getASTContext()) clang::ReturnStmt(clang::SourceLocation(),E,nullptr);
}

DLLEXPORT void *CreateFunctionRefExprFD(C, clang::FunctionDecl *FD)
{
  return (void*)CreateFunctionRefExpr(Cxx->CI->getSema(),FD,FD,false).get();
}

DLLEXPORT void *CreateFunctionRefExprFDTemplate(C, clang::FunctionTemplateDecl *FTD)
{
  return (void*)CreateFunctionRefExpr(Cxx->CI->getSema(),FTD->getTemplatedDecl(),FTD,false).get();
}


DLLEXPORT void SetFDBody(clang::FunctionDecl *FD, clang::Stmt *body)
{
  FD->setBody(body);
}

DLLEXPORT void ActOnFinishFunctionBody(C,clang::FunctionDecl *FD, clang::Stmt *Body)
{
  Cxx->CI->getSema().ActOnFinishFunctionBody(FD,Body,true);
}

DLLEXPORT void *CreateLinkageSpec(C, clang::DeclContext *DC, unsigned kind)
{
  return (void *)(clang::DeclContext *)clang::LinkageSpecDecl::Create(Cxx->CI->getASTContext(), DC,
    clang::SourceLocation(), clang::SourceLocation(), (clang::LinkageSpecDecl::LanguageIDs) kind,
    true);
}

DLLEXPORT const char *getLLVMValueName(llvm::Value *V)
{
  return V->getName().data();
}

DLLEXPORT void *getParmVarDecl(clang::FunctionDecl *FD, unsigned i)
{
  return (void *)FD->getParamDecl(i);
}

DLLEXPORT void SetDeclUsed(C,clang::Decl *D)
{
  D->markUsed(Cxx->CI->getASTContext());
}

DLLEXPORT void *getPointerElementType(llvm::Type *T)
{
  return (void*)T->getPointerElementType ();
}

DLLEXPORT void emitDestroyCXXObject(C, llvm::Value *x, clang::Type *T)
{
  clang::CXXRecordDecl *RD = T->getAsCXXRecordDecl();
  Cxx->CI->getSema().MarkBaseAndMemberDestructorsReferenced(
    clang::SourceLocation(), RD);
  clang::CXXDestructorDecl *Destructor = Cxx->CI->getSema().LookupDestructor(RD);
  Cxx->CI->getSema().MarkFunctionReferenced(clang::SourceLocation(), Destructor);
  Cxx->CI->getSema().DefineUsedVTables();
  Cxx->CI->getSema().PerformPendingInstantiations(false);
  Cxx->CGF->destroyCXXObject(*Cxx->CGF, x, clang::QualType(T,0));
}

DLLEXPORT bool hasTrivialDestructor(C, clang::CXXRecordDecl *RD)
{
  clang::CXXScopeSpec spec;
  spec.setBeginLoc(getTrivialSourceLocation(Cxx));
  clang::Sema &cs = Cxx->CI->getSema();
  cs.RequireCompleteDeclContext(spec,RD);
  return RD->hasTrivialDestructor();
}

DLLEXPORT void setPersonality(llvm::Function *F, llvm::Function *PersonalityF)
{
  F->setPersonalityFn(PersonalityF);
}

DLLEXPORT void *getFunction(C, char *name, size_t length)
{
  return Cxx->shadow->getFunction(llvm::StringRef(name,length));
}

DLLEXPORT int hasFDBody(clang::FunctionDecl *FD)
{
  return FD->hasBody();
}

DLLEXPORT void *getUnderlyingTemplateDecl(clang::TemplateSpecializationType *TST)
{
  return (void*)TST->getTemplateName().getAsTemplateDecl();
}

DLLEXPORT void *getOrCreateTemplateSpecialization(C, clang::FunctionTemplateDecl *FTD, void **T, size_t nargs)
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

DLLEXPORT void *CreateIntegerLiteral(C, uint64_t val, void *T)
{
  clang::QualType QT = clang::QualType::getFromOpaquePtr(T);
  return (void*)clang::IntegerLiteral::Create(Cxx->CI->getASTContext(),
    llvm::APInt(8*sizeof(uint64_t),val), QT, clang::SourceLocation());
}

DLLEXPORT void *desugarElaboratedType(clang::ElaboratedType *T)
{
  return (void *)T->desugar().getAsOpaquePtr();
}

DLLEXPORT unsigned getTTPTIndex(clang::TemplateTypeParmType *TTPT)
{
  return TTPT->getIndex();
}

DLLEXPORT void *getTemplatedDecl(clang::TemplateDecl *TD)
{
  return TD->getTemplatedDecl();
}

extern void *jl_pchar_to_string(const char *str, size_t len);
DLLEXPORT void *getTypeName(C, void *Ty)
{
  SmallString<256> OutName;
  llvm::raw_svector_ostream Out(OutName);
  Cxx->CGM->getCXXABI().
    getMangleContext().mangleCXXRTTIName(clang::QualType::getFromOpaquePtr(Ty), Out);
  Out.flush();
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

void RegisterType(C, clang::TagDecl *D, llvm::StructType *ST)
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

}

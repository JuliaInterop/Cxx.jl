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
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Frontend/CodeGenOptions.h>
#include <clang/AST/Type.h>
#include <clang/AST/ASTContext.h>
#include <clang/AST/DeclTemplate.h>
#include <clang/Basic/Specifiers.h>
#include "CodeGen/CodeGenModule.h"
#include <CodeGen/CodeGenTypes.h>
#include <CodeGen/CodeGenFunction.h>

#include "dtypes.h"

#if defined(LLVM_VERSION_MAJOR) && LLVM_VERSION_MAJOR == 3 && LLVM_VERSION_MINOR >= 6
#define LLVM36 1
#endif

// From julia
using namespace llvm;
extern ExecutionEngine *jl_ExecutionEngine;
extern llvm::LLVMContext &jl_LLVMContext;

static clang::ASTContext *clang_astcontext;
static clang::CompilerInstance *clang_compiler;
static clang::CodeGen::CodeGenModule *clang_cgm;
static clang::CodeGen::CodeGenTypes *clang_cgt;
static clang::CodeGen::CodeGenFunction *clang_cgf;
static clang::Parser *clang_parser;
static clang::Preprocessor *clang_preprocessor;
static DataLayout *TD;

DLLEXPORT llvm::Module *clang_shadow_module;

extern "C" {
  // clang types
  DLLEXPORT const clang::Type *cT_int1;
  DLLEXPORT const clang::Type *cT_int8;
  DLLEXPORT const clang::Type *cT_uint8;
  DLLEXPORT const clang::Type *cT_int16;
  DLLEXPORT const clang::Type *cT_uint16;
  DLLEXPORT const clang::Type *cT_int32;
  DLLEXPORT const clang::Type *cT_uint32;
  DLLEXPORT const clang::Type *cT_int64;
  DLLEXPORT const clang::Type *cT_uint64;
  DLLEXPORT const clang::Type *cT_char;
  DLLEXPORT const clang::Type *cT_cchar;
  DLLEXPORT const clang::Type *cT_size;
  DLLEXPORT const clang::Type *cT_int128;
  DLLEXPORT const clang::Type *cT_uint128;
  DLLEXPORT const clang::Type *cT_complex64;
  DLLEXPORT const clang::Type *cT_complex128;
  DLLEXPORT const clang::Type *cT_float32;
  DLLEXPORT const clang::Type *cT_float64;
  DLLEXPORT const clang::Type *cT_void;
  DLLEXPORT const clang::Type *cT_pvoid;
  DLLEXPORT const clang::Type *cT_wint;
}

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

clang::SourceLocation getTrivialSourceLocation()
{
    clang::SourceManager &sm = clang_compiler->getSourceManager();
    return sm.getLocForStartOfFile(sm.getMainFileID());
}

extern "C" {
  extern void jl_error(const char *str);
  void *julia_namespace = 0;
  void *createNamespace(char *name)
  {
    clang::IdentifierInfo *Id = clang_preprocessor->getIdentifierInfo(name);
    return (void*)clang::NamespaceDecl::Create(
          *clang_astcontext,
          clang_astcontext->getTranslationUnitDecl(),
          false,
          getTrivialSourceLocation(),
          getTrivialSourceLocation(),
          Id,
          nullptr
          );
  }
  DLLEXPORT void SetDeclInitializer(clang::VarDecl *D, llvm::Constant *CI)
  {
      llvm::Constant *C = clang_cgm->GetAddrOfGlobalVar(D);
      if (!isa<llvm::GlobalVariable>(C))
        jl_error("Clang did not create a global variable for the given VarDecl");
      llvm::GlobalVariable *GV = cast<llvm::GlobalVariable>(C);
      GV->setInitializer(CI);
      GV->setConstant(true);
  }
  DLLEXPORT void ReplaceFunctionForDecl(clang::FunctionDecl *D, llvm::Function *F)
  {
      llvm::Constant *C = clang_cgm->GetAddrOfFunction(D);
      if (!isa<llvm::Function>(C))
        jl_error("Clang did not create function for the given FunctionDecl");
      llvm::Function *OF = cast<llvm::Function>(C);
      llvm::ValueToValueMapTy VMap;
      llvm::ClonedCodeInfo CCI;
      llvm::Function *NF = llvm::CloneFunction(F,VMap,true,&CCI);
      // TODO: Ideally we would delete the cloned function
      // once we're done with the inlineing, but clang delays
      // emitting some functions (e.g. constructors) until
      // they're used.
      clang_shadow_module->getFunctionList().push_back(NF);
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
}

class JuliaCodeGenerator : public clang::ASTConsumer {
  public:
    JuliaCodeGenerator() {}

    virtual ~JuliaCodeGenerator() {}

    virtual void HandleCXXStaticMemberVarInstantiation(clang::VarDecl *VD) {
      clang_cgm->HandleCXXStaticMemberVarInstantiation(VD);
    }

    virtual bool HandleTopLevelDecl(clang::DeclGroupRef DG) {
      // Make sure to emit all elements of a Decl.
      for (clang::DeclGroupRef::iterator I = DG.begin(), E = DG.end(); I != E; ++I) {
        clang_cgm->EmitTopLevelDecl(*I);
      }
      return true;
    }

    /// HandleTagDeclDefinition - This callback is invoked each time a TagDecl
    /// to (e.g. struct, union, enum, class) is completed. This allows the
    /// client hack on the type, which can occur at any point in the file
    /// (because these can be defined in declspecs).
    virtual void HandleTagDeclDefinition(clang::TagDecl *D) {
      clang_cgm->UpdateCompletedType(D);

      // In C++, we may have member functions that need to be emitted at this
      // point.
      if (clang_astcontext->getLangOpts().CPlusPlus && !D->isDependentContext()) {
        for (clang::DeclContext::decl_iterator M = D->decls_begin(),
                                     MEnd = D->decls_end();
             M != MEnd; ++M)
          if (clang::CXXMethodDecl *Method = dyn_cast<clang::CXXMethodDecl>(*M))
            if (Method->doesThisDeclarationHaveABody() &&
                (Method->hasAttr<clang::UsedAttr>() ||
                 Method->hasAttr<clang::ConstructorAttr>()))
              clang_cgm->EmitTopLevelDecl(Method);
      }
    }

    virtual void CompleteTentativeDefinition(clang::VarDecl *D) {
      clang_cgm->EmitTentativeDefinition(D);
    }

    virtual void HandleVTable(clang::CXXRecordDecl *RD, bool DefinitionRequired) {
      clang_cgm->EmitVTable(RD, DefinitionRequired);
    }
};

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

void myParseAST(clang::Sema &S, bool PrintStats, bool SkipFunctionBodies) {
  // Collect global stats on Decls/Stmts (until we have a module streamer).
  if (PrintStats) {
    clang::Decl::EnableStatistics();
    clang::Stmt::EnableStatistics();
  }

  // Also turn on collection of stats inside of the Sema object.
  bool OldCollectStats = PrintStats;
  std::swap(OldCollectStats, S.CollectStats);

  clang::ASTConsumer *Consumer = &S.getASTConsumer();

  clang::Parser &P = *clang_parser;

  S.getPreprocessor().EnterMainSourceFile();
  P.Initialize();

  // C11 6.9p1 says translation units must have at least one top-level
  // declaration. C++ doesn't have this restriction. We also don't want to
  // complain if we have a precompiled header, although technically if the PCH
  // is empty we should still emit the (pedantic) diagnostic.
  clang::Parser::DeclGroupPtrTy ADecl;
  clang::ExternalASTSource *External = S.getASTContext().getExternalSource();
  if (External)
    External->StartTranslationUnit(Consumer);

  if (P.ParseTopLevelDecl(ADecl)) {
    if (!External && !S.getLangOpts().CPlusPlus)
      P.Diag(clang::diag::ext_empty_translation_unit);
  } else {
    do {
      // If we got a null return and something *was* parsed, ignore it.  This
      // is due to a top-level semicolon, an action override, or a parse error
      // skipping something.
      if (ADecl && !Consumer->HandleTopLevelDecl(ADecl.get()))
        return;
    } while (!P.ParseTopLevelDecl(ADecl));
  }

  // Process any TopLevelDecls generated by #pragma weak.
  for (llvm::SmallVectorImpl<clang::Decl *>::iterator
       I = S.WeakTopLevelDecls().begin(),
       E = S.WeakTopLevelDecls().end(); I != E; ++I)
    Consumer->HandleTopLevelDecl(clang::DeclGroupRef(*I));

  Consumer->HandleTranslationUnit(S.getASTContext());

  std::swap(OldCollectStats, S.CollectStats);
  if (PrintStats) {
    llvm::errs() << "\nSTATISTICS:\n";
    P.getActions().PrintStats();
    S.getASTContext().PrintStats();
    clang::Decl::PrintStats();
    clang::Stmt::PrintStats();
    Consumer->PrintStats();
  }
}

DLLEXPORT void add_directory(int kind, int isFramework, const char *dirname)
{
  clang::SrcMgr::CharacteristicKind flag = (clang::SrcMgr::CharacteristicKind)kind;
  clang::FileManager &fm = clang_compiler->getFileManager();
  clang::Preprocessor &pp = clang_parser->getPreprocessor();
  auto dir = fm.getDirectory(dirname);
  if (dir == NULL)
    std::cout << "WARNING: Could not add directory" << dirname << "to clang search path!\n";
  else
    pp.getHeaderSearchInfo().AddSearchPath(clang::DirectoryLookup(dir,flag,isFramework),flag == clang::SrcMgr::C_System || flag == clang::SrcMgr::C_ExternCSystem);
}

static int _cxxparse(const clang::DirectoryLookup *CurDir)
{
    clang::Sema &sema = clang_compiler->getSema();
    clang::ASTConsumer *Consumer = &sema.getASTConsumer();

    clang::Parser::DeclGroupPtrTy ADecl;

    while (!clang_parser->ParseTopLevelDecl(ADecl)) {
      // If we got a null return and something *was* parsed, ignore it.  This
      // is due to a top-level semicolon, an action override, or a parse error
      // skipping something.
      if (ADecl && !Consumer->HandleTopLevelDecl(ADecl.get()))
        return 0;
    }

    clang_compiler->getSema().PerformPendingInstantiations(false);
    clang_cgm->Release();

    return 1;
}

DLLEXPORT int cxxinclude(char *fname, char *sourcepath, int isAngled)
{
    const clang::DirectoryLookup *CurDir;
    clang::FileManager &fm = clang_compiler->getFileManager();
    clang::Preprocessor &P = clang_parser->getPreprocessor();

    const clang::FileEntry *File = P.LookupFile(
      getTrivialSourceLocation(), fname,
      isAngled, P.GetCurDirLookup(), CurDir, nullptr,nullptr, nullptr);

    if(!File)
      return 0;

    clang::SourceManager &sm = clang_compiler->getSourceManager();

    clang::FileID FID = sm.createFileID(File, sm.getLocForStartOfFile(sm.getMainFileID()), P.getHeaderSearchInfo().getFileDirFlavor(File));

    P.EnterSourceFile(FID, CurDir, sm.getLocForStartOfFile(sm.getMainFileID()));
    return _cxxparse(CurDir);
}

DLLEXPORT void *ActOnStartOfFunction(clang::Decl *D)
{
    clang::Sema &sema = clang_compiler->getSema();
    return (void*)sema.ActOnStartOfFunctionDef(clang_parser->getCurScope(), D);
}

DLLEXPORT void ParseFunctionStatementBody(clang::Decl *D)
{
    clang::Parser::ParseScope BodyScope(clang_parser, clang::Scope::FnScope|clang::Scope::DeclScope);
    clang_parser->ConsumeToken();

    clang::Sema &sema = clang_compiler->getSema();

    // Slightly modified
    assert(clang_parser->getCurToken().is(clang::tok::l_brace));
    clang::SourceLocation LBraceLoc = clang_parser->getCurToken().getLocation();

    clang::PrettyDeclStackTraceEntry CrashInfo(sema, D, LBraceLoc,
                                        "parsing function body");

    // Do not enter a scope for the brace, as the arguments are in the same scope
    // (the function body) as the body itself.  Instead, just read the statement
    // list and put it into a CompoundStmt for safe keeping.
    clang::StmtResult FnBody(clang_parser->ParseCompoundStatementBody(true));

    // If the function body could not be parsed, make a bogus compoundstmt.
    if (FnBody.isInvalid()) {
      clang::Sema::CompoundScopeRAII CompoundScope(sema);
      FnBody = sema.ActOnCompoundStmt(LBraceLoc, LBraceLoc, None, false);
    }

    clang::CompoundStmt *Body = cast<clang::CompoundStmt>(FnBody.get());

    // If we don't yet have a return statement, implicitly return
    // the result of the last statement
    if (cast<clang::FunctionDecl>(D)->getReturnType()->isUndeducedType())
    {
      clang::Stmt *last = Body->body_back();
      if (last && isa<clang::Expr>(last))
        Body->setLastStmt(
          sema.BuildReturnStmt(getTrivialSourceLocation(), cast<clang::Expr>(last)).get());
    }

    BodyScope.Exit();
    sema.ActOnFinishFunctionBody(D, Body);
}

DLLEXPORT void *ActOnStartNamespaceDef(char *name)
{
  clang_parser->EnterScope(clang::Scope::DeclScope);
  clang::ParsedAttributes attrs(clang_parser->getAttrFactory());
  return clang_compiler->getSema().ActOnStartNamespaceDef(
      clang_parser->getCurScope(),
      getTrivialSourceLocation(),
      getTrivialSourceLocation(),
      getTrivialSourceLocation(),
      clang_parser->getPreprocessor().getIdentifierInfo(name),
      getTrivialSourceLocation(),
      attrs.getList()
      );
}

DLLEXPORT void ActOnFinishNamespaceDef(clang::Decl *D)
{
  clang_parser->ExitScope();
  clang_compiler->getSema().ActOnFinishNamespaceDef(
      D, getTrivialSourceLocation()
      );
}

DLLEXPORT void EnterSourceFile(char *data, size_t length)
{
    const clang::DirectoryLookup *CurDir;
    clang::FileManager &fm = clang_compiler->getFileManager();
    clang::SourceManager &sm = clang_compiler->getSourceManager();
    clang::FileID FID = sm.createFileID(llvm::MemoryBuffer::getMemBuffer(llvm::StringRef(data,length)),clang::SrcMgr::C_User,
      0,0,sm.getLocForStartOfFile(sm.getMainFileID()));
    clang::Preprocessor &P = clang_parser->getPreprocessor();
    P.EnterSourceFile(FID, CurDir, sm.getLocForStartOfFile(sm.getMainFileID()));
}

DLLEXPORT int cxxparse(char *data, size_t length)
{
    EnterSourceFile(data, length);
    return _cxxparse(nullptr);
}

DLLEXPORT void defineMacro(const char *Name)
{
  clang::Preprocessor &PP = clang_parser->getPreprocessor();
  // Get the identifier.
  clang::IdentifierInfo *Id = PP.getIdentifierInfo(Name);

  clang::MacroInfo *MI = PP.AllocateMacroInfo(getTrivialSourceLocation());

  PP.appendDefMacroDirective(Id, MI);
}

DLLEXPORT void init_julia_clang_env() {
    //copied from http://www.ibm.com/developerworks/library/os-createcompilerllvm2/index.html
    clang_compiler = new clang::CompilerInstance;
    clang_compiler->getDiagnosticOpts().ShowColors = 1;
    clang_compiler->createDiagnostics();
    clang_compiler->getLangOpts().CPlusPlus = 1;
    clang_compiler->getLangOpts().CPlusPlus11 = 1;
    clang_compiler->getLangOpts().CPlusPlus14 = 1;
    clang_compiler->getLangOpts().LineComment = 1;
    clang_compiler->getLangOpts().Bool = 1;
    clang_compiler->getLangOpts().WChar = 1;
    clang_compiler->getLangOpts().C99 = 1;
    clang_compiler->getLangOpts().RTTI = 0;
    clang_compiler->getLangOpts().RTTIData = 0;
    clang_compiler->getLangOpts().ImplicitInt = 0;
    // TODO: Decide how we want to handle this
    // clang_compiler->getLangOpts().AccessControl = 0;
    clang_compiler->getPreprocessorOpts().UsePredefines = 1;
    clang_compiler->getHeaderSearchOpts().UseBuiltinIncludes = 1;
    clang_compiler->getHeaderSearchOpts().UseLibcxx = 1;
    clang_compiler->getHeaderSearchOpts().UseStandardSystemIncludes = 1;
    clang_compiler->getHeaderSearchOpts().UseStandardCXXIncludes = 1;
    clang_compiler->getCodeGenOpts().setDebugInfo(clang::CodeGenOptions::NoDebugInfo);
    clang_compiler->getTargetOpts().Triple = llvm::Triple::normalize(llvm::sys::getProcessTriple());
    clang_compiler->setTarget(clang::TargetInfo::CreateTargetInfo(
      clang_compiler->getDiagnostics(),
      std::make_shared<clang::TargetOptions>(clang_compiler->getTargetOpts())));
    clang::TargetInfo &tin = clang_compiler->getTarget();
    clang_compiler->createFileManager();
    clang_compiler->createSourceManager(clang_compiler->getFileManager());
    clang_compiler->createPreprocessor(clang::TU_Prefix);
    clang_preprocessor = &clang_compiler->getPreprocessor();
    clang_compiler->createASTContext();
    clang_shadow_module = new llvm::Module("clangShadow",jl_LLVMContext);
    clang_astcontext = &clang_compiler->getASTContext();
#ifdef LLVM36
    clang_compiler->setASTConsumer(std::unique_ptr<clang::ASTConsumer>(new JuliaCodeGenerator()));
#else
    clang_compiler->setASTConsumer(new JuliaCodeGenerator());
#endif
    clang_compiler->createSema(clang::TU_Prefix,NULL);
    clang_compiler->getSema().addExternalSource(new JuliaSemaSource());
    TD = new DataLayout(tin.getTargetDescription());
    clang_cgm = new clang::CodeGen::CodeGenModule(
        *clang_astcontext,
        clang_compiler->getCodeGenOpts(),
        *clang_shadow_module,
        *TD,
        clang_compiler->getDiagnostics());
    clang_cgt = &(clang_cgm->getTypes());
    clang_cgf = new clang::CodeGen::CodeGenFunction(*clang_cgm);
    clang_cgf->CurFuncDecl = NULL;
    clang_cgf->CurCodeDecl = NULL;

    T_int32 = Type::getInt32Ty(jl_LLVMContext);

    cT_int1  = clang_astcontext->BoolTy.getTypePtrOrNull();
    cT_cchar = clang_astcontext->CharTy.getTypePtrOrNull();
    cT_int8  = clang_astcontext->SignedCharTy.getTypePtrOrNull();
    cT_uint8 = clang_astcontext->UnsignedCharTy.getTypePtrOrNull();
    cT_int16 = clang_astcontext->ShortTy.getTypePtrOrNull();
    cT_uint16 = clang_astcontext->UnsignedShortTy.getTypePtrOrNull();
    cT_int32 = clang_astcontext->IntTy.getTypePtrOrNull();
    cT_uint32 = clang_astcontext->UnsignedIntTy.getTypePtrOrNull();
    cT_char = clang_astcontext->IntTy.getTypePtrOrNull();
#ifdef __LP64__
    cT_int64 = clang_astcontext->LongTy.getTypePtrOrNull();
    cT_uint64 = clang_astcontext->UnsignedLongTy.getTypePtrOrNull();
#else
    cT_int64 = clang_astcontext->LongLongTy.getTypePtrOrNull();
    cT_uint64 = clang_astcontext->UnsignedLongLongTy.getTypePtrOrNull();
#endif
    cT_size = clang_astcontext->getSizeType().getTypePtrOrNull();
    cT_int128 = clang_astcontext->Int128Ty.getTypePtrOrNull();
    cT_uint128 = clang_astcontext->UnsignedInt128Ty.getTypePtrOrNull();
    cT_complex64 = clang_astcontext->FloatComplexTy.getTypePtrOrNull();
    cT_complex128 = clang_astcontext->DoubleComplexTy.getTypePtrOrNull();

    cT_float32 = clang_astcontext->FloatTy.getTypePtrOrNull();
    cT_float64 = clang_astcontext->DoubleTy.getTypePtrOrNull();
    cT_void = clang_astcontext->VoidTy.getTypePtrOrNull();

    cT_pvoid = clang_astcontext->getPointerType(clang_astcontext->VoidTy).getTypePtrOrNull();

    cT_wint = clang_astcontext->WIntTy.getTypePtrOrNull();

    clang::Sema &sema = clang_compiler->getSema();
    clang_parser = new clang::Parser(sema.getPreprocessor(), sema, false);

    clang::Preprocessor &pp = clang_parser->getPreprocessor();
    clang_compiler->getDiagnosticClient().BeginSourceFile(clang_compiler->getLangOpts(), 0);
    pp.getBuiltinInfo().InitializeBuiltins(pp.getIdentifierTable(),
                                           clang_compiler->getLangOpts());
    pp.enableIncrementalProcessing();

    clang::SourceManager &sm = clang_compiler->getSourceManager();
    sm.setMainFileID(sm.createFileID(llvm::MemoryBuffer::getNewMemBuffer(0), clang::SrcMgr::C_User));

    sema.getPreprocessor().EnterMainSourceFile();
    clang_parser->Initialize();
}

static llvm::Module *cur_module = NULL;
static llvm::Function *cur_func = NULL;


DLLEXPORT void *setup_cpp_env(void *jlfunc)
{
    //assert(in_cpp == false);
    //in_cpp = true;

    cppcall_state_t *state = new cppcall_state_t;
    state->module = NULL;
    state->func = cur_func;
    state->CurFn = clang_cgf->CurFn;
    state->block = clang_cgf->Builder.GetInsertBlock();
    state->point = clang_cgf->Builder.GetInsertPoint();
    state->prev_alloca_bb_ptr = clang_cgf->AllocaInsertPt;

    llvm::Function *w = (Function *)jlfunc;
    assert(w != NULL);
    assert(clang_cgf != NULL);
    cur_module = NULL;
    cur_func = w;

    Function *ShadowF = (llvm::Function *)jlfunc;

    BasicBlock *b0 = BasicBlock::Create(clang_shadow_module->getContext(), "top", ShadowF);

    // setup the environment to clang's expecations
    clang_cgf->Builder.SetInsertPoint( b0 );
    // clang expects to alloca memory before the AllocaInsertPt
    // typically, clang would create this pointer when it started emitting the function
    // instead, we create a dummy reference here
    // for efficiency, we avoid creating a new placehold instruction if possible
    llvm::Instruction *alloca_bb_ptr = NULL;
    if (b0->empty()) {
        llvm::Value *Undef = llvm::UndefValue::get(T_int32);
        clang_cgf->AllocaInsertPt = alloca_bb_ptr = new llvm::BitCastInst(Undef, T_int32, "", b0);
    } else {
        clang_cgf->AllocaInsertPt = &(b0->front());
    }

    clang_cgf->CurFn = ShadowF;
    state->alloca_bb_ptr = alloca_bb_ptr;

    return state;
}

DLLEXPORT void EmitTopLevelDecl(clang::Decl *D)
{
    clang_cgm->EmitTopLevelDecl(D);
}

DLLEXPORT void cleanup_cpp_env(cppcall_state_t *state)
{
    //assert(in_cpp == true);
    //in_cpp = false;

    clang_compiler->getSema().PerformPendingInstantiations(false);
    clang_cgm->Release();

    // Set all functions and globals to external linkage (MCJIT needs this ugh)
    //for(Module::global_iterator I = jl_Module->global_begin(),
    //        E = jl_Module->global_end(); I != E; ++I) {
    //    I->setLinkage(llvm::GlobalVariable::ExternalLinkage);
    //}

    Function *F = clang_cgf->CurFn;

    // cleanup the environment
    clang_cgf->AllocaInsertPt = 0; // free this ptr reference
    if (state->alloca_bb_ptr)
        state->alloca_bb_ptr->eraseFromParent();

    //copy_into(F,cur_func);

    //F->eraseFromParent();
    // Hack: MaybeBindToTemporary can cause this to be
    // set if the allocated type has a constructor.
    // For now, ignore.
    clang_compiler->getSema().ExprNeedsCleanups = false;

    cur_module = state->module;
    cur_func = state->func;
    clang_cgf->CurFn = state->CurFn;
    clang_cgf->Builder.SetInsertPoint(state->block,state->point);
    clang_cgf->AllocaInsertPt = state->prev_alloca_bb_ptr;
    delete state;
}


DLLEXPORT int RequireCompleteType(clang::Type *t)
{
  clang::Sema &sema = clang_compiler->getSema();
  return sema.RequireCompleteType(getTrivialSourceLocation(),clang::QualType(t,0),0);
}


DLLEXPORT void *typeconstruct(clang::Type *t, clang::Expr **rawexprs, size_t nexprs)
{
    clang::QualType Ty(t,0);
    clang::MultiExprArg Exprs(rawexprs,nexprs);

    clang::Sema &sema = clang_compiler->getSema();
    clang::TypeSourceInfo *TInfo = clang_astcontext->getTrivialTypeSourceInfo(Ty);

    if (Ty->isDependentType() || clang::CallExpr::hasAnyTypeDependentArguments(Exprs)) {
        return clang::CXXUnresolvedConstructExpr::Create(*clang_astcontext, TInfo,
                                                      getTrivialSourceLocation(),
                                                      Exprs,
                                                      getTrivialSourceLocation());
    }

    clang::ExprResult Result;

    if (Exprs.size() == 1) {
        clang::Expr *Arg = Exprs[0];
        Result = sema.BuildCXXFunctionalCastExpr(TInfo, getTrivialSourceLocation(),
          Arg, getTrivialSourceLocation());
        assert(!Result.isInvalid());
        return Result.get();
    }

    if (!Ty->isVoidType() &&
        sema.RequireCompleteType(getTrivialSourceLocation(), Ty,
                            clang::diag::err_invalid_incomplete_type_use)) {
        assert(false);
        return NULL;
    }

    if (sema.RequireNonAbstractType(getTrivialSourceLocation(), Ty,
                               clang::diag::err_allocation_of_abstract_type)) {
        assert(false);
        return NULL;
    }

    clang::InitializedEntity Entity = clang::InitializedEntity::InitializeTemporary(TInfo);
    clang::InitializationKind Kind =
        Exprs.size() ?  clang::InitializationKind::CreateDirect(getTrivialSourceLocation(), getTrivialSourceLocation(), getTrivialSourceLocation())
        : clang::InitializationKind::CreateValue(getTrivialSourceLocation(), getTrivialSourceLocation(), getTrivialSourceLocation());
    clang::InitializationSequence InitSeq(sema, Entity, Kind, Exprs);
    Result = InitSeq.Perform(sema, Entity, Kind, Exprs);

    assert(!Result.isInvalid());
    return Result.get();
}

DLLEXPORT void *BuildCXXNewExpr(clang::Type *T, clang::Expr **exprs, size_t nexprs)
{
  clang::QualType Ty(T,0);
    clang::SourceManager &sm = clang_compiler->getSourceManager();
  return (void*) clang_compiler->getSema().BuildCXXNew(clang::SourceRange(),
    false, getTrivialSourceLocation(),
    clang::MultiExprArg(), getTrivialSourceLocation(), clang::SourceRange(),
    Ty, clang_astcontext->getTrivialTypeSourceInfo(Ty),
    NULL, clang::SourceRange(sm.getLocForStartOfFile(sm.getMainFileID()),
      sm.getLocForStartOfFile(sm.getMainFileID())),
    new (clang_astcontext) clang::ParenListExpr(*clang_astcontext,getTrivialSourceLocation(),
      ArrayRef<clang::Expr*>(exprs, nexprs), getTrivialSourceLocation()), false).get();
  //return (clang_astcontext) new clang::CXXNewExpr(clang_astcontext, false, nE, dE, )
}

DLLEXPORT void *EmitCXXNewExpr(clang::Expr *E)
{
  assert(isa<clang::CXXNewExpr>(E));
  return (void*)clang_cgf->EmitCXXNewExpr(cast<clang::CXXNewExpr>(E));
}

DLLEXPORT void *build_call_to_member(clang::Expr *MemExprE,clang::Expr **exprs, size_t nexprs)
{
  if (MemExprE->getType() == clang_astcontext->BoundMemberTy ||
         MemExprE->getType() == clang_astcontext->OverloadTy)
    return (void*)clang_compiler->getSema().BuildCallToMemberFunction(NULL,MemExprE,getTrivialSourceLocation(),clang::MultiExprArg(exprs,nexprs),getTrivialSourceLocation()).get();
  else {
    return (void*) new (clang_astcontext) clang::CXXMemberCallExpr(*clang_astcontext,
        MemExprE,ArrayRef<clang::Expr*>(exprs,nexprs),
        cast<clang::CXXMethodDecl>(cast<clang::MemberExpr>(MemExprE)->getMemberDecl())->getReturnType(),
        clang::VK_RValue,getTrivialSourceLocation());
  }
}

/*
ActOnCallExpr(Scope *S, Expr *Fn, SourceLocation LParenLoc,
04467                     MultiExprArg ArgExprs, SourceLocation RParenLoc,
04468                     Expr *ExecConfig, bool IsExecConfig) {
04469   // Since this might be a postfix expression, get rid of Pare
*/
DLLEXPORT void *CreateCallExpr(clang::Expr *Fn,clang::Expr **exprs, size_t nexprs)
{
    return clang_compiler->getSema().ActOnCallExpr(NULL, Fn, getTrivialSourceLocation(),
      clang::MultiExprArg(exprs,nexprs), getTrivialSourceLocation(), NULL, false).get();
}

DLLEXPORT void *CreateVarDecl(void *DC, char* name, clang::Type *type)
{
  clang::QualType T(type,0);
  clang::VarDecl *D = clang::VarDecl::Create(*clang_astcontext, (clang::DeclContext *)DC,
    getTrivialSourceLocation(), getTrivialSourceLocation(),
      clang_preprocessor->getIdentifierInfo(name),
      T, clang_astcontext->getTrivialTypeSourceInfo(T), clang::SC_Extern);
  return D;
}

DLLEXPORT void *CreateFunctionDecl(void *DC, char* name, clang::Type *type, int isextern)
{
  clang::QualType T(type,0);
  clang::FunctionDecl *D = clang::FunctionDecl::Create(*clang_astcontext, (clang::DeclContext *)DC,
    getTrivialSourceLocation(), getTrivialSourceLocation(),
      clang::DeclarationName(clang_preprocessor->getIdentifierInfo(name)),
      T, clang_astcontext->getTrivialTypeSourceInfo(T), isextern ? clang::SC_Extern : clang::SC_None);
  return D;
}


DLLEXPORT void *CreateParmVarDecl(clang::Type *type, char *name)
{
    clang::QualType T(type,0);
    clang::ParmVarDecl *d = clang::ParmVarDecl::Create(
        *clang_astcontext,
        clang_astcontext->getTranslationUnitDecl(), // This is wrong, hopefully it doesn't matter
        getTrivialSourceLocation(),
        getTrivialSourceLocation(),
        &clang_compiler->getPreprocessor().getIdentifierTable().getOwn(name),
        T,
        clang_astcontext->getTrivialTypeSourceInfo(T),
        clang::SC_None,NULL);
    d->setIsUsed();
    return (void*)d;
}

DLLEXPORT void SetFDParams(clang::FunctionDecl *FD, clang::ParmVarDecl **PVDs, size_t npvds)
{
    FD->setParams(ArrayRef<clang::ParmVarDecl*>(PVDs,npvds));
}

DLLEXPORT void AssociateValue(clang::Decl *d, clang::Type *type, llvm::Value *V)
{
    clang::VarDecl *vd = dyn_cast<clang::VarDecl>(d);
    clang::QualType T(type,0);
    llvm::Type *Ty = clang_cgf->ConvertTypeForMem(T);
    if (type == cT_int1)
      V = clang_cgf->Builder.CreateZExt(V, Ty);
    // Associate the value with this decl
    clang_cgf->EmitParmDecl(*vd, clang_cgf->Builder.CreateBitCast(V, Ty), false, 0);
}

DLLEXPORT void AddDeclToDeclCtx(clang::DeclContext *DC, clang::Decl *D)
{
    DC->addDecl(D);
}

DLLEXPORT void *CreateDeclRefExpr(clang::ValueDecl *D, clang::NestedNameSpecifierLocBuilder *builder, int islvalue)
{
    clang::QualType T = D->getType();
    return (void*)clang::DeclRefExpr::Create(*clang_astcontext, builder ?
            builder->getWithLocInContext(*clang_astcontext) : clang::NestedNameSpecifierLoc(NULL,NULL),
            getTrivialSourceLocation(), D, false, getTrivialSourceLocation(),
            T.getNonReferenceType(), islvalue ? clang::VK_LValue : clang::VK_RValue);
}

DLLEXPORT void *CreateMemberExpr(clang::Expr *base, int isarrow, clang::ValueDecl *memberdecl)
{
    return (void*)(clang::Expr*)clang::MemberExpr::Create (
        *clang_astcontext,
        base,
        isarrow,
        clang::NestedNameSpecifierLoc(),
        getTrivialSourceLocation(),
        memberdecl,
        clang::DeclAccessPair::make(memberdecl,clang::AS_public),
        clang::DeclarationNameInfo (memberdecl->getDeclName(),getTrivialSourceLocation()),
        NULL, clang_astcontext->BoundMemberTy, clang::VK_RValue, clang::OK_Ordinary);
}

DLLEXPORT void *DeduceReturnType(clang::Expr *expr)
{
    return (void*)expr->getType().getTypePtr();
}

DLLEXPORT void *CreateFunction(llvm::Type *rt, llvm::Type** argt, size_t nargs)
{
  llvm::FunctionType *ft = llvm::FunctionType::get(rt,llvm::ArrayRef<llvm::Type*>(argt,nargs),false);
  return (void*)llvm::Function::Create(ft, llvm::GlobalValue::ExternalLinkage, "", clang_shadow_module);
}

DLLEXPORT void *tovdecl(clang::Decl *D)
{
    return dyn_cast<clang::ValueDecl>(D);
}

DLLEXPORT void *cxxtmplt(clang::Decl *D)
{
    return dyn_cast<clang::ClassTemplateDecl>(D);
}

DLLEXPORT void *typeForDecl(clang::Decl *D)
{
    clang::TypeDecl *ty = dyn_cast<clang::TypeDecl>(D);
    if (ty == NULL)
      return NULL;
    return (void *)ty->getTypeForDecl();
}

DLLEXPORT void *SpecializeClass(clang::ClassTemplateDecl *tmplt, clang::Type **types, uint64_t *integralValues, uint32_t *bitwidths, int8_t *integralValuePresent, size_t nargs)
{
  clang::TemplateArgument *targs = new clang::TemplateArgument[nargs];
  for (size_t i = 0; i < nargs; ++i) {
    if (integralValuePresent[i] == 1)
      targs[i] = clang::TemplateArgument(*clang_astcontext,llvm::APSInt(llvm::APInt(8,integralValues[i])),clang::QualType(types[i],0));
    else
      targs[i] = clang::TemplateArgument(clang::QualType(types[i],0));
  }
  void *InsertPos;
  clang::ClassTemplateSpecializationDecl *ret =
    tmplt->findSpecialization(ArrayRef<clang::TemplateArgument>(targs,nargs),
    InsertPos);
  if (!ret)
  {
    ret = clang::ClassTemplateSpecializationDecl::Create(*clang_astcontext,
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

DLLEXPORT void *emitcppmembercallexpr(clang::CXXMemberCallExpr *E, llvm::Value *rslot)
{
    clang::CodeGen::RValue ret = clang_cgf->EmitCXXMemberCallExpr(E,clang::CodeGen::ReturnValueSlot(rslot,false));
    if (ret.isScalar())
      return ret.getScalarVal();
    else
      return ret.getAggregateAddr();
}

DLLEXPORT void *emitcallexpr(clang::Expr *E, llvm::Value *rslot)
{
    if (isa<clang::CXXBindTemporaryExpr>(E))
      E = cast<clang::CXXBindTemporaryExpr>(E)->getSubExpr();

    clang::CallExpr *CE = dyn_cast<clang::CallExpr>(E);
    assert(CE != NULL);

    clang::CodeGen::RValue ret = clang_cgf->EmitCallExpr(CE,clang::CodeGen::ReturnValueSlot(rslot,false));
    if (ret.isScalar())
      return ret.getScalarVal();
    else
      return ret.getAggregateAddr();
}

DLLEXPORT void emitexprtomem(clang::Expr *E, llvm::Value *addr, int isInit)
{
    clang_cgf->EmitAnyExprToMem(E, addr, clang::Qualifiers(), isInit);
}

DLLEXPORT void *EmitAnyExpr(clang::Expr *E, llvm::Value *rslot)
{
    clang::CodeGen::RValue ret = clang_cgf->EmitAnyExpr(E);
    if (ret.isScalar())
      return ret.getScalarVal();
    else
      return ret.getAggregateAddr();
}
/*
Sema::BuildCallToMemberFunction(Scope *S, Expr *MemExprE,
                                SourceLocation LParenLoc,
                                MultiExprArg Args,
                                SourceLocation RParenLoc) {
                                    */

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

DLLEXPORT void *create_extract_value(Value *agg, size_t idx)
{
    return clang_cgf->Builder.CreateExtractValue(agg,ArrayRef<unsigned>((unsigned)idx));
}

DLLEXPORT void *create_insert_value(llvm::IRBuilder<false> *builder, Value *agg, Value *val, size_t idx)
{
    return builder->CreateInsertValue(agg,val,ArrayRef<unsigned>((unsigned)idx));
}

DLLEXPORT void *lookup_name(char *name, clang::DeclContext *ctx)
{
    clang::SourceManager &sm = clang_compiler->getSourceManager();
    clang::CXXScopeSpec spec;
    spec.setBeginLoc(sm.getLocForStartOfFile(sm.getMainFileID()));
    spec.setEndLoc(sm.getLocForStartOfFile(sm.getMainFileID()));
    clang::DeclarationName DName(&clang_astcontext->Idents.get(name));
    clang::Sema &cs = clang_compiler->getSema();
    cs.RequireCompleteDeclContext(spec,ctx);
    //return dctx->lookup(DName).front();
    clang::LookupResult R(cs, DName, getTrivialSourceLocation(), clang::Sema::LookupAnyName);
    cs.LookupQualifiedName(R, ctx, false);
    return R.empty() ? NULL : R.getRepresentativeDecl();
}

DLLEXPORT void *tu_decl()
{
    return clang_astcontext->getTranslationUnitDecl();
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

DLLEXPORT void *get_result_type(void *cppfunc)
{
    clang::Decl* MD = ((clang::Decl *)cppfunc);
    clang::FunctionDecl* fdecl = dyn_cast<clang::FunctionDecl>(MD);
    if (fdecl == NULL)
        return NULL;
    return (void*)fdecl->getReturnType().getTypePtr();
}

DLLEXPORT void *emit_field_ref(clang::Type *BaseType, Value *BaseVal, clang::FieldDecl *FieldDecl)
{
    clang::CodeGen::LValue BaseLV = clang_cgf->MakeNaturalAlignAddrLValue(BaseVal,clang::QualType(BaseType,0));
    clang::CodeGen::LValue LV = clang_cgf->EmitLValueForField(BaseLV,FieldDecl);
    return LV.getAddress();
}

DLLEXPORT char *decl_name(clang::NamedDecl *decl)
{
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

DLLEXPORT void *getTemplateArgs(clang::ClassTemplateSpecializationDecl *tmplt)
{
    return (void*)&tmplt->getTemplateArgs();
}

DLLEXPORT size_t getTargsSize(clang::TemplateArgumentList *targs)
{
    return targs->size();
}

DLLEXPORT void *getTargType(clang::TemplateArgument *targ)
{
    return (void*)targ->getAsType().getTypePtr();
}

DLLEXPORT void *getTargTypeAtIdx(clang::TemplateArgumentList *targs, size_t i)
{
    return (void*)getTargType(const_cast<clang::TemplateArgument*>(&targs->get(i)));
}

DLLEXPORT void *getTargIntegralTypeAtIdx(clang::TemplateArgumentList *targs, size_t i)
{
    return (void*)targs->get(i).getIntegralType().getTypePtr();
}

DLLEXPORT int getTargKindAtIdx(clang::TemplateArgumentList *targs, size_t i)
{
    return targs->get(i).getKind();
}

DLLEXPORT int64_t getTargAsIntegralAtIdx(clang::TemplateArgumentList *targs, size_t i)
{
    return targs->get(i).getAsIntegral().getSExtValue();
}

DLLEXPORT void *referenced_type(clang::Type *t)
{
    return (void*)t->getPointeeType().getTypePtr();
}

DLLEXPORT void *getOriginalTypePtr(clang::ParmVarDecl *d)
{
  return (void*)d->getOriginalType().getTypePtr();
}

DLLEXPORT void *getPointerTo(clang::Type *t)
{
    return (void*)clang_astcontext->getPointerType(clang::QualType(t,0)).getTypePtr();
}

DLLEXPORT void *getReferenceTo(clang::Type *t)
{
    return (void*)clang_astcontext->getLValueReferenceType(clang::QualType(t,0)).getTypePtr();
}

DLLEXPORT void *createDerefExpr(clang::Expr *expr)
{
  return (void*)clang_compiler->getSema().CreateBuiltinUnaryOp(getTrivialSourceLocation(),clang::UO_Deref,expr).get();
}

DLLEXPORT void *createAddrOfExpr(clang::Expr *expr)
{
  return (void*)clang_compiler->getSema().CreateBuiltinUnaryOp(getTrivialSourceLocation(),clang::UO_AddrOf,expr).get();
}

DLLEXPORT void *createCast(clang::Expr *expr, clang::Type *t, int kind)
{
  return clang::ImplicitCastExpr::Create(*clang_astcontext,clang::QualType(t,0),(clang::CastKind)kind,expr,NULL,clang::VK_RValue);
}

DLLEXPORT void *BuildMemberReference(clang::Expr *base, clang::Type *t, int IsArrow, char *name)
{
    clang::DeclarationName DName(&clang_astcontext->Idents.get(name));
    clang::Sema &sema = clang_compiler->getSema();
    clang::CXXScopeSpec scope;
    return (void*)sema.BuildMemberReferenceExpr(base,clang::QualType(t,0), getTrivialSourceLocation(), IsArrow, scope,
      getTrivialSourceLocation(), nullptr, clang::DeclarationNameInfo(DName, getTrivialSourceLocation()), nullptr).get();
}

DLLEXPORT void *BuildDeclarationNameExpr(char *name, clang::DeclContext *ctx)
{
    clang::Sema &sema = clang_compiler->getSema();
    clang::SourceManager &sm = clang_compiler->getSourceManager();
    clang::CXXScopeSpec spec;
    spec.setBeginLoc(sm.getLocForStartOfFile(sm.getMainFileID()));
    spec.setEndLoc(sm.getLocForStartOfFile(sm.getMainFileID()));
    clang::DeclarationName DName(&clang_astcontext->Idents.get(name));
    sema.RequireCompleteDeclContext(spec,ctx);
    clang::LookupResult R(sema, DName, getTrivialSourceLocation(), clang::Sema::LookupAnyName);
    sema.LookupQualifiedName(R, ctx, false);
    return (void*)sema.BuildDeclarationNameExpr(spec,R,false).get();
}

DLLEXPORT void *clang_get_instance()
{
    return clang_compiler;
}

DLLEXPORT void *clang_get_cgm()
{
    return clang_cgm;
}

DLLEXPORT void *clang_get_cgf()
{
    return clang_cgf;
}

DLLEXPORT void *clang_get_cgt()
{
    return clang_cgt;
}

DLLEXPORT void *clang_get_builder()
{
    return (void*)&clang_cgf->Builder;
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

DLLEXPORT void *tollvmty(clang::Type *p)
{
    clang::QualType T(p,0);
    return (void*)clang_cgf->ConvertTypeForMem(T);
}

DLLEXPORT void *createLoad(llvm::IRBuilder<false> *builder, llvm::Value *val)
{
    return builder->CreateLoad(val);
}

DLLEXPORT void *CreateConstGEP1_32(llvm::IRBuilder<false> *builder, llvm::Value *val, uint32_t idx)
{
    return (void*)builder->CreateConstGEP1_32(val,idx);
}

/*
DeduceTemplateArguments (FunctionTemplateDecl *FunctionTemplate, TemplateArgumentListInfo *ExplicitTemplateArgs, ArrayRef< Expr * > Args, FunctionDecl *&Specialization, sema::TemplateDeductionInfo &Info)
*/

DLLEXPORT void *DeduceTemplateArguments(clang::FunctionTemplateDecl *tmplt, clang::Type **spectypes, uint32_t nspectypes, clang::Expr **args, uint32_t nargs)
{
    clang::TemplateArgumentListInfo tali;
    for (size_t i = 0; i < nspectypes; ++i) {
      clang::QualType T(spectypes[i],0);
      tali.addArgument(clang::TemplateArgumentLoc(clang::TemplateArgument(T),
        clang_astcontext->getTrivialTypeSourceInfo(T)));
    }
    clang::sema::TemplateDeductionInfo tdi((getTrivialSourceLocation()));
    clang::FunctionDecl *decl = NULL;
    clang_compiler->getSema().DeduceTemplateArguments(tmplt, &tali, ArrayRef<clang::Expr *>(args,nargs), decl, tdi);
    return (void*) decl;
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

DLLEXPORT size_t cxxsizeof(clang::CXXRecordDecl *decl)
{
  llvm::ExecutionEngine *ee = (llvm::ExecutionEngine *)jl_get_llvm_ee();
  clang::CodeGen::CodeGenTypes *cgt = (clang::CodeGen::CodeGenTypes *)clang_get_cgt();
  auto dl = ee->getDataLayout();
  clang_compiler->getSema().RequireCompleteType(getTrivialSourceLocation(),
    clang::QualType(decl->getTypeForDecl(),0),0);
  auto t = cgt->ConvertRecordDeclType(decl);
  return dl->getTypeSizeInBits(t)/8;
}

DLLEXPORT size_t cxxsizeofType(clang::Type *t)
{
  llvm::ExecutionEngine *ee = (llvm::ExecutionEngine *)jl_get_llvm_ee();
  auto dl = ee->getDataLayout();
  clang::CodeGen::CodeGenTypes *cgt = (clang::CodeGen::CodeGenTypes *)clang_get_cgt();
  return dl->getTypeSizeInBits(
    cgt->ConvertTypeForMem(clang::QualType(t,0)))/8;
}

DLLEXPORT void *ConvertTypeForMem(clang::Type *t)
{
  return (void*)((clang::CodeGen::CodeGenTypes *)clang_get_cgt())->
    ConvertTypeForMem(clang::QualType(t,0));
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

DLLEXPORT void *getDirectCallee(clang::CallExpr *e)
{
  return (void*)e->getDirectCallee();
}

DLLEXPORT void *getCalleeReturnType(clang::CallExpr *e)
{
  clang::FunctionDecl *fd = e->getDirectCallee();
  if (fd == NULL)
    return NULL;
  return (void*)fd->getReturnType().getTypePtr();
}

DLLEXPORT void *newNNSBuilder()
{
  return (void*)new clang::NestedNameSpecifierLocBuilder();
}

DLLEXPORT void deleteNNSBuilder(clang::NestedNameSpecifierLocBuilder *builder)
{
  delete builder;
}

DLLEXPORT void ExtendNNS(clang::NestedNameSpecifierLocBuilder *builder, clang::NamespaceDecl *d)
{
  builder->Extend(*clang_astcontext,d,getTrivialSourceLocation(),getTrivialSourceLocation());
}

DLLEXPORT void ExtendNNSIdentifier(clang::NestedNameSpecifierLocBuilder *builder, const char *Name)
{
  clang::Preprocessor &PP = clang_parser->getPreprocessor();
  // Get the identifier.
  clang::IdentifierInfo *Id = PP.getIdentifierInfo(Name);
  builder->Extend(*clang_astcontext,Id,getTrivialSourceLocation(),getTrivialSourceLocation());
}

DLLEXPORT void ExtendNNSType(clang::NestedNameSpecifierLocBuilder *builder, const clang::Type *t)
{
  builder->Extend(*clang_astcontext,clang::SourceLocation(),clang::TypeLoc(t,0),getTrivialSourceLocation());
}

DLLEXPORT void *makeFunctionType(clang::Type *rt, clang::Type **argts, size_t nargs)
{
  clang::QualType T;
  if (rt == NULL) {
    T = clang_astcontext->getAutoType(clang::QualType(),
                                 /*decltype(auto)*/true,
                                 /*IsDependent*/   false);
  } else {
    T = clang::QualType(rt,0);
  }
  clang::QualType *qargs = (clang::QualType *)__builtin_alloca(nargs*sizeof(clang::QualType));
  for (size_t i = 0; i < nargs; ++i)
    qargs[i] = clang::QualType(argts[i], 0);
  clang::FunctionProtoType::ExtProtoInfo EPI;
  return (void*)clang_astcontext->getFunctionType(T, llvm::ArrayRef<clang::QualType>(qargs, nargs), EPI).getTypePtr();
}

DLLEXPORT void *makeMemberFunctionType(clang::Type *cls, clang::Type *FT)
{
  return (void*)clang_astcontext->getMemberPointerType(clang::QualType(FT, 0), cls).getTypePtr();
}

DLLEXPORT void *getMemberPointerClass(clang::Type *mptr)
{
  return (void*)cast<clang::MemberPointerType>(mptr)->getClass();
}

DLLEXPORT void *getMemberPointerPointee(clang::Type *mptr)
{
  return (void*)cast<clang::MemberPointerType>(mptr)->getPointeeType().getTypePtr();
}

DLLEXPORT void *getFPTReturnType(clang::FunctionProtoType *fpt)
{
  return (void*)fpt->getReturnType().getTypePtr();
}

DLLEXPORT size_t getFPTNumParams(clang::FunctionProtoType *fpt)
{
  return fpt->getNumParams();
}

DLLEXPORT void *getFPTParam(clang::FunctionProtoType *fpt, size_t idx)
{
  return (void*)fpt->getParamType(idx).getTypePtr();
}

DLLEXPORT void *getLLVMStructType(llvm::Type **ts, size_t nts)
{
  return (void*)llvm::StructType::get(jl_LLVMContext,ArrayRef<llvm::Type*>(ts,nts));
}

DLLEXPORT void MarkMemberReferenced(clang::Expr *me)
{
  clang::Sema &sema = clang_compiler->getSema();
  sema.MarkMemberReferenced(dyn_cast<clang::MemberExpr>(me));
}

DLLEXPORT void MarkAnyDeclReferenced(clang::Decl *d)
{
  clang::Sema &sema = clang_compiler->getSema();
  sema.MarkAnyDeclReferenced(getTrivialSourceLocation(),d,true);
}

DLLEXPORT void MarkDeclarationsReferencedInExpr(clang::Expr *e)
{
  clang::Sema &sema = clang_compiler->getSema();
  sema.MarkDeclarationsReferencedInExpr(e,true);
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

}

require("../src/CXX.jl")

# LLVM Headers

addHeaderDir(joinpath(basepath,"usr/lib/clang/3.5.0/include/"), kind = C_ExternCSystem)
addHeaderDir(joinpath(basepath,"usr/include"))
addHeaderDir(joinpath(basepath,"deps/llvm-svn/tools/clang/"))
addHeaderDir(joinpath(basepath,"deps/llvm-svn/tools/clang/include/"))


# Load LLVM and clang libraries

defineMacro("__STDC_LIMIT_MACROS")
defineMacro("__STDC_CONSTANT_MACROS")
cxxinclude("llvm/Support/MemoryBuffer.h")
cxxinclude("llvm/BitCode/ReaderWriter.h")
cxxinclude("llvm/IR/Module.h")
cxxinclude("llvm/IR/IRBuilder.h")
cxxinclude("llvm/IR/Constants.h")
cxxinclude("llvm/IR/CFG.h")
cxxinclude("llvm/Support/GraphWriter.h")
cxxinclude("llvm/ExecutionEngine/ExecutionEngine.h")
cxxinclude("lib/CodeGen/CGValue.h")
cxxinclude("lib/CodeGen/CodeGenTypes.h")
cxxinclude("clang/AST/DeclBase.h")
cxxinclude("clang/AST/Type.h")
cxxinclude("clang/Basic/SourceLocation.h")
cxxinclude("clang/Frontend/CompilerInstance.h")
cxxinclude("clang/AST/DeclTemplate.h")
cxxinclude("llvm/ADT/ArrayRef.h")
cxxinclude("llvm/Analysis/CallGraph.h")


RequireCompleteType(d::pcpp"clang::Type") = ccall(:RequireCompleteType,Cint,(Ptr{Void},),d.ptr) > 0
function cxxsizeof(d::pcpp"clang::CXXRecordDecl")
    executionEngine = pcpp"llvm::ExecutionEngine"(ccall(:jl_get_llvm_ee,Ptr{Void},()))
    cgt = pcpp"clang::CodeGen::CodeGenTypes"(ccall(:clang_get_cgt,Ptr{Void},()))
    dl = @cxx executionEngine->getDataLayout()
    RequireCompleteType(@cxx d->getTypeForDecl())
    t = @cxx cgt->ConvertRecordDeclType(d)
    @assert @cxx t->isSized()
    div((@cxx dl->getTypeSizeInBits(t)),8)
end
@assert cxxsizeof(pcpp"clang::CXXRecordDecl"(lookup_name(["llvm","ExecutionEngine"]).ptr)) == 152

code_llvmf(f,t) = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Any,Bool), f, t, false))
function code_graph(f,args)
    v = @cxx std::string()
    os = @cxx llvm::raw_string_ostream(v)
    graphf = code_llvmf(f,args)
    @cxx llvm::WriteGraph(os,graphf)
    @cxx os->flush()
    bytestring((@cxx v->data()), (@cxx v->length()))
end

gt = code_graph(factorize,(typeof(rand(4,4)),))

@assert sizeof(gt) > 0

# LLDB test


addHeaderDir(joinpath(basepath,"deps/llvm-svn/tools/lldb/include"))
defineMacro("LLDB_DISABLE_PYTHON") # NO!
cxxinclude("lldb/Interpreter/CommandInterpreter.h")
cxxinclude("lldb/Interpreter/CommandReturnObject.h")
cxxinclude("string", isAngled = true)

initd() = @cxx lldb_private::Debugger::Initialize(cast(C_NULL,vcpp"lldb_private::Debugger::LoadPluginCallbackType"))
initd()

debugger() = @cxx lldb_private::Debugger::CreateInstance()
const dbg = @cxx (debugger())->get()
ci(dbg::pcpp"lldb_private::Debugger") = @cxx dbg->GetCommandInterpreter()
function hc(ci::rcpp"lldb_private::CommandInterpreter",cmd)
    cro = @cxx lldb_private::CommandReturnObject()
    @cxx ci->HandleCommand(pointer(cmd),0,cro)
    @cxx cro->GetOutputData()
end

stdout = pcpp"FILE"(ccall(:fdopen,Ptr{Void},(Int32,Ptr{Uint8}),1,"a"))

function setSTDOUT(dbg,stdout)
    @cxx dbg->SetOutputFileHandle(stdout,false)
end

function setSTDERR(dbg,stdout)
    @cxx dbg->SetErrorFileHandle(stdout,false)
end

setSTDOUT(dbg,stdout)
setSTDERR(dbg,stdout)

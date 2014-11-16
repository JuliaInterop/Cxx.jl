using Cxx

include("llvmincludes.jl")

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
@assert cxxsizeof(pcpp"clang::CXXRecordDecl"(lookup_name(["llvm","ExecutionEngine"]).ptr)) >= 152

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

cxx"""
void f() {}
"""
clangmod = pcpp"llvm::Module"(unsafe_load(cglobal(:clang_shadow_module,Ptr{Void})))
ptr = @cxx clangmod->getFunction(pointer("_Z1fv"))
@assert ptr != C_NULL

jns = cglobal((:julia_namespace,libcxxffi),Ptr{Void})
ns = createNamespace("julia")

# This is basically the manual expansion of the cxx_str macro
unsafe_store!(jns,ns.ptr)
ctx = toctx(pcpp"clang::Decl"(ns.ptr))
d = CreateVarDecl(ctx,"var1",cpptype(Int64))
AddDeclToDeclCtx(ctx,pcpp"clang::Decl"(d.ptr))
cxxparse("""
extern llvm::Module *clang_shadow_module;
extern llvm::LLVMContext &jl_LLVMContext;
uint64_t foo() {
    return __julia::var1;
}
""")
unsafe_store!(jns,C_NULL)
#GV = @cxx dyn_cast{llvm::GlobalVariable}(@cxx (@cxx clang_shadow_module)->getNamedValue(pointer("_ZN5julia4var1E")))
GV = pcpp"llvm::GlobalVariable"((@cxx (@cxx clang_shadow_module)->getNamedValue(pointer("_ZN5julia4var1E"))).ptr)
@assert GV != C_NULL
@cxx (@cxx GV->getType())->dump()
@cxx GV->setInitializer(@cxx llvm::ConstantInt::get((@cxx llvm::Type::getInt64Ty(*(@cxx &jl_LLVMContext))),uint64(0)))
@cxx GV->setConstant(true)
@assert (@cxx foo()) == uint64(0)

# LLDB test


addHeaderDir(joinpath(basepath,"deps/llvm-svn/tools/lldb/include"))

# Because LLDB includes private headers from public ones! For shame.
addHeaderDir(joinpath(basepath,"deps/llvm-svn/tools/lldb/include/lldb/Target"))
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

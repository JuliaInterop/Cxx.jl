require("../src/CXX.jl")
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

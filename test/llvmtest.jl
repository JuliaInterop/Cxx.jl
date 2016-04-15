using Cxx

include("llvmincludes.jl")

RequireCompleteType(C,d::cpcpp"clang::Type") =
    ccall((:RequireCompleteType,Cxx.libcxxffi),Cint,(Ptr{Cxx.ClangCompiler},Ptr{Void}),&C,d.ptr) > 0

function cxxsizeof(d::pcpp"clang::CXXRecordDecl")
    executionEngine = pcpp"llvm::ExecutionEngine"(ccall((:jl_get_llvm_ee,Cxx.libcxxffi),Ptr{Void},()))
    C = Cxx.instance(__current_compiler__)
    cgt = pcpp"clang::CodeGen::CodeGenTypes"(ccall((:clang_get_cgt,Cxx.libcxxffi),Ptr{Void},
        (Ptr{Cxx.ClangCompiler},),&C))
    dl = @cxx executionEngine->getDataLayout()
    RequireCompleteType(C,@cxx d->getTypeForDecl())
    t = @cxx cgt->ConvertRecordDeclType(d)
    @assert @cxx t->isSized()
    div((@cxx dl->getTypeSizeInBits(t)),8)
end
size = cxxsizeof(pcpp"clang::CXXRecordDecl"(Cxx.lookup_name(Cxx.instance(__current_compiler__),
    ["llvm","ExecutionEngine"]).ptr))
@assert size >= 144

code_llvmf(f,t::Tuple{Vararg{Type}}) = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Bool,Bool), Tuple{t...}, false, false))
function code_graph(f,args)
    v = @cxx std::string()
    os = @cxx llvm::raw_string_ostream(v)
    graphf = code_llvmf(f,args)
    @cxx llvm::WriteGraph(os,graphf)
    @cxx os->flush()
    bytestring(v)
end

gt = code_graph(factorize,(typeof(rand(4,4)),))

@assert sizeof(gt) > 0

cxx"""
void f() {}
"""
C = Cxx.instance(__current_compiler__)
clangmod = pcpp"llvm::Module"(ccall(:clang_shadow_module,Ptr{Void},
    (Ptr{Cxx.ClangCompiler},),&C))
ptr = @cxx clangmod->getFunction(pointer("_Z1fv"))
@assert ptr != C_NULL

jns = cglobal((:julia_namespace,Cxx.libcxxffi),Ptr{Void})
ns = Cxx.createNamespace(C,"julia")

# This is basically the manual expansion of the cxx_str macro
unsafe_store!(jns,ns.ptr)
ctx = Cxx.toctx(pcpp"clang::Decl"(ns.ptr))
d = Cxx.CreateVarDecl(C,ctx,"xvar1",Cxx.cpptype(C,Int64))
Cxx.AddDeclToDeclCtx(ctx,pcpp"clang::Decl"(d.ptr))
cxxparse("""
extern "C" {
extern llvm::Module *clang_shadow_module(void *);
}
extern llvm::LLVMContext &jl_LLVMContext;
uint64_t foo() {
    return __julia::xvar1;
}
""")
unsafe_store!(jns,C_NULL)
#GV = @cxx dyn_cast{llvm::GlobalVariable}(@cxx (@cxx clang_shadow_module)->getNamedValue(pointer("_ZN5julia4var1E")))
GV = pcpp"llvm::GlobalVariable"((@cxx (@cxx clang_shadow_module(convert(Ptr{Void},pointer([C]))))->getNamedValue(pointer("_ZN5julia5xvar1E"))).ptr)
@assert GV != C_NULL
@cxx (@cxx GV->getType())->dump()
@cxx GV->setInitializer(@cxx llvm::ConstantInt::get((@cxx llvm::Type::getInt64Ty(*(@cxx &jl_LLVMContext))),UInt64(0)))
@cxx GV->setConstant(true)
@assert (@cxx foo()) === UInt64(0)

# Find llvm
if haskey(ENV,"LLVM_DIR")
    llvmdir = ENV["LLVM_DIR"]
else
    try
        llvmdir = readchomp(`llvm-config --includedir`)
    catch
        try
            llvmdir = readchomp(`$(joinpath(JULIA_HOME,"llvm-config")) --includedir`)
        catch
            error("Could not find LLVM include directory. Set LLVM_DIR env variable manually")
        end
    end
end

import Base.Intrinsics.llvmcall

Base.t_func[eval(Core.Intrinsics,:llvmcall)] =
(3, Inf,function(args, fptrt, rtt, att, a...)
    fptr, rt, at = args
    ret = None
    if is(rt,Type{Void}) 
        ret = Nothing
    elseif Base.isType(rtt)
        ret = rtt.parameters[1]
    elseif isa(rtt,Tuple) && is(rtt[1],Function)
        if isa(rt,Expr)
            if rt.head == :call
                if isa(rt.args[1],Expr) && rt.args[1].head == :call &&
                    rt.args[1].args[1] == :top && rt.args[1].args[2] == :tuple
                    rt = rt.args[2:end]
                end
            elseif rt.head == :call1 
                if isa(rt.args[1],TopNode) && rt.args[1].name == :tuple
                    rt = rt.args[2:end]
                end
            end
        end
        if (isa(rt,Tuple) || isa(rt,Array)) && isa(rt[1],Function)
            ret = rt[1](a,rt[2:end]...)
        end
    end
    if ret === None 
        if isa(rt,Type) && isa(rt,Tuple)
            ret = rtt
        else
            ret = Any
        end
    end
    return ret
end)

#foo() = llvmcall(compile_func,Void,(Ptr{Uint8},),"SUCCESS")
#bar() = ccall(:jl_error,Void,(Ptr{Uint8},),"SUCCESS")

#code_llvm(foo,())
#code_llvm(bar,())


initialized = false
function initialize(mod,f)
    global initialized
    was_initialized = initialized
    if !initialized
        initialized = true
        ccall(:init_julia_clang_env,Void,(Ptr{Void},),mod)
    end 
    state = ccall(:setup_cpp_env,Ptr{Void},(Ptr{Void},Ptr{Void}),mod,f)
    if !was_initialized
        ccall(:init_header,Void,(Ptr{Uint8},),"test.h")
    end
    state
end

function initialize(thunk::Function,mod,f) 
    state=initialize(mod,f)
    thunk()
    cleanup(state)
end

cleanup(state) = ccall(:cleanup_cpp_env,Ptr{Void},(Ptr{Void},),state)

immutable CppPtr{T}
    ptr::Ptr{Void}
end

immutable CppRef{T}
    ptr::Ptr{Void}
end

immutable CppValue{T}
    data::Vector{Uint8}
end

immutable CppPOD{T,N}
    data::NTuple{N,Uint8}
    CppPOD() = new()
end

macro pcpp_str(s)
    CppPtr{symbol(s)}
end

macro rcpp_str(s)
    CppRef{symbol(s)}
end

import Base: cconvert

cconvert(::Type{Ptr{Void}},p::CppPtr) = p.ptr
cconvert(::Type{Ptr{Void}},p::CppRef) = p.ptr

function compile_new(f,mod,argt,t)
    initialize(mod,f) do
        d = lookup_name(t)
        ccall(:emit_cpp_new,Void,(Ptr{Void},),d)
    end
end
macro cppnew(t)
    :( CppPtr{$(quot(symbol(t)))}(llvmcall((compile_new,$t),Ptr{Void},()))::$(CppPtr{symbol(t)}) )
end

import Base: ==

==(p1::CppPtr,p2::Ptr) = p1.ptr == p2

function cpp_arg(T)
    return T
end

function get_decl(argt,func,thiscall)
    if (!(isa(func,Symbol) || isa(func,String)))
        Base.dump((argt,func,thiscall))
    end
    if thiscall
        thist = argt[1]
        if !(thist <: CppPtr) && !(thist <: CppRef)
            error("Expected a CppPtr or CppRef type, got $thist")
        end
        fname = string(thist.parameters[1],"::",func)
    else
        fname = string(func)
    end
    println(fname)
    lookup_name(fname)
end

function cpp_argt(args,fname,thiscall)
    for i = 1:length(args)
        arg = args[i]
        if arg == None
            error("Cannot determine type for argument $(i-int(thiscall)) to function $fname. Please add a type annotation.")
        end
    end
    args
end

ldump(x) = llvmcall((compile_func,"clang::Decl::dumpColor"),Void,(Ptr{Void},),x)
ddump(x) = llvmcall((compile_func,"clang::DeclContext::dump"),Void,(Ptr{Void},),x)
function primary_decl(x) 
    x == C_NULL && error("primary_decl")
    y = decl_context(x)
    ccall(:get_primary_dc,Ptr{Void},(Ptr{Void},),y)
end
function decl_context(x) 
    x == C_NULL && error("decl_context")
    y = ccall(:decl_context,Ptr{Void},(Ptr{Void},),x)
    if y == C_NULL
        ccall(:cdump,Void,(Ptr{Void},),x)
        error("Decl Context Returned NULL!")
    end
    y
end
function to_decl(x) 
    x == C_NULL && error("to_decl")
    ccall(:to_decl,Ptr{Void},(Ptr{Void},),x)
end
#map(x->ldump(decl(x)),)

#c = ClangCompiler()

using Base.Meta

function build_cpp_call(cexpr,member,ret,prefix,this=nothing)
    @assert isexpr(cexpr,:call)
    fname = string(prefix,cexpr.args[1])
    c = Expr(:call,:llvmcall,Expr(:tuple,member,fname,this != nothing),
                             Expr(:tuple,ret,fname,this != nothing),
                             Expr(:tuple,cpp_argt,fname,this != nothing))
    if this != nothing
        push!(c.args,this)
    end
    if length(cexpr.args) > 1
        for arg in cexpr.args[2:end]
            push!(c.args,arg)
        end
    end
    return c
end

function to_prefix(expr)
    if isa(expr,Symbol)
        return string(expr)
    elseif isexpr(expr,:(::))
        return string(to_prefix(expr.args[1]),"::",to_prefix(expr.args[2]))
    end
    error("Invalid NSS")
end

function build_ref(expr)
    if isa(expr,Symbol)
        return (expr,)
    elseif isexpr(expr,:(.))
        return tuple(build_ref(expr.args[1])...,build_ref(expr.args[2])...)
    else
        return (expr,)
    end
end

function cpps_impl(expr,member,ret,prefix="")
    # Expands a->b to
    # llvmcall((cpp_member,typeof(a),"b"))
    if expr.head == :(->) 
        a = expr.args[1]
        b = expr.args[2]
        i = 1
        while !(isexpr(b,:call) || isa(b,Symbol))
            b = expr.args[2].args[i]
            if !(isexpr(b,:call) || isexpr(b,:line) || isa(b,Symbol))
                error("Malformed C++ call. Expected member not $b")
            end
            i += 1
        end
        if isexpr(b,:call)
            return build_cpp_call(b,member,ret,prefix,a)
        else 
            error("Unsupported!")
        end
    elseif isexpr(expr,:(=))
        flattened = build_ref(expr.args[1])
        return Expr(:call,:llvmcall,Expr(:tuple,:cpp_assignment,quot(flattened[2:end])),
                Void,Expr(:tuple,:cpp_argt),flattened[1],expr.args[2])
    elseif isexpr(expr,:(::))
        return cpps_impl(expr.args[2],member,ret,string(to_prefix(expr.args[1]),"::"))
    elseif isexpr(expr,:call)
        return build_cpp_call(expr,member,ret,prefix,nothing)
    end
    error("Unrecognized CPP Expression ",expr," (",expr.head,")")
end

# STAGE 1 BOOTSTRAP

function lookup_name(n,d) 
    @assert d != C_NULL
    ccall(:lookup_name,Ptr{Void},(Ptr{Uint8},Ptr{Void}),n,d)
end

function lookup_name(fname)
    cur = ccall(:tu_decl,Ptr{Void},())
    for x in split(fname,"::")
        d = lookup_name(x,cur)
        if d == C_NULL
            ccall(:cdump,Void,(Ptr{Void},),cur)
            error("Could not find $x as part of $fname lookup")
        end
        cur = to_decl(primary_decl(d))
    end
    cur
end

function process_args(f,argt)
    args = Array(Ptr{Void},length(argt))
    types = Array(Ptr{Void},length(argt))
    for i in 1:length(argt)
        t = argt[i]
        args[i] = ccall(:get_nth_argument,Ptr{Void},(Ptr{Void},Csize_t),f,i-1)
        if t <: CppPtr || t <: CppRef
            types[i] = C_NULL
            args[i] = ccall(:create_extract_value,Ptr{Void},(Ptr{Void},Csize_t),args[i],0)
        else
            types[i] = C_NULL
        end
        if args[i] == C_NULL
            println((i,t))
            #error("Failed to process argument")
        end
    end
    args, types
end

function compile_func(f,mod,argt,func)
    initialize(mod,f) do
        d = lookup_name(func)
        args,types = process_args(f,argt)
        ccall(:emit_cpp_call,Void,(Ptr{Void},Ptr{Ptr{Void}},Ptr{Ptr{Void}},Csize_t,Bool,Bool),d,args,types,length(args),false,true)
    end
end

function cpp_rett(args,f,thiscall)
    d = get_decl(args,f,thiscall)
    t = ccall(:get_result_type,Ptr{Void},(Ptr{Void},),d) 
    arr = Array(Ptr{Void},1)
    if llvmcall((compile_func,"clang::Type::isVoidType"),Bool,(Ptr{Void},),t) != 0
        return Void
    end
    if llvmcall((compile_func,"clang::Type::isBooleanType"),Bool,(Ptr{Void},),t) != 0
        return Bool
    end
    return Ptr{Void}
end


function cpp_member(f,mod,argt,func,thiscall)
    println((f,mod,argt,func,thiscall))
    initialize(mod,f) do 
        d = get_decl(argt,func,thiscall)
        args,types = process_args(f,argt)
        ccall(:emit_cpp_call,Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Ptr{Ptr{Void}},Csize_t,Bool,Bool),d,args,types,length(args),false,true)
    end
end

macro cpp1(expr)
    cpps_impl(expr,cpp_member,cpp_rett)
end

# STAGE 2 BOOTSTRAP

type ClangCompiler
    handle::pcpp"clang::CompilerInstance"
    cgm::pcpp"clang::CodeGen::CodeGenModule"
    cgt::pcpp"clang::CodeGen::CodeGenTypes"
    cgf::pcpp"clang::CodeGen::CodeGenFunction"
    function ClangCompiler(handle::pcpp"clang::CompilerInstance",cgm::pcpp"clang::CodeGen::CodeGenModule",cgt::pcpp"clang::CodeGen::CodeGenTypes",cgf::pcpp"clang::CodeGen::CodeGenFunction")
        new(handle,cgm,cgt,cgf)
    end
end

dump(x::CppPtr) = @cpp1 x->dump()
dump(x::Union(pcpp"clang::Decl",pcpp"clang::Expr")) = @cpp1 x->dumpColor()

tocxx(p::pcpp"clang::Decl") = pcpp"clang::CXXRecordDecl"(ccall(:to_cxxdecl,Ptr{Void},(Ptr{Void},),p.ptr))

pointerTo(t::pcpp"clang::Type") = pcpp"clang::Type"(ccall(:getPointerTo,Ptr{Void},(Ptr{Void},),t.ptr))
function typeForDecl(p::pcpp"clang::CXXRecordDecl")
    @assert p.ptr != C_NULL
    @show p 
    pcpp"clang::Type"(@cpp1 p->getTypeForDecl())
end
typeForDecl(p::pcpp"clang::Decl") = typeForDecl(tocxx(p))

createDeref(p::pcpp"clang::Type", val::pcpp"llvm::UndefValue") = pcpp"clang::Expr"(ccall(:createDeref,Ptr{Void},(Ptr{Void},Ptr{Void}),p.ptr,val.ptr))

tovdecl(p::pcpp"clang::Decl") = pcpp"clang::ValueDecl"(ccall(:tovdecl,Ptr{Void},(Ptr{Void},),p.ptr))
CreateDeclRefExpr(p::pcpp"clang::ValueDecl",ty::pcpp"clang::Type") = pcpp"clang::Expr"(ccall(:CreateDeclRefExpr,Ptr{Void},(Ptr{Void},Ptr{Void}),p.ptr,ty.ptr))
CreateDeclRefExpr(p::pcpp"clang::Decl",ty::pcpp"clang::Type") = CreateDeclRefExpr(tovdecl(p),ty)

CreateParmVarDecl(p::pcpp"clang::Type") = pcpp"clang::Decl"(ccall(:CreateParmVarDecl,Ptr{Void},(Ptr{Void},),p.ptr))

CreateMemberExpr(base::pcpp"clang::Expr",isarrow::Bool,member::pcpp"clang::ValueDecl") = pcpp"clang::Expr"(ccall(:CreateMemberExpr,Ptr{Void},(Ptr{Void},Cint,Ptr{Void}),base.ptr,isarrow,member.ptr))
BuildCallToMemberFunction(me::pcpp"clang::Expr", args::Vector{pcpp"clang::Expr"}) = pcpp"clang::Expr"(ccall(:build_call_to_member,Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        me.ptr,[arg.ptr for arg in args],length(args)))

AssociateValue(d::pcpp"clang::Decl", ty::pcpp"clang::Type", V::pcpp"llvm::Value") = ccall(:AssociateValue,Void,(Ptr{Void},Ptr{Void},Ptr{Void}),d,ty,V)

function process_args2(f,argt)
    args = Array(pcpp"llvm::Value",length(argt))
    types = Array(Ptr{Void},length(argt))
    for i in 1:length(argt)
        t = argt[i]
        args[i] = pcpp"llvm::Value"(ccall(:get_nth_argument,Ptr{Void},(Ptr{Void},Csize_t),f,i-1))
        if t <: CppPtr
            types[i] = pointerTo(typeForDecl(lookup_name2(string(t.parameters[1])))).ptr
            args[i] = pcpp"llvm::Value"(ccall(:create_extract_value,Ptr{Void},(Ptr{Void},Csize_t),args[i].ptr,0))
        elseif t <: CppRef 
            # For now
            types[i] = C_NULL
            args[i] = pcpp"llvm::Value"(ccall(:create_extract_value,Ptr{Void},(Ptr{Void},Csize_t),args[i].ptr,0))
        else
            types[i] = C_NULL
        end
        if args[i] == C_NULL
            println((i,t))
            #error("Failed to process argument")
        end
    end
    args, types
end

function _decl_name(d)
    if d == C_NULL
        error("get_name failed")
    end
    s = ccall(:decl_name,Ptr{Uint8},(Ptr{Void},),d)
    ret = bytestring(s)
    c_free(s)
    ret
end

get_pointee_name(t) = _decl_name(@cpp1 t->getPointeeCXXRecordDecl())
get_name(t) = _decl_name(@cpp1 t->getAsCXXRecordDecl())

function cpp_ret_to_julia(args,f,thiscall)
    d = pcpp"clang::Decl"(get_decl(args,f,thiscall))
    t = pcpp"clang::Type"(ccall(:get_result_type,Ptr{Void},(Ptr{Void},),d.ptr))
    if t != C_NULL
        if @cpp1 t->isVoidType()
            return Void
        elseif @cpp1 t->isBooleanType()
            return Bool
        elseif @cpp1 t->isPointerType()
            return CppPtr{symbol(get_pointee_name(t))}
        elseif @cpp1 t->isReferenceType()
            t = pcpp"clang::Type"(ccall(:referenced_type,Ptr{Void},(Ptr{Void},),t.ptr))
            return CppRef{symbol(get_name(t))}
        elseif @cpp1 t->isIntegerType()
            # This is wrong. Might be any int. Need to access the BuiltinType::Kind Enum
            return Int
        end
        return Ptr{Void}
    else
        cxxd = tocxx(d)
        @show cxxd
        if cxxd != C_NULL
            t = typeForDecl(cxxd)
            return CppValue{symbol(get_name(t))}
        else
            error("Unknown type of call!")
        end
    end
end

tname{s}(p::Type{CppPtr{s}}) = p.parameters[1]
cpptype{s}(p::Type{CppPtr{s}}) = pointerTo(typeForDecl(lookup_name2(string(tname(p)))))
get_decl2(args...) = pcpp"clang::Decl"(get_decl(args...))

const default_cgf = (pcpp"clang::CodeGen::CodeGenFunction")(ccall(:clang_get_cgf,Ptr{Void},()))

function cpp_member2(f,mod,argt,func,thiscall)
    println("cpp_member2")
    #Base.dump((f,mod,argt,func,thiscall))
    initialize(mod,f) do
        llvmf = pcpp"llvm::Function"(f)
        d = get_decl2(argt,func,thiscall)
        cxxd = tocxx(d)
        args, types = process_args2(f,argt)
        @show args
        if thiscall
            ct = cpptype(argt[1])
            pvd = CreateParmVarDecl(ct)
            AssociateValue(pvd,ct,args[1])
            dre = CreateDeclRefExpr(pvd,ct)
            me = CreateMemberExpr(dre,true,tovdecl(d))

            callargs = pcpp"clang::Expr"[]
            for i in 2:length(argt)
                argit = cpptype(argt[i])
                @show argit
                argpvd = CreateParmVarDecl(argit)
                AssociateValue(argpvd,argit,args[i])
                push!(callargs,CreateDeclRefExpr(argpvd,argit))
            end

            mce = BuildCallToMemberFunction(me,callargs)

            ret = pcpp"llvm::Value"(ccall(:emitcppmembercallexpr,Ptr{Void},(Ptr{Void},),mce.ptr))
        else
            ret::pcpp"llvm::Value" = pcpp"llvm::Value"(ccall(:emit_cpp_call,Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Ptr{Ptr{Void}},Csize_t,Bool,Bool),
                d,[arg.ptr for arg in args],types,length(args),false,false))
        end
        builder = pcpp"clang::CodeGen::CGBuilderTy"(ccall(:clang_get_builder,Ptr{Void},()))
        if ret == C_NULL
            @cpp1 builder->CreateRetVoid()
        else
            rett = cpp_ret_to_julia(argt,func,thiscall)
            @show rett
            if rett == Void
                @cpp1 builder->CreateRetVoid()
            else
                if rett <: CppPtr || rett <: CppRef
                    llvmt = pcpp"llvm::Type"(@cpp1 llvmf->getReturnType())
                    undef = pcpp"llvm::Value"(@cpp1 llvm::UndefValue::get(llvmt))
                    elty = pcpp"llvm::Type"(@cpp1 llvmt->getStructElementType(uint32(0)))
                    ret = pcpp"llvm::Value"(@cpp1 builder->CreateBitCast(ret,elty))
                    ret = pcpp"llvm::Value"(ccall(:create_insert_value,Ptr{Void},(Ptr{Void},Ptr{Void},Csize_t),undef.ptr,ret.ptr,0))
                end
                @cpp1 builder->CreateRet(ret)
            end
        end
    end
    println("-cpp_member2")
end

function lookup_name2(fname)
    pcpp"clang::Decl"(lookup_name(fname))
end

function cpp_assignment(f,mod,argt,path)
    t = argt[1]
    @assert t <: CppRef
    ct = lookup_name2(string(t.parameters[1]))

end

macro cpp(expr)
    cpps_impl(expr,cpp_member2,cpp_ret_to_julia)
end


function ClangCompiler()
    instance = @cppnew "clang::CompilerInstance"
    @cpp instance->createDiagnostics()
    lopts = @cpp instance->getLangOpts()
    @cpp lopts.CPlusPlus = 1
    @cpp lopts.LineComment = 1
    @cpp lopts.Bool = 1
    @cpp lopts.WChar = 1
    @cpp lopts.C99 = 1
    @cpp lopts.ImplicitInt = 0
    ClangCompiler(instance)
    #@cpp to->Triple = @cpp llvm::sys::getProcessTriple();
    #tin = @cpp clang::TargetInfo::CreateTargetInfo(@cpp instance->getDiagnostics(), to)
    #@cpp instance->setTarget(tin)
    #@cpp instance->createFileManager()
    #@cpp instance->createSourceManager(@cpp instance->getFileManager())
    #@cpp instance->createPreprocessor()
    #@cpp instance->createASTContext()
    #@cpp instance->setASTConsumer(@cppnew JuliaCodeGenerator)
    #@cpp instance->createSema(@cpp clang::TU_Prefix,C_NULL)
    #TD = @cppnew DataLayout(@cpp tin->getTargetDescription())
    #cgm = @cppnew "clang::CodeGen::CodeGenModule"(
    #    @cpp instance->getASTContext(),
    #    @cpp instance->getCodeGenOpts(),
    #    ccall(:jl_get_llvm_module,Ptr{Void},()),
    #    *TD,
    #    @cpp instance->getDiagnostics()
    #)
    #cgt = @cppnew "clang::CodeGen::CodeGenTypes"(*cgm)
    #cgf = @cppnew "clang::CodeGen::CodeGenFunction"(*cgm)
    #new(handle,cgt,cgm)
end

function foo() 
    instance = @cppnew "clang::CompilerInstance"
    @cpp instance->createDiagnostics()
    @cpp instance->getLangOpts()
end

code_llvm(foo,())

const default_compiler = ClangCompiler(
    (pcpp"clang::CompilerInstance")(ccall(:clang_get_instance,Ptr{Void},())),
    (pcpp"clang::CodeGen::CodeGenModule")(ccall(:clang_get_cgm,Ptr{Void},())),
    (pcpp"clang::CodeGen::CodeGenTypes")(ccall(:clang_get_cgt,Ptr{Void},())),
    (pcpp"clang::CodeGen::CodeGenFunction")(ccall(:clang_get_cgf,Ptr{Void},()))
)

f(ee) = @cpp ee->getDataLayout()
code_llvm(f,(pcpp"llvm::ExecutionEngine",))

function sizeof(d::pcpp"clang::CXXRecordDecl")
    @assert d.ptr != C_NULL
    executionEngine = pcpp"llvm::ExecutionEngine"(ccall(:jl_get_llvm_ee,Ptr{Void},()))
    dl = @cpp executionEngine->getDataLayout()
    cgt = default_compiler.cgt
    t = @cpp cgt->ConvertRecordDeclType(d)
    div((@cpp dl->getTypeSizeInBits(t)),8)
end

sizeof(d::pcpp"clang::Decl") = sizeof(tocxx(d))

code_llvm(sizeof,(pcpp"clang::CXXRecordDecl",))
println(sizeof(lookup_name2("clang::CompilerInstance")))

const llvmc = rcpp"llvm::LLVMContext"(ccall(:jl_get_llvmc,Ptr{Void},()))

bar1(r::rcpp"llvm::LLVMContext") = @cpp llvm::Type::getInt8Ty(r)
code_llvm(bar1,(rcpp"llvm::LLVMContext",))
@show bar1(llvmc)

storageFor(d::pcpp"clang::Decl") = Array(Uint8,sizeof(d))

function bar()
    t = typeForDecl(lookup_name2("clang::QualType"))
    pt = pointerTo(t)
    #@show llvmc
    llvmt = bar1(llvmc)
    @show llvmt
    #dump(llvmt)
    pllvmt = @cpp llvm::PointerType::get(llvmt,uint32(0))
    expr = createDeref(pt,@cpp llvm::UndefValue::get(pllvmt))
    @cpp expr->dump()
    expr
end

ct = pointerTo(typeForDecl(lookup_name2("llvm::ExecutionEngine")))
pvd = CreateParmVarDecl(ct)
dump(pvd)
dre = CreateDeclRefExpr(pvd,ct)
dump(dre)
me = CreateMemberExpr(dre,true,tovdecl(lookup_name2("llvm::ExecutionEngine::getDataLayout")))
dump(me)
mce = BuildCallToMemberFunction(me,pcpp"clang::Expr"[])
dump(mce)

baz() = @cpp clang::QualType(p,uint32(0))
code_llvm(baz,())

# THE GOAL FOR TODAY

#function toLLVM(p::pcpp"clang::Type")
 #   cgt = default_compiler.cgt
#    @cpp cgt->ConvertType(@cpp clang::QualType(p,uint32(0)))
#end

#toLLVM(typeForDecl(lookup_name2("llvm::ExecutionEngine")))


#bar(cgt,d) = @cpp cgt->ConvertRecordDeclType(d)
#t = bar(default_compiler.cgt,lookup_name2("clang::CompilerInstance"))
#function baz(cgt)
#   dl = @cpp cgt->getDataLayout()
#end
#dl = baz(default_compiler.cgt)
#test(dl,t) = @cpp dl->getTypeSizeInBits(t)
#test(dl,t)
#test(dl,t)
#println(foo())


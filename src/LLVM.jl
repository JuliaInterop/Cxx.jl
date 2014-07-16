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
        ccall(:init_header,Void,(Ptr{Uint8},),joinpath(dirname(Base.source_path()),"test.h"))
    end
    state
end

function initialize(thunk::Function,mod,f) 
    state=initialize(mod,f)
    thunk()
    cleanup(state)
end

cleanup(state) = ccall(:cleanup_cpp_env,Ptr{Void},(Ptr{Void},),state)

immutable CppPtr{T,targs}
    ptr::Ptr{Void}
end

immutable CppRef{T,targs}
    ptr::Ptr{Void}
end

immutable CppValue{T,targs}
    data::Vector{Uint8}
end

immutable CppPOD{T,N}
    data::NTuple{N,Uint8}
    CppPOD() = new()
end

immutable CppCast{T,To}
    from::T
end
CppCast{T,To}(from::T,::Type{To}) = CppCast{T,To}(from)

macro pcpp_str(s)
    CppPtr{symbol(s),()}
end

macro rcpp_str(s)
    CppRef{symbol(s),()}
end

macro vcpp_str(s)
    CppValue{symbol(s),()}
end

cast{T,To}(from::T,::Type{To}) = CppCast{T,To}(from)

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
==(p1::Ptr,p2::CppPtr) = p1 == p2.ptr

function cpp_arg(T)
    return T
end

function get_decl(argt,func,thiscall)
    if thiscall
        thist = argt[1]
        if !(thist <: CppPtr) && !(thist <: CppRef) && !(thist <: CppValue)
            error("Expected a CppPtr, CppRef or CppValue type, got $thist")
        end
        fname = string(thist.parameters[1],"::",func)
    else
        fname = string(func)
    end
    #println(fname)
    lookup_name(fname)
end

function cpp_argt(args,uuid,fname,thiscall)
    #println("cpp_argt")
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
        #ccall(:cdump,Void,(Ptr{Void},),x)
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

function build_cpp_call1(cexpr,member,ret,prefix,this,uuid)
    @assert isexpr(cexpr,:call)
    fname = string(prefix,cexpr.args[1])
    c = Expr(:call,:llvmcall,Expr(:tuple,member,uuid,fname,this != nothing),
                             Expr(:tuple,ret,uuid,fname,this != nothing),
                             Expr(:tuple,cpp_argt,uuid,fname,this != nothing))
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


function build_ref(expr)
    if isa(expr,Symbol)
        return (expr,)
    elseif isexpr(expr,:(.))
        return tuple(build_ref(expr.args[1])...,build_ref(expr.args[2])...)
    else
        return (expr,)
    end
end

function cpp_ref(expr, prefix, uuid)
    fname = string(prefix,expr)
    c = Expr(:call,:llvmcall,Expr(:tuple,:cpp_ref_ref,uuid,fname),
                         Expr(:tuple,:cpp_ref_ret,uuid,fname),
                         ())
    return c
end

function cpps_impl(expr,member,build_cpp_call,ret,prefix="",uuid = rand(Uint128))
    # Expands a->b to
    # llvmcall((cpp_member,typeof(a),"b"))
    if isa(expr,Symbol)
        error("Unfinished")
        return cpp_ref(expr,prefix,uuid)
    elseif expr.head == :(->)
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
            return build_cpp_call(b,member,ret,prefix,a,uuid)
        else
            Base.dump(expr)
            error("Unsupported!")
        end
    elseif isexpr(expr,:(=))
        flattened = build_ref(expr.args[1])
        return Expr(:call,:llvmcall,Expr(:tuple,:cpp_assignment,uuid,quot(flattened[2:end])),
                Void,Expr(:tuple,:cpp_argt),flattened[1],expr.args[2])
    elseif isexpr(expr,:(::))
        return cpps_impl(expr.args[2],member,build_cpp_call,ret,string(to_prefix(expr.args[1]),"::"),uuid)
    elseif isexpr(expr,:call)
        return build_cpp_call(expr,member,ret,prefix,nothing,uuid)
    end
    error("Unrecognized CPP Expression ",expr," (",expr.head,")")
end

# STAGE 1 BOOTSTRAP



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
        ccall(:emit_cpp_call,Void,(Ptr{Void},Ptr{Ptr{Void}},Ptr{Ptr{Void}},Ptr{Ptr{Void}},Csize_t,Bool,Bool,Ptr{Void}),d,args,types,C_NULL,length(args),false,true,C_NULL)
    end
end

function check_args(argt,f)
    for (i,t) in enumerate(argt)
        if isa(t,UnionType) || (isa(t,DataType) && t.abstract) ||
            (!(t <: CppPtr) && !(t <: CppRef) && !(t <: CppValue) && !(t <: CppCast) && !in(t,
                [Bool, Uint8, Uint32, Uint64, Int64, Ptr{Void}, Ptr{Uint8}]))
            error("Got bad type information while compiling $f (got $t for argument $i)")
        end
    end
end

function cpp_rett(args,uuid,f,thiscall)
    check_args(args,f)
    d = get_decl(args,f,thiscall)
    t = ccall(:get_result_type,Ptr{Void},(Ptr{Void},),d) 
    arr = Array(Ptr{Void},1)
    if llvmcall((compile_func,"clang::Type::isVoidType"),Bool,(Ptr{Void},),t) != 0
        return Void
    end
    if llvmcall((compile_func,"clang::Type::isBooleanType"),Bool,(Ptr{Void},),t) != 0
        return Bool
    end
    if llvmcall((compile_func,"clang::Type::isIntegerType"),Bool,(Ptr{Void},),t) != 0
        # This is wrong. Might be any int. Need to access the BuiltinType::Kind Enum
        return Int
    end
    return Ptr{Void}
end


function cpp_member(f,mod,argt,uuid,func,thiscall)
    #println((f,mod,argt,func,thiscall))
    initialize(mod,f) do 
        d = get_decl(argt,func,thiscall)
        args,types = process_args(f,argt)
        ccall(:emit_cpp_call,Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Ptr{Ptr{Void}},Ptr{Ptr{Void}},Csize_t,Bool,Bool,Ptr{Void}),d,args,types,C_NULL,length(args),false,true,C_NULL)
    end
end

macro cpp1(expr)
    cpps_impl(expr,cpp_member,build_cpp_call1,cpp_rett)
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
const default_compiler = ClangCompiler(
    (pcpp"clang::CompilerInstance")(ccall(:clang_get_instance,Ptr{Void},())),
    (pcpp"clang::CodeGen::CodeGenModule")(ccall(:clang_get_cgm,Ptr{Void},())),
    (pcpp"clang::CodeGen::CodeGenTypes")(ccall(:clang_get_cgt,Ptr{Void},())),
    (pcpp"clang::CodeGen::CodeGenFunction")(ccall(:clang_get_cgf,Ptr{Void},()))
)

lookup_name2(fname) = pcpp"clang::Decl"(lookup_name(fname))
function tocxx(decl::pcpp"clang::Decl")
    @assert decl.ptr != C_NULL
    pcpp"clang::CXXRecordDecl"(ccall(:to_cxxdecl,Ptr{Void},(Ptr{Void},),decl.ptr))
end

RequireCompleteType(d::pcpp"clang::Type") = ccall(:RequireCompleteType,Cint,(Ptr{Void},),d.ptr) > 0

function typeForDecl(cxxdecl::pcpp"clang::CXXRecordDecl")
    @assert cxxdecl.ptr != C_NULL
    pcpp"clang::Type"(@cpp1 cxxdecl->getTypeForDecl())
end
typeForDecl(p::pcpp"clang::Decl") = typeForDecl(tocxx(p))
typeForDecl(p::pcpp"clang::ClassTemplateSpecializationDecl") = typeForDecl(pcpp"clang::CXXRecordDecl"(p.ptr))

function sizeof(d::pcpp"clang::CXXRecordDecl")
    @assert d.ptr != C_NULL
    executionEngine = pcpp"llvm::ExecutionEngine"(ccall(:jl_get_llvm_ee,Ptr{Void},()))
    cgt = pcpp"clang::CodeGen::CodeGenTypes"(ccall(:clang_get_cgt,Ptr{Void},()))
    dl = @cpp1 executionEngine->getDataLayout()
    RequireCompleteType(typeForDecl(d))
    t = pcpp"llvm::Type"(@cpp1 cgt->ConvertRecordDeclType(d))
    @assert @cpp1 t->isSized()
    div((@cpp1 dl->getTypeSizeInBits(t)),8)
end

sizeof(d::pcpp"clang::Decl") = sizeof(tocxx(d))

dump(x::CppPtr) = @cpp1 x->dump()
dump(x::pcpp"clang::Decl") = @cpp1 x->dumpColor()
dump(x::pcpp"clang::Expr") = @cpp1 x->dumpColor()


pointerTo(t::pcpp"clang::Type") = pcpp"clang::Type"(ccall(:getPointerTo,Ptr{Void},(Ptr{Void},),t.ptr))
referenceTo(t::pcpp"clang::Type") = pcpp"clang::Type"(ccall(:getReferenceTo,Ptr{Void},(Ptr{Void},),t.ptr))
createDeref(p::pcpp"clang::Type", val::pcpp"llvm::UndefValue") = pcpp"clang::Expr"(ccall(:createDeref,Ptr{Void},(Ptr{Void},Ptr{Void}),p.ptr,val.ptr))

tovdecl(p::pcpp"clang::Decl") = pcpp"clang::ValueDecl"(ccall(:tovdecl,Ptr{Void},(Ptr{Void},),p.ptr))
CreateDeclRefExpr(p::pcpp"clang::ValueDecl",ty::pcpp"clang::Type") = pcpp"clang::Expr"(ccall(:CreateDeclRefExpr,Ptr{Void},(Ptr{Void},Ptr{Void}),p.ptr,ty.ptr))
CreateDeclRefExpr(p::pcpp"clang::Decl",ty::pcpp"clang::Type") = CreateDeclRefExpr(tovdecl(p),ty)

CreateParmVarDecl(p::pcpp"clang::Type") = pcpp"clang::Decl"(ccall(:CreateParmVarDecl,Ptr{Void},(Ptr{Void},),p.ptr))

CreateMemberExpr(base::pcpp"clang::Expr",isarrow::Bool,member::pcpp"clang::ValueDecl") = pcpp"clang::Expr"(ccall(:CreateMemberExpr,Ptr{Void},(Ptr{Void},Cint,Ptr{Void}),base.ptr,isarrow,member.ptr))
BuildCallToMemberFunction(me::pcpp"clang::Expr", args::Vector{pcpp"clang::Expr"}) = pcpp"clang::Expr"(ccall(:build_call_to_member,Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),
        me.ptr,[arg.ptr for arg in args],length(args)))

BuildCXXTypeConstructExpr(t::pcpp"clang::Type", exprs::Vector{pcpp"clang::Expr"}) = pcpp"clang::Expr"(ccall(:typeconstruct,Ptr{Void},(Ptr{Void},Ptr{Ptr{Void}},Csize_t),t,[expr.ptr for expr in exprs],length(exprs)))

code_llvmf(f,t) = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Any,Bool), f, t, false))

macro code_llvmf(ex0)
    gen_call_with_extracted_types(code_llvmf, ex0)
end

create_extract_value(v::pcpp"llvm::Value",idx) = pcpp"llvm::Value"(ccall(:create_extract_value,Ptr{Void},(Ptr{Void},Csize_t),v.ptr,idx))

tollvmty(t::pcpp"clang::Type") = pcpp"llvm::Type"(ccall(:tollvmty,Ptr{Void},(Ptr{Void},),t.ptr))
getPointerTo(t::pcpp"llvm::Type") = pcpp"llvm::Type"(@cpp1 t->getPointerTo())
getType(v::pcpp"llvm::Value") = pcpp"llvm::Type"(@cpp1 v->getType())
CreateBitCast(builder,data::pcpp"llvm::Value",destty::pcpp"llvm::Type") = pcpp"llvm::Value"(@cpp1 builder->CreateBitCast(data,destty))
CreateLoad(builder,val::pcpp"llvm::Value") = pcpp"llvm::Value"(ccall(:createLoad,Ptr{Void},(Ptr{Void},Ptr{Void}),builder.ptr,val.ptr))

#TODO: Figure out why the first definition doesn't work
#CreateConstGEP1_32(builder,x::pcpp"llvm::Value",idx) = pcpp"llvm::Value"(@cpp1 builder->CreateConstGEP1_32(x,uint32(idx)))
CreateConstGEP1_32(builder,x,idx) = pcpp"llvm::Value"(ccall(:CreateConstGEP1_32,Ptr{Void},(Ptr{Void},Ptr{Void},Uint32),builder,x,uint32(idx)))



function _decl_name(d)
    if d == C_NULL
        error("get_name failed")
    end
    s = ccall(:decl_name,Ptr{Uint8},(Ptr{Void},),d)
    ret = bytestring(s)
    c_free(s)
    ret
end


type CXXState
    callargs
    pvds
    templateresult
    isconstructor
    CXXState() = new()
end

const statemap = (Uint128=>CXXState)[]

state(uuid) = haskey(statemap,uuid) ? statemap[uuid] : (statemap[uuid] = CXXState())
function argexprs(state,argt,derefs,cpptype)
    if !isdefined(state,:callargs)
        state.callargs, state.pvds = buildargexprs(argt,derefs,cpptype)
    end
    @assert length(argt) == length(state.callargs) == length(state.pvds)
    state.callargs, state.pvds
end

get_pointee_name(t) = _decl_name(@cpp1 t->getPointeeCXXRecordDecl())
get_name(t) = _decl_name(@cpp1 t->getAsCXXRecordDecl())

function juliatype(t::pcpp"clang::Type")
    if @cpp1 t->isVoidType()
        return Void
    elseif @cpp1 t->isBooleanType()
        return Bool
    elseif @cpp1 t->isPointerType()
        return CppPtr{symbol(get_pointee_name(t)),()}
    elseif @cpp1 t->isReferenceType()
        t = pcpp"clang::Type"(ccall(:referenced_type,Ptr{Void},(Ptr{Void},),t.ptr))
        return CppRef{symbol(get_name(t)),()}
    elseif @cpp1 t->isIntegerType()
        if t == cpptype(Int64)
            return Int64
        elseif t == cpptype(Uint64)
            return Uint64
        elseif t == cpptype(Uint32)
            return Uint32
        elseif t == cpptype(Int32)
            return Int32
        end
        # This is wrong. Might be any int. Need to access the BuiltinType::Kind Enum
        return Int
    else
        rd = pcpp"clang::CXXRecordDecl"(@cpp1 t->getAsCXXRecordDecl())
        if rd.ptr != C_NULL
            return CppValue{symbol(get_name(t)),()}
        end
    end
    return Ptr{Void}
end

function cppret_constructor(argt,uuid,derefs,targs,f,thiscall,d,juliatype,cpptype)
    cxxd = tocxx(d)
    #@show cxxd
    if cxxd != C_NULL
        # Returned via sret
        return Void
        #t = typeForDecl(cxxd)
        #return CppValue{symbol(get_name(t))}
    else
        cxxt =  cxxtmplt(d)
        s = state(uuid)
        if cxxt != C_NULL
            ts = map(cpptype,targs)
            deduced_class = specialize_template(cxxt,targs,cpptype)
            @assert deduced_class != C_NULL
            s.templateresult = deduced_class
            s.isconstructor = true
            return Void
            #@cpp1 cxxt->findSpecialization(args,nargs,C_NULL)
        else
            # Just blatently assume it's a template call for now
            args = argexprs(s,argt,derefs,cpptype)[1]
            ts = pcpp"clang::Type"[cpptype(t) for t in targs]
            deduced_function = pcpp"clang::FunctionDecl"(ccall(:DeduceTemplateArguments,Ptr{Void},(Ptr{Void},Ptr{Void},Uint32,Ptr{Void},Uint32),d.ptr,ts,length(ts),args,length(args)))
            @assert deduced_function != C_NULL
            s.templateresult = deduced_function
            s.isconstructor = false
            t = pcpp"clang::Type"(ccall(:get_result_type,Ptr{Void},(Ptr{Void},),deduced_function.ptr))
            return juliatype(t)
        end
    end
end

cxxtmplt(x) = pcpp"clang::ClassTemplateDecl"(ccall(:cxxtmplt,Ptr{Void},(Ptr{Void},),x))

function cpp_ret_to_julia(argt,uuid,derefs,targs,f,thiscall)
    check_args(argt,f)
    d = pcpp"clang::Decl"(get_decl(argt,f,thiscall))
    t = pcpp"clang::Type"(ccall(:get_result_type,Ptr{Void},(Ptr{Void},),d.ptr))
    if t != C_NULL
        return juliatype(t)
    else
        return cppret_constructor(argt,uuid,derefs,targs,f,thiscall,d,juliatype,cpptype)
    end
end

tname{s,targs}(p::Type{CppPtr{s,targs}}) = s
tname{s,targs}(p::Type{CppValue{s,targs}}) = s
tname{s,targs}(p::Type{CppRef{s,targs}}) = s
cpptype{s}(p::Type{CppPtr{s,()}}) = pointerTo(typeForDecl(lookup_name2(string(tname(p)))))
cpptype{T<:CppPtr}(p::Type{CppPtr{T,()}}) = pointerTo(cpptype(T))
cpptype{s}(p::Type{CppValue{s,()}}) = typeForDecl(lookup_name2(string(tname(p))))
cpptype{s}(p::Type{CppRef{s,()}}) = referenceTo(typeForDecl(lookup_name2(string(tname(p)))))
cpptype{T}(p::Type{Ptr{T}}) = pointerTo(cpptype(T))

cpptype2(args...) = cpptype(args...)
cpptype2{s}(p::Type{CppPtr{s,()}}) = pointerTo(typeForDecl2(lookup_name2(string(tname(p)))))
cpptype2{T<:CppPtr}(p::Type{CppPtr{T,()}}) = pointerTo(cpptype2(T))
cpptype2{s}(p::Type{CppValue{s,()}}) = typeForDecl2(lookup_name2(string(tname(p))))
cpptype2{s}(p::Type{CppRef{s,()}}) = referenceTo(typeForDecl2(lookup_name2(string(tname(p)))))
cpptype2{T}(p::Type{Ptr{T}}) = pointerTo(cpptype2(T))


function cpptype{s,targs}(p::Type{CppValue{s,targs}})
    typeForDecl(specialize_template(pcpp"clang::ClassTemplateDecl"(lookup_name2(string(tname(p))).ptr),targs,cpptype))
end
function cpptype2{s,targs}(p::Type{CppValue{s,targs}})
    typeForDecl2(specialize_template(pcpp"clang::ClassTemplateDecl"(lookup_name2(string(tname(p))).ptr),targs,cpptype2))
end

get_decl2(args...) = pcpp"clang::Decl"(get_decl(args...))

const default_cgf = (pcpp"clang::CodeGen::CodeGenFunction")(ccall(:clang_get_cgf,Ptr{Void},()))

using Base.Meta

function specialize_template(cxxt::pcpp"clang::ClassTemplateDecl",targs,cpptype)
    ts = pcpp"clang::Type"[cpptype(t) for t in targs]
    d = pcpp"clang::ClassTemplateSpecializationDecl"(ccall(:SpecializeClass,Ptr{Void},(Ptr{Void},Ptr{Void},Uint32),cxxt.ptr,[p.ptr for p in ts],length(ts)))
    d
end

function build_cpp_call2(cexpr,member,ret,prefix,this,uuid)

    
    c = Expr(:call,:llvmcall,Expr(:tuple,member,uuid,derefs,targs,fname,this != nothing),
                             Expr(:tuple,ret,uuid,derefs,targs,fname,this != nothing),
                             Expr(:tuple,cpp_argt,uuid,fname,this != nothing))
    ret = c
    if this != nothing
        push!(c.args,this)
    else
        d = lookup_name2(fname)
        @assert d.ptr != C_NULL
        cxxd = tocxx(d)
        cxxt = cxxtmplt(d)
        if cxxd != C_NULL || cxxt != C_NULL
            T = CppValue{symbol(fname),tuple(targs...)}
            size =  cxxd != C_NULL ? sizeof(cxxd) : sizeof(pcpp"clang::CXXRecordDecl"(specialize_template(cxxt,targs,cpptype).ptr))
            ret = Expr(:block,
                :( r = ($(T))(Array(Uint8,$size)) ),
                c,
                :r)
            push!(c.args,:(convert(Ptr{Void},pointer(r.data))))
        end
    end

    return ret
end

createDerefExpr(e::pcpp"clang::Expr") = pcpp"clang::Expr"(ccall(:createDerefExpr,Ptr{Void},(Ptr{Void},),e.ptr))


function alloc(ty)
    @assert ty <: CppValue
    d = lookup_name2(string(tname(ty)))
    @assert d.ptr != C_NULL
    cxxd = tocxx(d)
    ty(Array(Uint8,sizeof(cxxd)))
end

import Base: getindex

function cppmember23_pre(f,argt,uuid,derefs,targs,func,thiscall,cpp_ret_to_julia,cpptype)
    llvmf = pcpp"llvm::Function"(f)
    s = state(uuid)
    d = isdefined(s,:templateresult) ? pcpp"clang::Decl"(s.templateresult.ptr) : get_decl2(argt,func,thiscall)
    @assert d.ptr != C_NULL
    cxxd = tocxx(d)
    args, types = process_args2(f,argt,builder,cpptype)
    rett = cpp_ret_to_julia(argt,uuid,derefs,targs,func,thiscall)
    rslot = pcpp"llvm::Value"(C_NULL)
    jlrslot = pcpp"llvm::Value"(C_NULL)
    if rett <: CppValue
        if isdefined(s,:isconstructor) && s.isconstructor
            # Via sret
            @assert s.templateresult.ptr == d.ptr
            @assert cxxd != C_NULL
            #t = typeForDecl(d)
            rslot = args[1]
        end
    end
    return (builder,llvmf,d,cxxd,s,args,types,rett,jlrslot,rslot)
end

function BuildMemberReference(base, t, IsArrow, name)
    pcpp"clang::Expr"(ccall(:BuildMemberReference,Ptr{Void},(Ptr{Void},Ptr{Void},Cint,Ptr{Uint8}),base, t, IsArrow, name))
end

function simple_decl_name(d)
    s = ccall(:simple_decl_name,Ptr{Uint8},(Ptr{Void},),d)
    ret = bytestring(s)
    c_free(s)
    ret
end

function cppmember23_post(builder,llvmf,d,cxxd,s,args,types,rett,jlrslot,rslot,argt,uuid,derefs,targs,func,thiscall,adjustargs,cpptype)
    if cxxd != C_NULL
        @assert argt[1] == Ptr{Void}
        #@show argt
        callargs, pvds = argexprs(s,argt[2:end],derefs,cpptype)
        associateargs(builder,argt[2:end],args[2:end],pvds)
        callargs = adjustargs(d,callargs)
        ctce = BuildCXXTypeConstructExpr(typeForDecl(cxxd),callargs)
        #dump(ctce)
        ccall(:emitexprtomem,Void,(Ptr{Void},Ptr{Void},Cint),ctce,args[1],1)
        ret = args[1]
    elseif thiscall
        ct = cpptype(argt[1])
        if argt[1] <: CppValue
            # We want the this argument to be modified in place,
            # so we make a deref of the pointer to the
            # data.
            pct = pointerTo(ct)
            pvd = CreateParmVarDecl(pct)
            AssociateValue(pvd,pct,args[1])
            dre = createDerefExpr(CreateDeclRefExpr(pvd,pct))
        else
            pvd = CreateParmVarDecl(ct)
            AssociateValue(pvd,ct,args[1])
            dre = CreateDeclRefExpr(pvd,ct)
        end
        me = BuildMemberReference(dre, ct, argt[1] <: CppPtr, simple_decl_name(d))
        #me = CreateUnresolvedMemberExpr(false, dre, ct, argt[1] <: CppPtr, get_name(d))
        #me = CreateMemberExpr(dre,argt[1] <: CppPtr,tovdecl(d))

        callargs, pvds = argexprs(s,argt[2:end],derefs,cpptype)
        associateargs(builder,argt[2:end],args[2:end],pvds)
        callargs = adjustargs(d,callargs)
        mce = BuildCallToMemberFunction(me,callargs)

        ret = pcpp"llvm::Value"(ccall(:emitcppmembercallexpr,Ptr{Void},(Ptr{Void},Ptr{Void}),mce.ptr,rslot))
    else
        callargs, pvds = argexprs(s,argt,derefs,cpptype)
        associateargs(builder,argt,args,pvds)
        callargs = adjustargs(d,callargs)
        ret::pcpp"llvm::Value" = pcpp"llvm::Value"(ccall(:emit_cpp_call,Ptr{Void},(Ptr{Void},Ptr{Void},Ptr{Ptr{Void}},Ptr{Void},Csize_t,Bool,Bool,Ptr{Void}),
            d,args,types,callargs,length(args),false,false,rslot))
    end
    if jlrslot != C_NULL && rslot != C_NULL && (length(args) == 0 || rslot != args[1])
        @cpp1 builder->CreateRet(pcpp"llvm::Value"(jlrslot.ptr))
    elseif ret == C_NULL
        @cpp1 builder->CreateRetVoid()
    else
        #@show rett
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

adjustargs_dummy(d,callargs) = callargs

getindex(p::pcpp"clang::FucntionDecl",i) = pcpp"ParamVarDecl"(@cpp1 p->getParamDecl(i))
function cpp_member2(f,mod,argt,uuid,derefs,targs,func,thiscall)
    check_args(argt,f)
    initialize(mod,f) do
        (builder,llvmf,d,cxxd,s,args,types,rett,jlrslot,rslot) = cppmember23_pre(f,argt,uuid,derefs,targs,func,thiscall,cpp_ret_to_julia,cpptype)
        cppmember23_post(builder,llvmf,d,cxxd,s,args,types,rett,jlrslot,rslot,argt,uuid,derefs,targs,func,thiscall,adjustargs_dummy,cpptype)
    end
    delete!(statemap,uuid)
end

function cpp_assignment(f,mod,argt,path)
    t = argt[1]
    @assert t <: CppRef
    ct = lookup_name2(string(t.parameters[1]))

end

chartype() = pcpp"clang::Type"(unsafe_load(cglobal(:cT_cchar,Ptr{Void})))
cpptype(::Type{Uint8}) = chartype()#pcpp"clang::Type"(unsafe_load(cglobal(:cT_uint8,Ptr{Void})))
cpptype(::Type{Int8}) = pcpp"clang::Type"(unsafe_load(cglobal(:cT_int8,Ptr{Void})))
cpptype(::Type{Uint32}) = pcpp"clang::Type"(unsafe_load(cglobal(:cT_uint32,Ptr{Void})))
cpptype(::Type{Int32}) = pcpp"clang::Type"(unsafe_load(cglobal(:cT_int32,Ptr{Void})))
cpptype(::Type{Uint64}) = pcpp"clang::Type"(unsafe_load(cglobal(:cT_uint64,Ptr{Void})))
cpptype(::Type{Int64}) = pcpp"clang::Type"(unsafe_load(cglobal(:cT_int64,Ptr{Void})))
cpptype(::Type{Bool}) = pcpp"clang::Type"(unsafe_load(cglobal(:cT_int1,Ptr{Void})))
cpptype(::Type{Void}) = pcpp"clang::Type"(unsafe_load(cglobal(:cT_void,Ptr{Void})))

macro cpp2(expr)
    cpps_impl(expr,cpp_member2,build_cpp_call2,cpp_ret_to_julia)
end

typeForDecl2(p::pcpp"clang::TypeDecl") = @cpp2 p->getTypeForDecl()
function typeForDecl2(p::pcpp"clang::Decl")
    d::pcpp"clang::Decl" = p
    td = @cpp2 llvm::dyn_cast_or_null{vcpp"clang::TypeDecl"}(d)
    typeForDecl2(td)
end

llvmconst(builder,::Type{Any},x::ANY) =
    (@cpp2 builder->CreateIntToPtr((@cpp2 llvm::ConstantInt::get(llvmty(Uint64),convert(Uint64,pointer_from_objref(x)::Ptr{Void}))), llvmty(Ptr{Void})))
llvmconst{T}(builder,::Type{T},x) = @cpp2 llvm::ConstantInt::get(llvmty(T),convert(Uint64,x))

const llvmc = rcpp"llvm::LLVMContext"(ccall(:jl_get_llvmc,Ptr{Void},()))

llvmty(::Type{Any}) = pcpp"llvm::Type"(unsafe_load(cglobal(:jl_pvalue_llvmt,Ptr{Void})))
llvmty(::Type{Ptr{Void}}) = pcpp"llvm::Type"((@cpp2 (@cpp2 llvm::Type::getInt8Ty(llvmc))->getPointerTo()).ptr)
llvmty(::Type{Uint64}) = pcpp"llvm::Type"((@cpp2 llvm::Type::getInt64Ty(llvmc)).ptr)
llvmty(::Type{Uint32}) = pcpp"llvm::Type"((@cpp2 llvm::Type::getInt32Ty(llvmc)).ptr)

function cpp_ref_ret(retargs...)
    @show retargs
end

function cpp_ref_ref(refargs...)
    @show refargs
end

function adjustEnum(d)

end

const CK_Dependent      = 0
const CK_BitCast        = 1
const CK_LValueBitCast  = 2
const CK_LValueToRValue = 3
const CK_NoOp           = 4
const CK_BaseToDerived  = 5
const CK_DerivedToBase  = 6
const CK_UncheckedDerivedToBase = 7
const CK_Dynamic = 8
const CK_ToUnion = 9
const CK_ArrayToPointerDecay = 10
const CK_FunctionToPointerDecay = 11
const CK_NullToPointer = 12
const CK_NullToMemberPointer = 13
const CK_BaseToDerivedMemberPointer = 14
const CK_DerivedToBaseMemberPointer = 15
const CK_MemberPointerToBoolean = 16
const CK_ReinterpretMemberPointer = 17
const CK_UserDefinedConversion = 18
const CK_ConstructorConversion = 19
const CK_IntegralToPointer = 20
const CK_PointerToIntegral = 21
const CK_PointerToBoolean = 22
const CK_ToVoid = 23
const CK_VectorSplat = 24
const CK_IntegralCast = 25

function createCast(arg,t,kind)
    pcpp"clang::Expr"(ccall(:createCast,Ptr{Void},(Ptr{Void},Ptr{Void},Cint),arg,t,kind))
end

function adjustargs3(d,callargs)
    if @cpp2 llvm::isa{vcpp"clang::FunctionDecl"}(d)
        fdecl = @cpp2 llvm::dyn_cast_or_null{vcpp"clang::FunctionDecl"}(d)
        @assert fdecl != C_NULL
        for i = 0:((@cpp2 fdecl->getNumParams())-1)
            param = @cpp2 fdecl->getParamDecl(i)
            t = pcpp"clang::Type"(ccall(:getOriginalTypePtr,Ptr{Void},(Ptr{Void},),param))
            if @cpp2 t->isEnumeralType()
                callargs[i+1] = createCast(callargs[i+1],t,CK_IntegralCast)
            end
        end
    end
    callargs
end

function cpp_member3(f,mod,argt,uuid,derefs,targs,func,thiscall)
    check_args(argt,f)
    initialize(mod,f) do
        (builder,llvmf,d,cxxd,s,args,types,rett,jlrslot,rslot) = cppmember23_pre(f,argt,uuid,derefs,targs,func,thiscall,cpp_ret_to_julia,cpptype)
        adjustEnum(d)
        cppmember23_post(builder,llvmf,d,cxxd,s,args,types,rett,jlrslot,rslot,argt,uuid,derefs,targs,func,thiscall,adjustargs3,cpptype)
    end
    delete!(statemap,uuid)
end

macro cpp3(expr)
    cpps_impl(expr,cpp_member3,build_cpp_call2,cpp_ret_to_julia)
end

function juliatype4(t::pcpp"clang::Type")
    if @cpp1 t->isVoidType()
        return Void
    elseif @cpp1 t->isBooleanType()
        return Bool
    elseif @cpp1 t->isPointerType()
        cxxd = @cpp3 t->getPointeeCXXRecordDecl()
        if cxxd != C_NULL
            return CppPtr{symbol(get_pointee_name(t)),()}
        else
            pt = pcpp"clang::Type"(ccall(:referenced_type,Ptr{Void},(Ptr{Void},),t.ptr))
            tt = juliatype4(pt)
            if tt <: CppPtr
                return CppPtr{tt,()}
            else
                return Ptr{tt}
            end
        end
    elseif @cpp1 t->isReferenceType()
        t = pcpp"clang::Type"(ccall(:referenced_type,Ptr{Void},(Ptr{Void},),t.ptr))
        return CppRef{symbol(get_name(t)),()}
    elseif @cpp1 t->isCharType()
        return Uint8
    elseif @cpp1 t->isIntegerType()
        if t == cpptype(Int64)
            return Int64
        elseif t == cpptype(Uint64)
            return Uint64
        elseif t == cpptype(Uint32)
            return Uint32
        elseif t == cpptype(Int32)
            return Int32
        elseif t == cpptype(Uint8) || t == chartype()
            return Uint8
        elseif t == cpptype(Int8)
            return Int8
        end
        # This is wrong. Might be any int. Need to access the BuiltinType::Kind Enum
        return Int
    else
        rd = pcpp"clang::CXXRecordDecl"(@cpp1 t->getAsCXXRecordDecl())
        if rd.ptr != C_NULL
            targt = ()
            if @cpp2 llvm::isa{vcpp"clang::ClassTemplateSpecializationDecl"}(pcpp"clang::Decl"(rd.ptr))
                tmplt = @cpp2 llvm::dyn_cast_or_null{vcpp"clang::ClassTemplateSpecializationDecl"}(pcpp"clang::Decl"(rd.ptr))
                targs = @cpp2 tmplt->getTemplateArgs()
                args = pcpp"clang::Type"[]
                for i = 0:((@cpp2 targs->size())-1)
                    targ = @cpp2 targs->get(uint32(i))
                    push!(args,pcpp"clang::Type"(ccall(:getTargType,Ptr{Void},(Ptr{Void},),targ)))
                end
                targt = tuple(map(juliatype4,args)...)
            end
            return CppValue{symbol(get_name(t)),targt}
        end
    end
    return Ptr{Void}
end

function cpp_ret_to_julia4(argt,uuid,derefs,targs,f,thiscall)
    check_args(argt,f)
    d = pcpp"clang::Decl"(get_decl(argt,f,thiscall))
    t = pcpp"clang::Type"(ccall(:get_result_type,Ptr{Void},(Ptr{Void},),d.ptr))
    if t != C_NULL
        return juliatype4(t)
    else
        return cppret_constructor(argt,uuid,derefs,targs,f,thiscall,d,juliatype4,cpptype2)
    end
end

function toLLVM(p::pcpp"clang::Type")
    #cgt = default_compiler.cgt
    cgt = (pcpp"clang::CodeGen::CodeGenTypes")(ccall(:clang_get_cgt,Ptr{Void},()))
    @cpp2 cgt->ConvertType(@cpp2 clang::QualType(p,uint32(0)))
end

function cpp_member4(f,mod,argt,uuid,derefs,targs,func,thiscall)
    check_args(argt,f)
    initialize(mod,f) do
        (builder,llvmf,d,cxxd,s,args,types,rett,jlrslot,rslot) = cppmember23_pre(f,argt,uuid,derefs,targs,func,thiscall,cpp_ret_to_julia4,cpptype2)
        if rett !== Void && rett <: CppValue && (!isdefined(s,:isconstructor) || !s.isconstructor)
            t = pcpp"clang::Type"(ccall(:get_result_type,Ptr{Void},(Ptr{Void},),d.ptr))
            @assert t != C_NULL
            cxxt = pcpp"clang::CXXRecordDecl"(@cpp1 t->getAsCXXRecordDecl())
            jlrslot, rslot = createAlloc(builder,cxxt,rett)
            rslot = @cpp2 builder->CreateBitCast(rslot, getPointerTo(toLLVM(t)))
        end
        cppmember23_post(builder,llvmf,d,cxxd,s,args,types,rett,jlrslot,rslot,argt,uuid,derefs,targs,func,thiscall,adjustargs3,cpptype2)
    end
end

function createAlloc(builder::pcpp"clang::CodeGen::CGBuilderTy",cxxt::pcpp"clang::CXXRecordDecl",rett)
    # Prepare struct return
    # We emit:
    #
    # arr = jl_alloc_array_1d(Uint8,sizeof(cxxt))
    # obj = allocobj(2)
    # obj[0] = rett
    # obj[1] = arr
    #
    # First set up the function objects
    mod = pcpp"llvm::Module"(unsafe_load(cglobal(:clang_shadow_module,Ptr{Void})))
    args = pcpp"llvm::Type"[llvmty(Ptr{Void}),llvmty(Csize_t)]
    nargs::Csize_t = convert(Csize_t,length(args))
    aftype1 = @cpp2 llvm::FunctionType::get(llvmty(Ptr{Void}),
        (@cpp2 llvm::ArrayRef{pcpp"llvm::Type"}(CppPtr{pcpp"llvm::Type",()}(pointer(args)),nargs)),
        false)
    jl_alloc_array = @cpp3 llvm::Function::Create(aftype1, 0,
        pointer("jl_alloc_array_1d"), mod)


    args = pcpp"llvm::Type"[llvmty(Csize_t)]
    nargs = convert(Csize_t,length(args))
    aftype2 = @cpp2 llvm::FunctionType::get(llvmty(Any),
        (@cpp2 llvm::ArrayRef{pcpp"llvm::Type"}(CppPtr{pcpp"llvm::Type",()}(pointer(args)),nargs)),
        false)
    allocobj = @cpp3 llvm::Function::Create(aftype2, 0,
                               pointer("allocobj"), mod)

    # Emit the actual allocation
    puint8 = llvmconst(builder,Any,Array{Uint8,1})
    size = llvmconst(builder,Csize_t,sizeof(cxxt))
    arr = @cpp2 builder::pcpp"clang::CodeGen::CGBuilderTy"->CreateCall2(jl_alloc_array,puint8,size)
    obj = @cpp3 builder::pcpp"clang::CodeGen::CGBuilderTy"->CreateCall(allocobj,llvmconst(builder,Csize_t,2))
    obj2 = @cpp2 builder->CreateBitCast(obj,getPointerTo(llvmty(Ptr{Void})))
    c = llvmconst(builder,Any,rett)
    @cpp2 builder::pcpp"clang::CodeGen::CGBuilderTy"->CreateStore(c,obj2)
    gep = CreateConstGEP1_32(builder,obj2,1)::pcpp"llvm::Value"
    @cpp2 builder::pcpp"clang::CodeGen::CGBuilderTy"->CreateStore(arr,gep)
    arrb = @cpp2 builder->CreateBitCast(arr,getPointerTo(@cpp2 arr->getType()))
    arr2 = @cpp2 builder->CreateLoad(CreateConstGEP1_32(builder,arrb,1))
    obj, arr2
end

macro cpp(expr)
    cpps_impl(expr,cpp_member4,build_cpp_call2,cpp_ret_to_julia4)
end

function ClangCompiler()
    #instance = @cpp2new "clang::CompilerInstance"
    #@cpp2 instance->createDiagnostics()
    #lopts = @cpp2 instance->getLangOpts()
    ##@cpp2 lopts.CPlusPlus = 1
    #@cpp2 lopts.LineComment = 1
    #@cpp2 lopts.Bool = 1
    ##@cpp2 lopts.WChar = 1
    #@cpp2 lopts.C99 = 1
    #@cpp2 lopts.ImplicitInt = 0
    #ClangCompiler(instance)
    #@cpp2 to->Triple = @cpp2 llvm::sys::getProcessTriple();
    #tin = @cpp2 clang::TargetInfo::CreateTargetInfo(@cpp2 instance->getDiagnostics(), to)
    #@cpp2 instance->setTarget(tin)
    #@cpp2 instance->createFileManager()
    #@cpp2 instance->createSourceManager(@cpp2 instance->getFileManager())
    #@cpp2 instance->createPreprocessor()
    #@cpp2 instance->createASTContext()
    #@cpp2 instance->setASTConsumer(@cpp2new JuliaCodeGenerator)
    #@cpp2 instance->createSema(@cpp2 clang::TU_Prefix,C_NULL)
    #TD = @cpp2new DataLayout(@cpp2 tin->getTargetDescription())
    #cgm = @cpp2new "clang::CodeGen::CodeGenModule"(
    #    @cpp2 instance->getASTContext(),
    #    @cpp2 instance->getCodeGenOpts(),
    #    ccall(:jl_get_llvm_module,Ptr{Void},()),
    #    *TD,
    #    @cpp2 instance->getDiagnostics()
    #)
    #cgt = @cpp2new "clang::CodeGen::CodeGenTypes"(*cgm)
    #cgf = @cpp2new "clang::CodeGen::CodeGenFunction"(*cgm)
    #new(handle,cgt,cgm)
end

function foo(instance::pcpp"clang::CompilerInstance") 
    #instance = @cpp2new "clang::CompilerInstance"
    @cpp2 instance->createDiagnostics()
    @cpp2 instance->getLangOpts()
end

#code_llvm(foo,(pcpp"clang::CompilerInstance",))


#f(ee) = @cpp2 ee->getDataLayout()
#code_llvm(f,(pcpp"llvm::ExecutionEngine",))



#code_llvm(sizeof,(pcpp"clang::CXXRecordDecl",))
#println(sizeof(lookup_name2("clang::CompilerInstance")))

bar1(r::rcpp"llvm::LLVMContext") = @cpp2 llvm::Type::getInt8Ty(r)
#code_llvm(bar1,(rcpp"llvm::LLVMContext",))
#@show bar1(llvmc)

storageFor(d::pcpp"clang::Decl") = Array(Uint8,sizeof(d))

function bar()
    t = typeForDecl(lookup_name2("clang::QualType"))
    pt = pointerTo(t)
    #@show llvmc
    llvmt = bar1(llvmc)
    @show llvmt
    #dump(llvmt)
    pllvmt = @cpp2 llvm::PointerType::get(llvmt,uint32(0))
    expr = createDeref(pt,@cpp2 llvm::UndefValue::get(pllvmt))
    @cpp2 expr->dump()
    expr
end

#ct = pointerTo(typeForDecl(lookup_name2("llvm::ExecutionEngine")))
#pvd = CreateParmVarDecl(ct)
#dump(pvd)
#dre = CreateDeclRefExpr(pvd,ct)
#dump(dre)
#me = CreateMemberExpr(dre,true,tovdecl(lookup_name2("llvm::ExecutionEngine::getDataLayout")))
#dump(me)
#mce = BuildCallToMemberFunction(me,pcpp"clang::Expr"[])
#dump(mce)

#baz() = @cpp2 clang::SourceLocation()
#code_llvm(baz,())

#dump(cpptype(Uint32))

#code_llvm(toLLVM,(pcpp"clang::Type",))

#toLLVM(typeForDecl(lookup_name2("llvm::ExecutionEngine")))

# THE GOAL FOR TODAY
# Create a graph from a function

function baz()
    graphf = code_llvmf(toLLVM,(pcpp"clang::Type",))
    @cpp2 llvm::ViewGraph(graphf,@cpp2 llvm::Twine())
end

#code_lowered(baz,())
#code_llvm(baz,())

dump(x::CppRef) = @cpp2 x->dump()

sstring = pcpp"clang::ClassTemplateSpecializationDecl"(lookup_name2("std::string").ptr)

get_targs(x) = @cpp2 x->getTemplateArgs()
getindex(targ::rcpp"clang::TemplateArgumentList",i) = @cpp2 targ->get(uint32(i))

function astype(targ::rcpp"clang::TemplateArgument")
    t = @cpp2 targ->getAsType()
    @cpp2 t->getTypePtr()
end

#dump(astype(get_targs(sstring)[0]))



#code_llvm(baz2,())
#code_llvmf(baz2,())
sdata(v) = @cpp v->data()
ssize(v) = @cpp v->size()
test() = @cpp std::string(pointer("test"),4)


using Cairo
using GraphViz

#Graph(baz2(toLLVM,(pcpp"clang::Type",))) |> display

#println("SUCCESS")

# Debugger
initd() = @cpp lldb_private::Debugger::Initialize(cast(C_NULL,vcpp"lldb_private::Debugger::LoadPluginCallbackType"))
initd()

gc_disable()

debugger() = @cpp vcpp"lldb::DebuggerSP"((@cpp lldb_private::Debugger::CreateInstance()).data)->get()
const dbg = debugger()
ci(dbg::pcpp"lldb_private::Debugger") = @cpp dbg->GetCommandInterpreter()
function hc(ci::rcpp"lldb_private::CommandInterpreter",cmd)
    cro = @cpp lldb_private::CommandReturnObject()
    @cpp ci->HandleCommand(pointer(cmd),0,cro)
    @cpp cro->GetOutputData()
end

stdout = pcpp"FILE"(ccall(:fdopen,Ptr{Void},(Int32,Ptr{Uint8}),1,"a"))

function setSTDOUT(dbg,stdout)
    @cpp dbg->SetOutputFileHandle(stdout,false)
end

function setSTDERR(dbg,stdout)
    @cpp dbg->SetErrorFileHandle(stdout,false)
end

setSTDOUT(dbg,stdout)
setSTDERR(dbg,stdout)

#Graph(baz2()) |> display

#bar(cgt,d) = @cpp2 cgt->ConvertRecordDeclType(d)
#t = bar(default_compiler.cgt,lookup_name2("clang::CompilerInstance"))
#function baz(cgt)
#   dl = @cpp2 cgt->getDataLayout()
#end
#dl = baz(default_compiler.cgt)
#test(dl,t) = @cpp2 dl->getTypeSizeInBits(t)
#test(dl,t)
#test(dl,t)
#println(foo())


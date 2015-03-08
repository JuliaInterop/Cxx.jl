# cxx"" string implementation (global scope)

global varnum = 1

const jns = cglobal((:julia_namespace,libcxxffi),Ptr{Void})

#
# Takes a julia value and makes in into an llvm::Constant
#
function llvmconst(val::ANY)
    T = typeof(val)
    if isbits(T)
        if !Base.isstructtype(T)
            if T <: FloatingPoint
                return getConstantFloat(julia_to_llvm(T),float64(val))
            else
                return getConstantInt(julia_to_llvm(T),uint64(val))
            end
        else
            vals = [getfield(val,i) for i = 1:length(T.names)]
            return getConstantStruct(julia_to_llvm(T),vals)
        end
    end
    error("Cannot turn this julia value into a constant")
end

function SetDeclInitializer(C,decl::pcpp"clang::VarDecl",val::pcpp"llvm::Constant")
    ccall((:SetDeclInitializer,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void},Ptr{Void}),&C,decl,val)
end

function ssv(C,e::ANY,ctx,varnum,thunk)
    T = typeof(e)
    if isa(e,Expr) || isa(e,Symbol)
        # Create a thunk that contains this expression
        linfo = thunk.code
        (tree, ty) = Base.typeinf(linfo,(),())
        T = ty
        thunk.code.ast = tree
        # Pretend we're a specialized generic function
        # to get the good calling convention. The compiler
        # will never know :)
        setfield!(thunk.code,6,())
        if isa(T,UnionType) || T.abstract
            error("Inferred Union or abstract type $T for expression $e")
        end
        sv = CreateFunctionDecl(C,ctx,string("call",varnum),makeFunctionType(C,cpptype(C,T),QualType[]))
        e = thunk
    else
        name = string("var",varnum)
        sv = CreateVarDecl(C,ctx,name,cpptype(C,T))
    end
    AddDeclToDeclCtx(ctx,pcpp"clang::Decl"(sv.ptr))
    e, sv
end

function ArgCleanup(C,e,sv)
    if isa(sv,pcpp"clang::FunctionDecl")
        f = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Ptr{Void},Bool), e, C_NULL, false))
        ReplaceFunctionForDecl(C,sv,f)
    else
        SetDeclInitializer(C,sv,llvmconst(e))
    end
end

const sourcebuffers = Array((String,Symbol,Int,Int),0)

immutable SourceBuf{id}; end
sourceid{id}(::Type{SourceBuf{id}}) = id

icxxcounter = 0

function ActOnStartOfFunction(C,D)
    pcpp"clang::Decl"(ccall((:ActOnStartOfFunction,libcxxffi),
        Ptr{Void},(Ptr{ClangCompiler},Ptr{Void}),&C,D))
end
function ParseFunctionStatementBody(C,D)
    ccall((:ParseFunctionStatementBody,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void}),&C,D)
end

function ActOnStartNamespaceDef(C,name)
    pcpp"clang::Decl"(ccall((:ActOnStartNamespaceDef,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{Uint8}),&C,name))
end
function ActOnFinishNamespaceDef(C,D)
    ccall((:ActOnFinishNamespaceDef,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void}),&C,D)
end

function EmitTopLevelDecl(C, D::pcpp"clang::Decl")
    if isDeclInvalid(D)
        error("Tried to emit invalid decl")
    end
    ccall((:EmitTopLevelDecl,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void}),&C,D)
end
EmitTopLevelDecl(C,D::pcpp"clang::FunctionDecl") = EmitTopLevelDecl(C,pcpp"clang::Decl"(D.ptr))

SetFDParams(FD::pcpp"clang::FunctionDecl",params::Vector{pcpp"clang::ParmVarDecl"}) =
    ccall((:SetFDParams,libcxxffi),Void,(Ptr{Void},Ptr{Ptr{Void}},Csize_t),FD,[p.ptr for p in params],length(params))

#
# Create a clang FunctionDecl with the given body and
# and the given types for embedded __juliavars
#
function CreateFunctionWithBody(C,body,args...; filename = symbol(""), line = 1, col = 1)
    global icxxcounter

    argtypes = (Int,QualType)[]
    typeargs = (Int,QualType)[]
    callargs = Int[]
    llvmargs = Any[]
    argidxs = Int[]
    # Make a first part about the arguments
    # and replace __juliavar$i by __julia::type$i
    # for all types. Also remember all types and remove them
    # from `args`.
    for (i,arg) in enumerate(args)
        # We passed in an actual julia type
        if arg <: Type
            body = replace(body,"__juliavar$i","__juliatype$i")
            push!(typeargs,(i,cpptype(C,arg.parameters[1])))
        else
            # This is temporary until we can find a better solution
            if arg <: Function
                body = replace(body,"__juliavar$i","jl_call0(__juliavar$i)")
                push!(callargs,i)
                T = cpptype(C,pcpp"jl_function_t")
            else
                T = cpptype(C,arg)
            end
            (arg <: CppValue) && (T = referenceTo(C,T))
            push!(argtypes,(i,T))
            push!(llvmargs,arg)
            push!(argidxs,i)
        end
    end

    if filename == symbol("")
        EnterBuffer(C,body)
    else
        EnterVirtualSource(C,body,VirtualFileName(filename))
    end

    local FD
    local dne
    try
        ND = ActOnStartNamespaceDef(C,"__icxx")
        fname = string("icxx",icxxcounter)
        icxxcounter += 1
        ctx = toctx(ND)
        FD = CreateFunctionDecl(C,ctx,fname,makeFunctionType(C,QualType(C_NULL),
            QualType[ T for (_,T) in argtypes ]),false)
        params = pcpp"clang::ParmVarDecl"[]
        for (i,argt) in argtypes
            param = CreateParmVarDecl(C, argt,string("__juliavar",i))
            push!(params,param)
        end
        for (i,T) in typeargs
            D = CreateTypeDefDecl(C,ctx,"__juliatype$i",T)
            AddDeclToDeclCtx(ctx,pcpp"clang::Decl"(D.ptr))
        end
        SetFDParams(FD,params)
        FD = ActOnStartOfFunction(C,pcpp"clang::Decl"(FD.ptr))
        ParseFunctionStatementBody(C,FD)
        ActOnFinishNamespaceDef(C,ND)
    catch e
        @show e
    end

    #dump(FD)

    EmitTopLevelDecl(C,FD)

    FD, llvmargs, argidxs
end

function CallDNE(C, dne, argt; kwargs...)
    callargs, pvds = buildargexprs(C,argt)
    ce = CreateCallExpr(C, dne,callargs)
    EmitExpr(C,ce,C_NULL,C_NULL,argt,pvds; kwargs...)
end

stagedfunction cxxstr_impl(CT, sourcebuf, args...)
    C = instance(CT)
    id = sourceid(sourcebuf)
    buf, filename, line, col = sourcebuffers[id]

    FD, llvmargs, argidxs = CreateFunctionWithBody(C,buf, args...; filename = filename, line = line, col = col)

    dne = CreateDeclRefExpr(C,FD)
    argt = tuple(llvmargs...)
    return CallDNE(C,dne,argt; argidxs = argidxs)
end

#
# Generate a virtual name for a file in the same directory as `filename`.
# This will be the virtual filename for clang to refer to the source snippet by.
# What this is doesn't really matter as long as it's distring for every snippet,
# as we #line it to the proper filename afterwards anyway.
#
VirtualFileNameCounter = 0
function VirtualFileName(filename)
    global VirtualFileNameCounter
    name = joinpath(dirname(string(filename)),string("__cxxjl_",VirtualFileNameCounter,".cpp"))
    VirtualFileNameCounter += 1
    name
end

function process_cxx_string(str,global_scope = true,filename=symbol(""),line=1,col=1;
    compiler = :__current_compiler__)
    # First we transform the source buffer by pulling out julia expressions
    # and replaceing them by expression like __julia::var1, which we can
    # later intercept in our external sema source
    # TODO: Consider if we need more advanced scope information in which
    # case we should probably switch to __julia_varN instead of putting
    # things in namespaces.
    # TODO: It would be nice diagnostics were reported on the original source,
    # rather than the source with __julia* substitutions
    pos = 1
    sourcebuf = IOBuffer()
    if !global_scope
        write(sourcebuf,"{\n")
    end
    if filename != symbol("")
        if filename == :none
            filename = :REPL
        end
        write(sourcebuf,"#line $line \"$filename\"\n")
        if filename == :REPL
            filename = symbol(joinpath(pwd(),"REPL"))
        end
    end
    # Clang has no function for setting the column
    # so we just write a bunch of spaces to match the
    # indentation for the first line.
    # However, due to the processing below columns are off anyway,
    # so let's not do this until we can actually gurantee it'll be correct
    # for _ in 1:(col-1)
    #    write(sourcebuf," ")
    # end
    exprs = Any[]
    isexprs = Bool[]
    global varnum
    startvarnum = varnum
    localvarnum = 1
    while true
        idx = search(str,'$',pos)
        if idx == 0
            write(sourcebuf,str[pos:end])
            break
        end
        write(sourcebuf,str[pos:(idx-1)])
        # Parse the first expression after `$`
        expr,pos = parse(str, idx + 1; greedy=false)
        push!(exprs,expr)
        isexpr = (str[idx+1] == ':')
        push!(isexprs,isexpr)
        if global_scope
            write(sourcebuf,
                isexpr ? string("__julia::call",varnum,"()") :
                         string("__julia::var",varnum))
            varnum += 1
        else
            write(sourcebuf, string("__juliavar",localvarnum))
            localvarnum += 1
        end
    end
    if global_scope
        argsetup = Expr(:block)
        argcleanup = Expr(:block)
        instance = :( Cxx.instance($compiler) )
        for expr in exprs
            s = gensym()
            sv = gensym()
            push!(argsetup.args,quote
                ($s, $sv) =
                    let e = $expr
                        Cxx.ssv($instance,e,ctx,$startvarnum,eval(:( ()->($e) )))
                    end
                end)
            startvarnum += 1
            push!(argcleanup.args,:(Cxx.ArgCleanup($instance,$s,$sv)))
        end
        parsecode = filename == "" ? :( cxxparse($instance,$(takebuf_string(sourcebuf))) ) :
            :( Cxx.ParseVirtual($instance, $(takebuf_string(sourcebuf)),
                $( VirtualFileName(filename) ),
                $( quot(filename) ),
                $( line ),
                $( col )) )
        return quote
            let
                jns = cglobal((:julia_namespace,$libcxxffi),Ptr{Void})
                ns = Cxx.createNamespace($instance,"julia")
                ctx = Cxx.toctx(pcpp"clang::Decl"(ns.ptr))
                unsafe_store!(jns,ns.ptr)
                $argsetup
                $parsecode
                unsafe_store!(jns,C_NULL)
                $argcleanup
            end
        end
    else
        write(sourcebuf,"\n}")
        push!(sourcebuffers,(takebuf_string(sourcebuf),filename,line,col))
        id = length(sourcebuffers)
        setup = Expr(:block)
        cxxstr = Expr(:call,cxxstr_impl,compiler,:(Cxx.SourceBuf{$id}()))
        for (i,e) in enumerate(exprs)
            if isexprs[i]
                s = gensym()
                if isa(e,QuoteNode)
                    e = e.value
                elseif isexpr(e,:quote)
                    e = e.args[1]
                else
                    error("Unrecognized expression type for quote in icxx")
                end
                push!(setup.args,Expr(:(=),s,Expr(:->,Expr(:tuple),e)))
                push!(cxxstr.args,s)
            else
                push!(cxxstr.args,e)
            end
        end
        push!(setup.args,cxxstr)
        return setup
    end
end

macro cxx_str(str,args...)
    esc(process_cxx_string(str,true,args...))
end

macro icxx_str(str,args...)
    esc(process_cxx_string(str,false,args...))
end

macro icxx_mstr(str,args...)
    esc(process_cxx_string(str,false,args...))
end

macro cxx_mstr(str,args...)
    esc(process_cxx_string(str,true,args...))
end

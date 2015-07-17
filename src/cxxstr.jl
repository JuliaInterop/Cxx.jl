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
                return getConstantFloat(julia_to_llvm(T),Float64(val))
            elseif T <: Integer
                return getConstantInt(julia_to_llvm(T),UInt64(val))
            elseif T <: Ptr
                int = getConstantInt(julia_to_llvm(UInt64),UInt64(val))
                return getConstantIntToPtr(int, julia_to_llvm(T))
            else
                error("Creating LLVM constants for type `T` not implemented yet")
            end
        else
            vals = [getfield(val,i) for i = 1:length(fieldnames(T))]
            return getConstantStruct(julia_to_llvm(T),vals)
        end
    end
    error("Cannot turn this julia value (of type `$T`) into a constant")
end

function SetDeclInitializer(C,decl::pcpp"clang::VarDecl",val::pcpp"llvm::Constant")
    ccall((:SetDeclInitializer,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void},Ptr{Void}),&C,decl,val)
end

function ssv(C,e::ANY,ctx,varnum,thunk,sourcebuf,typeargs=Dict{Void,Void}())
    if isa(e,Expr) || isa(e,Symbol)
        T = typeof(e)
        # Create a thunk that contains this expression
        linfo = thunk.code
        (tree, ty) = Core.Inference.typeinf(linfo,Tuple{},svec())
        T = ty
        thunk.code.ast = tree
        # Pretend we're a specialized generic function
        # to get the good calling convention. The compiler
        # will never know :)
        setfield!(thunk.code,6,Tuple{})
        if T === Union{}
            T = Nothing
        end
        if isa(T,UnionType) || T.abstract
            error("Inferred Union or abstract type $T for expression $e")
        end
        sv = CreateFunctionDecl(C,ctx,string("call",varnum),makeFunctionType(C,cpptype(C,T),QualType[]))
        e = thunk
    elseif isa(e,Type)
        QT = cpptype(C,e)
        name = string("var",varnum)
        sv = CreateTypeDefDecl(C,ctx,name,QT)
    elseif isa(e,TypeVar)
        str = takebuf_string(sourcebuf)
        name = string("var",varnum)
        write(sourcebuf, replace(str, string("__julia::var",varnum), name))
        sv = ActOnTypeParameterParserScope(C,name,varnum)
        typeargs[varnum] = e
        return e, sv
    else
        e = cppconvert(e)
        T = typeof(e)
        name = string("var",varnum)
        sv = CreateVarDecl(C,ctx,name,cpptype(C,T))
    end
    AddDeclToDeclCtx(ctx,pcpp"clang::Decl"(sv.ptr))
    e, sv
end

# Create two functions
#
# template < class a, class b, class c >
# foo(a x, b y, c z) { foo_back(&x,&y,&z); }
# template < class a, class b, class c >
# foo_back(a x, b y c z);
#
# where foo_back is the one that will evntually be instantiated
#
function CreateTemplatedLambdaCall(C,DC,callnum,nargs)
    TPs = [ ActOnTypeParameter(C,string("param",i),i-1) for i = 1:nargs ]
    Params = CreateTemplateParameterList(C,TPs)
    argts = QualType[ typeForDecl(T) for T in TPs ]
    FD = CreateFunctionDecl(C, DC, string("call",callnum) ,makeFunctionType(C,cpptype(C,Void),argts))
    params = pcpp"clang::ParmVarDecl"[
        CreateParmVarDecl(C, argt,string("__juliavar",i)) for (i,argt) in enumerate(argts)]
    SetFDParams(FD,params)
    D = CreateFunctionTemplateDecl(C,DC,Params,FD)
    AddDeclToDeclCtx(DC,pcpp"clang::Decl"(D.ptr))
    D
end

substitute_symbols!(s::Symbol,substs) = haskey(substs,s) ? substs[s] : s
substitute_symbols!(s::GlobalRef, substs) =
  haskey(substs,s.name) ? substs[s.name] : s
function substitute_symbols!(e::Expr,substs)
    for i in 1:length(e.args)
        if !isa(e.args[i],Symbol) && !isa(e.args[i],Expr) &&
           !isa(e.args[i],GlobalRef)
            continue
        end
        e.args[i] = substitute_symbols!(e.args[i],substs)
    end
    e
end

function InstantiateLambdaTypeForType(C, FD, julia_type)
    hasFDBody(FD) && return
    Lit = CreateIntegerLiteral(C, convert(UInt, pointer_from_objref(julia_type)), cpptype(C, UInt))
    jl_value_t = QualType(typeForDecl(lookup_name(C,["jl_value_t"])))
    Casted = createCast(C, Lit, pointerTo(C,jl_value_t), CK_IntegralToPointer)
    RetStmt = CreateReturnStmt(C, Casted)
    ActOnStartOfFunction(C, FD, true)
    ActOnFinishFunctionBody(C, FD, RetStmt)
end

function createLambdaTypeSpecialization(C, lambda_typeD, T)
    haskey(lambdaIndxes, T) && return
    julia_type = lambdaForType(T)
    spec = specialize_template_clang(C, pcpp"clang::ClassTemplateDecl"(lambda_typeD.ptr), [T])
    d = pcpp"clang::Decl"(spec.ptr)
    result = pcpp"clang::VarDecl"(_lookup_name(C, "type", toctx(d)).ptr)
    SetDeclInitializer(C, result, llvmconst(pointer_from_objref(julia_type)))
end

function InstantiateLambdaType(C)
    D = lookup_name(C,["jl_calln"])
    lambda_typeD = lookup_name(C,["lambda_type"])
    sps = getSpecializations(D)
    for x in sps
        hasFDBody(x) && continue
        targs = templateParameters(x)
        args = Any[]
        for i = 0:(getTargsSize(targs)-1)
            kind = getTargKindAtIdx(targs,i)
            if kind == KindType
                T = getTargTypeAtIdx(targs,i)
                createLambdaTypeSpecialization(C, lambda_typeD, T)
            elseif kind == KindPack
                for j = 0:(getTargPackAtIdxSize(targs,i)-1)
                    targ = getTargPackAtIdxTargAtIdx(targs,i,j)
                    @assert getTargKind(targ) == KindType
                    T = getTargType(targ)
                    createLambdaTypeSpecialization(C, lambda_typeD, T)
                end
            else
                error("Unhandled template argument kind for lambda_type ($kind)")
            end
        end
    end
end

function CreateLambdaCallExpr(C, T, argt = [])
    meth = getLambdaCallOperator(getAsCXXRecordDecl(T))

    callargs, cpvds = buildargexprs(C,argt)
    PVoid = cpptype(C,Ptr{Void})
    pvd = CreateParmVarDecl(C, PVoid)
    pvds = [pvd]
    append!(pvds, cpvds)

    Tptr = pointerTo(C,T)
    Closure = CreateCStyleCast(C,createCast(C,CreateDeclRefExpr(C,pvd),PVoid,CK_LValueToRValue),Tptr)
    ce = CreateCallExpr(C,createDerefExpr(C,Closure),callargs)

    rt = GetExprResultType(ce)
    ce, rt, pvds
end

function InstantiateSpecializations(C,DC,D,expr,syms,icxxs)
    sps = getSpecializations(D)
    for x in sps
        bodies = Expr[]
        TP = templateParameters(x)
        nargs = getTargsSize(TP)

        PVoid = cpptype(C,Ptr{Void})
        tpvds = pcpp"clang::ParmVarDecl"[]

        for i = 1:nargs
            T = getTargTypeAtIdx(TP,i-1)

            # Step 1: Find the this lambda's call operator and wrap it using
            # the generic machinery
            ce, rt, pvds = CreateLambdaCallExpr(C, T)
            push!(tpvds, getParmVarDecl(x,i-1))

            body = EmitExpr(C,ce,C_NULL,C_NULL,[Ptr{Void}],pvds; symargs = (:($(syms[i])),))
            push!(bodies,body)
        end

        # Step 2: Create the instantiated julia function
        F = deepcopy(expr)

        # Collect substitutions
        substs = Dict{Symbol,Any}()
        for (i,(j,_)) in enumerate(icxxs)
            substs[j] = bodies[i]
        end

        # Apply them
        ast = Base.uncompressed_ast(F.code)
        substitute_symbols!(ast,substs)
        F.code.ast = ast

        # Perform type inference
        linfo = F.code
        ST = Tuple{[Ptr{Void} for _ in 1:nargs]...}
        (tree, ty) = Core.Inference.typeinf(linfo,ST,svec())
        T = ty
        F.code.ast = tree

        # Pretend we're a specialized generic function
        # to get the good calling convention. The compiler
        # will never know :)
        setfield!(F.code,6,ST)
        if T === Union{}
            T = Nothing
        end
        if isa(T,UnionType) || T.abstract
            error("Inferred Union or abstract type $T for expression $F")
        end
        if T !== Nothing
            error("Currently only `Nothing` is supported for nested expressions")
        end

        f = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Ptr{Void},Bool), F, C_NULL, false))
        @assert f != C_NULL

        # Create a Clang function Decl to represent this julia function
        ExternCDC = CreateLinkageSpec(C, DC, LANG_C)
        JFD = CreateFunctionDecl(C, ExternCDC, getName(f), makeFunctionType(C, cpptype(C,T), [PVoid for _ = 1:nargs]))

        # Create the body for the instantiation
        JCE = CreateCallExpr(C,CreateFunctionRefExpr(C, JFD),
                [ createCast(C,CreateAddrOfExpr(C,CreateDeclRefExpr(C,pvd)),PVoid,CK_BitCast) for pvd in tpvds ])
        SetFDBody(x,CreateReturnStmt(C,JCE))

        for pvd in tpvds
            SetDeclUsed(C,pvd)
        end

        # Now that the specialization has a body, emit it
        EmitTopLevelDecl(C, x)
    end
end

function ArgCleanup(C,e,sv)
    if isa(sv,pcpp"clang::FunctionDecl")
        f = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Ptr{Void},Bool), e, C_NULL, false))
        ReplaceFunctionForDecl(C,sv,f)
    elseif !isa(e,Type) && !isa(e,TypeVar)
        SetDeclInitializer(C,sv,llvmconst(e))
    end
end

const sourcebuffers = Array(Tuple{String,Symbol,Int,Int},0)

immutable SourceBuf{id}; end
sourceid{id}(::Type{SourceBuf{id}}) = id

icxxcounter = 0

function ActOnStartOfFunction(C,D,ScopeIsNull = false)
    pcpp"clang::Decl"(ccall((:ActOnStartOfFunction,libcxxffi),
        Ptr{Void},(Ptr{ClangCompiler},Ptr{Void},Bool),&C,D,ScopeIsNull))
end
function ParseFunctionStatementBody(C,D)
    if ccall((:ParseFunctionStatementBody,libcxxffi),Bool,(Ptr{ClangCompiler},Ptr{Void}),&C,D) == 0
        dump(D)
        error("A failure occured while parsing the function body")
    end
end

function ActOnStartNamespaceDef(C,name)
    pcpp"clang::Decl"(ccall((:ActOnStartNamespaceDef,libcxxffi),Ptr{Void},
        (Ptr{ClangCompiler},Ptr{UInt8}),&C,name))
end
function ActOnFinishNamespaceDef(C,D)
    ccall((:ActOnFinishNamespaceDef,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void}),&C,D)
end

function EmitTopLevelDecl(C, D::pcpp"clang::Decl")
    HadErrors = ccall((:EmitTopLevelDecl,libcxxffi),Bool,(Ptr{ClangCompiler},Ptr{Void}),&C,D)
    if HadErrors
        error("Tried to Emit Invalid Decl")
    end
end
EmitTopLevelDecl(C,D::pcpp"clang::FunctionDecl") = EmitTopLevelDecl(C,pcpp"clang::Decl"(D.ptr))

SetFDParams(FD::pcpp"clang::FunctionDecl",params::Vector{pcpp"clang::ParmVarDecl"}) =
    ccall((:SetFDParams,libcxxffi),Void,(Ptr{Void},Ptr{Ptr{Void}},Csize_t),FD,[p.ptr for p in params],length(params))

#
# Create a clang FunctionDecl with the given body and
# and the given types for embedded __juliavars
#
function CreateFunctionWithBody(C,body,args...; filename::Symbol = symbol(""), line::Int = 1, col::Int = 1)
    global icxxcounter

    argtypes = Tuple{Int,QualType}[]
    typeargs = Tuple{Int,QualType}[]
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
        # Make sure to note that an exception occured, in case
        # it gets swallowed by the staged function
        println("Caught exception")
        rethrow(e)
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

@generated function cxxstr_impl(CT, sourcebuf, args...)
    C = instance(CT)
    id = sourceid(sourcebuf)
    buf, filename, line, col = sourcebuffers[id]

    FD, llvmargs, argidxs = CreateFunctionWithBody(C,buf, args...; filename = filename, line = line, col = col)

#    @show "test"
#    dump(FD)
    InstantiateLambdaType(C)

    dne = CreateDeclRefExpr(C,FD)
    argt = tuple(llvmargs...)
    CallDNE(C,dne,argt; argidxs = argidxs)
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

function find_expr(sourcebuf,str,pos = 1)
    idx = search(str,'$',pos)
    if idx == 0
        write(sourcebuf,str[pos:end])
        return nothing, false, endof(str)+1
    end
    if idx != 1 && str[idx-1] == '\\'
        write(sourcebuf,str[pos:(idx-2)])
        write(sourcebuf,'$')
        pos = idx + 1
        return nothing, false, pos
    end
    write(sourcebuf,str[pos:(idx-1)])
    # Parse the first expression after `$`
    expr,pos = parse(str, idx + 1; greedy=false)
    isexpr = (str[idx+1] == ':')
    expr, isexpr, pos
end

function collect_exprs(str)
    sourcebuf = IOBuffer()
    pos = 1
    i = 0
    exprs = Any[]
    while pos <= endof(str)
        expr, isexpr, pos = find_expr(sourcebuf,str,pos)
        expr == nothing && continue
        write(sourcebuf,string("__lambdaarg",i))
        push!(exprs, (expr, isexpr))
    end
    exprs, takebuf_string(sourcebuf)
end

collect_icxx(s,icxxs) = s
function collect_icxx(e::Expr,icxxs)
    if isexpr(e,:macrocall) && e.args[1] == symbol("@icxx_str")
        x = gensym()
        exprs, str = collect_exprs(e.args[2])
        push!(icxxs, (x,str,exprs))
        return x
    else
        for i in 1:length(e.args)
            e.args[i] = collect_icxx(e.args[i], icxxs)
        end
    end
    e
end

function process_body(str, global_scope = true, filename=symbol(""),line=1,col=1)
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
    icxxs = Any[]
    global varnum
    startvarnum = varnum
    localvarnum = 1
    while pos <= endof(str)
        expr, isexpr, pos = find_expr(sourcebuf, str, pos)
        expr == nothing && continue
        push!(exprs,expr)
        push!(isexprs,isexpr)
        this_icxxs = Any[]
        if isexpr
            collect_icxx(expr,this_icxxs)
        end
        push!(icxxs, this_icxxs)
        cxxargs = join([begin
            string("[&](",
                join(["auto __lambdaarg$i" for i = 0:(length(exprs)-1)],','),
                "){ $(str) }")
        end for (x,str,exprs) in this_icxxs]
        ,',')
        if global_scope
            write(sourcebuf,
                isexpr ? string("__julia::call",varnum,"(",cxxargs,")") :
                         string("__julia::var",varnum))
            varnum += 1
        else
            if isexpr
                if isempty(this_icxxs)
                    write(sourcebuf, "jl_apply0(")
                else
                    write(sourcebuf, "jl_calln(")
                end
            end
            write(sourcebuf, string("__juliavar",localvarnum))
            if isexpr
                !isempty(this_icxxs) && write(sourcebuf,',')
                write(sourcebuf,cxxargs)
                write(sourcebuf, ')')
            end
            localvarnum += 1
        end
    end
    if !global_scope
        write(sourcebuf,"\n}")
    end
    startvarnum, sourcebuf, exprs, isexprs, icxxs
end

@generated function lambdacall(CT, l, args...)
    C = instance(CT)
    T = typeForLambda(l)
    ce, rt, pvds = CreateLambdaCallExpr(C, T, args)
    EmitExpr(C,ce,C_NULL,C_NULL,[Ptr{Void},args...],pvds;
        symargs = (:(l.captureData),[:(args[$i]) for i = 1:length(args)]...))
end

function build_icxx_expr(id, exprs, isexprs, icxxs, compiler, impl_func = cxxstr_impl)
    setup = Expr(:block)
    cxxstr = Expr(:call,impl_func,compiler,:(Cxx.SourceBuf{$id}()))
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
            largs = Expr(:tuple)
            if !isempty(icxxs[i])
                substs = Dict{Symbol,Any}()
                for (j,(s,_,ixexprs)) in enumerate(icxxs[i])
                    arg = gensym()
                    push!(largs.args, arg)
                    substs[s] = Expr(:call,Cxx.lambdacall,compiler,arg,[x[1] for x in ixexprs]...)
                end
                substitute_symbols!(e,substs)
            end
            push!(setup.args,Expr(:(=),s,Expr(:->,largs,e)))
            push!(cxxstr.args,s)
        else
            push!(cxxstr.args,:(Cxx.cppconvert($e)))
        end
    end
    push!(setup.args,cxxstr)
    return setup
end

function process_cxx_string(str,global_scope = true,type_name = false,filename=symbol(""),line=1,col=1;
    compiler = :__current_compiler__, tojuliatype = true)
    startvarnum, sourcebuf, exprs, isexprs, icxxs = process_body(str, global_scope, filename, line, col)
    if global_scope
        argsetup = Expr(:block)
        argcleanup = Expr(:block)
        postparse = Expr(:block)
        instance = :( Cxx.instance($compiler) )
        ctx = gensym()
        typeargs = gensym()
        for i in 1:length(exprs)
            expr = exprs[i]
            icxx = icxxs[i]
            if icxx == Any[]
                s = gensym()
                sv = gensym()
                x = :(Cxx.ssv($instance,e,$ctx,$startvarnum,eval(:( ()->($e) )),$sourcebuf))
                if type_name
                  push!(x.args,typeargs)
                end
                push!(argsetup.args,quote
                    ($s, $sv) =
                        let e = $expr
                            $x
                        end
                    end)
                push!(argcleanup.args,:(Cxx.ArgCleanup($instance,$s,$sv)))
            else
                s = gensym()
                # For now we put significant limitations on this. For one, expressions of
                # this kind must return nothing, so we can create the C++ prototype for it
                # without knowing the C++ types it contains. Further, currently we do not allow
                # more (i.e. a julia expression within a C++ expression within a julia expression
                # within a C++ expression)
                push!(argsetup.args,quote
                    $s = Cxx.CreateTemplatedLambdaCall($instance,$ctx,$startvarnum,$(length(icxx)))
                end)
                syms = tuple([gensym() for _ in 1:length(icxx)]...)
                push!(postparse.args,quote
                    Cxx.InstantiateSpecializations($instance,$ctx,$s,
                        $(Expr(:->,length(syms) == 1 ? syms[1] : Expr(:tuple,syms...),expr.args[1])),$syms,$icxx)
                end)
            end
            startvarnum += 1
        end
        parsecode = filename == "" ? :( cxxparse($instance,takebuf_string($sourcebuf),$type_name) ) :
            :( Cxx.ParseVirtual($instance, takebuf_string($sourcebuf),
                $( VirtualFileName(filename) ),
                $( quot(filename) ),
                $( line ),
                $( col ),
                $(type_name) ) )
        x = gensym()
        if type_name
          unshift!(argsetup.args,quote
            $typeargs = Dict{Int64,TypeVar}()
            Cxx.EnterParserScope($instance)
          end)
          push!(postparse.args, quote
            Cxx.ExitParserScope($instance)
          end)
          tojuliatype &&
            push!(postparse.args, quote
                $x = Cxx.juliatype($x, $typeargs)
            end)
        end
        return quote
            let
                jns = cglobal((:julia_namespace,$libcxxffi),Ptr{Void})
                ns = Cxx.createNamespace($instance,"julia")
                $ctx = Cxx.toctx(pcpp"clang::Decl"(ns.ptr))
                unsafe_store!(jns,ns.ptr)
                $argsetup
                $argcleanup
                $x = $parsecode
                $postparse
                unsafe_store!(jns,C_NULL)
                $x
            end
        end
    else
        push!(sourcebuffers,(takebuf_string(sourcebuf),filename,line,col))
        id = length(sourcebuffers)
        build_icxx_expr(id, exprs, isexprs, icxxs, compiler, cxxstr_impl)
    end
end

macro cxx_str(str,args...)
    esc(process_cxx_string(str,true,false,args...))
end

macro cxxt_str(str,args...)
    esc(process_cxx_string(str,true,true,args...))
end

# Not exported
macro ccxxt_str(str,args...)
    esc(process_cxx_string(str,true,true,args...; tojuliatype = false))
end

macro icxx_str(str,args...)
    esc(process_cxx_string(str,false,false,args...))
end

macro icxx_mstr(str,args...)
    esc(process_cxx_string(str,false,false,args...))
end

macro cxx_mstr(str,args...)
    esc(process_cxx_string(str,true,false,args...))
end

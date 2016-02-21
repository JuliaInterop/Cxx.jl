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
            if T <: AbstractFloat
                return getConstantFloat(julia_to_llvm(T),Float64(val))
            elseif T <: Integer
                return getConstantInt(julia_to_llvm(T),UInt64(val))
            elseif T <: Ptr
                int = getConstantInt(julia_to_llvm(UInt64),UInt64(val))
                return getConstantIntToPtr(int, julia_to_llvm(T))
            else
                error("Creating LLVM constants for type `T` not implemented yet")
            end
        elseif sizeof(T) == 0
            return getConstantStruct(getEmptyStructType(),pcpp"llvm::Constant"[])
        else
            vals = [llvmconst(getfield(val,i)) for i = 1:length(fieldnames(T))]
            return getConstantStruct(julia_to_llvm(T),vals)
        end
    end
    error("Cannot turn this julia value (of type `$T`) into a constant")
end

function SetDeclInitializer(C,decl::pcpp"clang::VarDecl",val::pcpp"llvm::Constant")
    ccall((:SetDeclInitializer,libcxxffi),Void,(Ptr{ClangCompiler},Ptr{Void},Ptr{Void}),&C,decl,val)
end

const specTypes = 8
function ssv(C,e::ANY,ctx,varnum,sourcebuf,typeargs=Dict{Void,Void}())
    if isa(e,Type)
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
    AddDeclToDeclCtx(ctx,pcpp"clang::Decl"(convert(Ptr{Void}, sv)))
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
    argts = QualType[ RValueRefernceTo(C,QualType(typeForDecl(T))) for T in TPs ]
    FD = CreateFunctionDecl(C, DC, string("call",callnum) ,makeFunctionType(C,cpptype(C,Void),argts))
    params = pcpp"clang::ParmVarDecl"[
        CreateParmVarDecl(C, argt,string("__juliavar",i)) for (i,argt) in enumerate(argts)]
    SetFDParams(FD,params)
    D = CreateFunctionTemplateDecl(C,DC,Params,FD)
    AddDeclToDeclCtx(DC,pcpp"clang::Decl"(convert(Ptr{Void}, D)))
    D
end

callsymbol(s::Symbol) = s
callsymbol(s::GlobalRef) = s.name
function substitute_lambdacalls!(e::Expr,substs)
    for i in 1:length(e.args)
        if !isa(e.args[i],Expr)
            continue
        end
        arg = e.args[i]
        if isexpr(arg,:call) && length(arg.args) >= 3 &&
            arg.args[1] == Cxx.lambdacall &&
            haskey(substs,callsymbol(arg.args[3]))
            e.args[i] = substs[callsymbol(arg.args[3])]
        else
            e.args[i] = substitute_lambdacalls!(arg, substs)
        end
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
    spec = specialize_template_clang(C, pcpp"clang::ClassTemplateDecl"(convert(Ptr{Void}, lambda_typeD)), [T])
    d = pcpp"clang::Decl"(convert(Ptr{Void}, spec))
    result = pcpp"clang::VarDecl"(convert(Ptr{Void}, _lookup_name(C, "type", toctx(d))))
    SetDeclInitializer(C, result, llvmconst(pointer_from_objref(julia_type)))
end

function InstantiateLambdaType(C)
    D = lookup_name(C,["jl_calln"])
    lambda_typeD = lookup_name(C,["lambda_type"])
    sps = getSpecializations(pcpp"clang::FunctionTemplateDecl"(convert(Ptr{Void},D)))
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

const lambda_roots = Function[]

# TODO: It would be good if this could be invoked as a callback when Clang instantiates
# a template.
function InstantiateSpecializationsForType(C, DC, LambdaT)
    TheClass = Cxx.getAsCXXRecordDecl(Cxx.MappedTypes[LambdaT])
    Method = Cxx.getLambdaCallOperator(TheClass)
    FTD = Cxx.GetDescribedFunctionTemplate(Method)
    if FTD == C_NULL
        return
    end
    sps = getSpecializations(FTD)
    for x in sps
        bodies = Expr[]
        TP = templateParameters(x)
        nargs = getTargsSize(TP)

        # Because CppPtr is now a bitstype
        PVoid = cpptype(C,Int)
        tpvds = pcpp"clang::ParmVarDecl"[]
        specTypes = Type[]

        useBoxed = false
        types = pcpp"clang::Type"[]
        for i = 1:nargs
            T = getTargTypeAtIdx(TP,i-1)
            specT = juliatype(T)
            push!(specTypes, specT <: CxxBuiltinTs ? specT : juliatype(pointerTo(C,T)))
            push!(types, canonicalType(extractTypePtr(T)))
            push!(tpvds, getParmVarDecl(x,i-1))
        end

        # Step 2: Create the instantiated julia function
        F = first(LambdaT.name.mt)
        for pvd in tpvds
            SetDeclUsed(C,pvd)
        end

        linfo = F.func
        ST = Tuple{LambdaT, specTypes...}
        (tree, ty) = Core.Inference.typeinf(linfo,ST,svec())
        T = ty

        if T === Union{}
          T = Void
        end
        if isa(T,Union) || T.abstract
          error("Inferred Union or abstract type $T for expression $F")
        end
        if T !== Void
          error("Currently only `Void` is supported for nested expressions")
        end

        # We can emit a direct llvm-level reference to this
        f = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Any,Bool,Bool), F, ST, false, true))
        @assert f != C_NULL

        # Create a Clang function Decl to represent this julia function
        ExternCDC = CreateLinkageSpec(C, DC, LANG_C)
        argtypes = [xT <: CxxBuiltinTs ? getTargTypeAtIdx(TP,i-1) : PVoid for (i,xT) in enumerate(specTypes)]
        JFD = CreateFunctionDecl(C, ExternCDC, getName(f), makeFunctionType(C, cpptype(C,T), argtypes))

        params = pcpp"clang::ParmVarDecl"[]
        for (i,argt) in enumerate(argtypes)
            param = CreateParmVarDecl(C, argt, string("__juliavar",i))
            push!(params,param)
        end
        SetFDParams(JFD,params)

        # Create the body for the instantiation
        callargs = pcpp"clang::Expr"[]
        for (i,pvd) in enumerate(tpvds)
            e = dre = CreateDeclRefExpr(C,pvd)
            if !(specTypes[i] <: CxxBuiltinTs)
                e = createCast(C,CreateAddrOfExpr(C,dre),PVoid,CK_PointerToIntegral)
            end
            push!(callargs, e)
        end
        JCE = CreateCallExpr(C,CreateFunctionRefExpr(C, JFD), callargs)

        # Now that the specialization has a body, emit it
        SetFDBody(x,CreateReturnStmt(C,JCE))
        EmitTopLevelDecl(C, x)
    end
end

function InstantiateSpecializations(C,DC,D,expr,syms,icxxs)
    sps = getSpecializations(D)
    for x in sps
        bodies = Expr[]
        TP = templateParameters(x)
        nargs = getTargsSize(TP)

        PVoid = cpptype(C,Ptr{Void})
        tpvds = pcpp"clang::ParmVarDecl"[]
        specTypes = Type[]

        useBoxed = false
        types = pcpp"clang::Type"[]
        for i = 1:nargs
            T = getTargTypeAtIdx(TP,i-1)
            @show T
            push!(specTypes, juliatype(pointerTo(C,T)))
            push!(types, canonicalType(extractTypePtr(T)))
            push!(tpvds, getParmVarDecl(x,i-1))
            continue

            # The reason for this split is that the first code is older and
            # more narrow, not being able to handle lambdacalls with captured
            # arguments. However it is currently still more efficient, since
            # the second method relies on generic dispatch. If this limitation
            # is lifted in the future, it would be good to switch everything
            # to the second method.
            if isempty(icxxs[i][3])
              # Find the this lambda's call operator and wrap it using
              # the generic machinery
              ce, rt, pvds = CreateLambdaCallExpr(C, T)

              body = EmitExpr(C,ce,C_NULL,C_NULL,[Ptr{Void}],pvds; symargs = (:($(syms[i])),))
              push!(bodies,body)
            else
              # Use the lambdacall method
              useBoxed = true
              # This is the default representation, so no substitutions needed
              push!(bodies,Expr(:thisisnotavalidexprdontlookatthis))
            end
        end

        # Step 2: Create the instantiated julia function
        F = first(methods(expr))

        # Collect substitutions

        for pvd in tpvds
            SetDeclUsed(C,pvd)
        end

        if !useBoxed
          # Perform type inference
          linfo = F.func
          @show Base.uncompressed_ast(linfo)
          ST = Tuple{typeof(expr), specTypes...}
          (tree, ty) = Core.Inference.typeinf(linfo,ST,svec())
          T = ty

          if T === Union{}
              T = Void
          end
          if isa(T,Union) || T.abstract
              error("Inferred Union or abstract type $T for expression $F")
          end
          if T !== Void
              error("Currently only `Void` is supported for nested expressions")
          end

          # We can emit a direct llvm-level reference to this
          f = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Any,Bool,Bool), F, ST, false, true))
          @assert f != C_NULL

          # Create a Clang function Decl to represent this julia function
          ExternCDC = CreateLinkageSpec(C, DC, LANG_C)
          argtypes = [PVoid for _ = 1:nargs]
          JFD = CreateFunctionDecl(C, ExternCDC, getName(f), makeFunctionType(C, cpptype(C,T), argtypes))

          params = pcpp"clang::ParmVarDecl"[]
          for (i,argt) in enumerate(argtypes)
            param = CreateParmVarDecl(C, argt, string("__juliavar",i))
            push!(params,param)
          end
          SetFDParams(JFD,params)

          # Create the body for the instantiation
          JCE = CreateCallExpr(C,CreateFunctionRefExpr(C, JFD),
                  [ createCast(C,CreateAddrOfExpr(C,CreateDeclRefExpr(C,pvd)),PVoid,CK_BitCast) for pvd in tpvds ])
        else
          @assert false
          # Root the function in the above array. Not that we don't care about
          # that in the other branch of this if statement, because there we
          # generate IR, which never ever goes away
          hasSubstitutions && push!(lambda_roots,F)
          # Forward this to jl_calln
          CFD = pcpp"clang::FunctionTemplateDecl"(convert(Ptr{Void},lookup_name(C,["jl_calln"])))
          forwardD = pcpp"clang::FunctionTemplateDecl"(convert(Ptr{Void},lookup_name(C,["std","forward"])))
          lambda_typeD = pcpp"clang::FunctionTemplateDecl"(convert(Ptr{Void},lookup_name(C,["lambda_type"])))
          FExpr = createCast(C,
            CreateIntegerLiteral(C,
              convert(UInt,pointer_from_objref(F)),cpptype(C,UInt)),
              cpptype(C,Function), CK_IntegralToPointer)
          FD = getOrCreateTemplateSpecialization(C, CFD, types)
          args = [FExpr]
          for (i,D) in enumerate(tpvds)
            createLambdaTypeSpecialization(C, lambda_typeD, QualType(types[i]))
            specializedForward = getOrCreateTemplateSpecialization(C, forwardD, [types[i]])
            forwardCall = CreateCallExpr(C,
              CreateFunctionRefExpr(C, specializedForward),
              [CreateDeclRefExpr(C,D)])
            push!(args, forwardCall)
          end
          JCE = CreateCallExpr(C,CreateFunctionRefExpr(C, FD), args)
        end
        # Now that the specialization has a body, emit it
        SetFDBody(x,CreateReturnStmt(C,JCE))
        EmitTopLevelDecl(C, x)
    end
end

function RealizeTemplates(C,DC,e)
    if haskey(MappedTypes, typeof(e))
        InstantiateSpecializationsForType(C, DC, typeof(e))
    end
end

function ArgCleanup(C,e,sv)
    if isa(sv,pcpp"clang::FunctionDecl")
        tt = Tuple{typeof(e)}
        f = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Any,Bool,Bool), e, tt, false, true))
        @assert f != C_NULL
        ReplaceFunctionForDecl(C,sv,f)
    elseif !isa(e,Type) && !isa(e,TypeVar)
        # Passed as pointer
        if haskey(MappedTypes,typeof(e))
            if sizeof(typeof(e)) == 0
                SetDeclInitializer(C,sv,llvmconst(C_NULL))
            else
                SetDeclInitializer(C,sv,llvmconst(pointer_from_objref(e)))
            end
        else
            SetDeclInitializer(C,sv,llvmconst(e))
        end
    end
end

const sourcebuffers = Array(Tuple{AbstractString,Symbol,Int,Int},0)

immutable SourceBuf{id}; end
sourceid{id}(::Type{SourceBuf{id}}) = id

icxxcounter = 0

function ActOnStartOfFunction(C,D,ScopeIsNull = false)
    pcpp"clang::Decl"(ccall((:ActOnStartOfFunction,libcxxffi),
        Ptr{Void},(Ptr{ClangCompiler},Ptr{Void},Bool),&C,D,ScopeIsNull))
end
function ParseFunctionStatementBody(C,D)
    if ccall((:ParseFunctionStatementBody,libcxxffi),Bool,(Ptr{ClangCompiler},Ptr{Void}),&C,D) == 0
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
EmitTopLevelDecl(C,D::pcpp"clang::FunctionDecl") = EmitTopLevelDecl(C,pcpp"clang::Decl"(convert(Ptr{Void}, D)))

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
    symargs = Expr[]
    # Make a first part about the arguments
    # and replace __juliavar$i by __julia::type$i
    # for all types. Also remember all types and remove them
    # from `args`.
    for (i,arg) in enumerate(args)
        # We passed in an actual julia type
        symarg = :(args[$i])
        if arg <: Type
            body = replace(body,"__juliavar$i","__juliatype$i")
            push!(typeargs,(i,cpptype(C,arg.parameters[1])))
        else
            arg, symarg = cxxtransform(arg,symarg)
            T = cpptype(C,arg)
            (arg <: CppValue) && (T = referenceTo(C,T))
            push!(argtypes,(i,T))
            push!(llvmargs,arg)
            push!(argidxs,i)
            push!(symargs,symarg)
        end
    end

    if filename == symbol("")
        EnterBuffer(C,body)
    else
        EnterVirtualSource(C,body,VirtualFileName(filename))
    end

    local FD
    local dne
    begin
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
            AddDeclToDeclCtx(ctx,pcpp"clang::Decl"(convert(Ptr{Void}, D)))
        end
        SetFDParams(FD,params)
        FD = ActOnStartOfFunction(C,pcpp"clang::Decl"(convert(Ptr{Void}, FD)))
        try
            ParseFunctionStatementBody(C,FD)
        finally
            ActOnFinishNamespaceDef(C,ND)
        end
    end

    # dump(FD)

    EmitTopLevelDecl(C,FD)

    FD, llvmargs, argidxs, symargs
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

    FD, llvmargs, argidxs, symargs = CreateFunctionWithBody(C,buf, args...; filename = filename, line = line, col = col)

    for T in args
        if haskey(MappedTypes, T)
            InstantiateSpecializationsForType(C, toctx(translation_unit(C)), T)
        end
    end

    dne = CreateDeclRefExpr(C,FD)
    argt = tuple(llvmargs...)
    expr = CallDNE(C,dne,argt; argidxs = argidxs, symargs = symargs)
    expr
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
        i += 1
    end
    exprs, takebuf_string(sourcebuf)
end

collect_icxx(compiler, s, icxxs) = s
function collect_icxx(compiler, e::Expr,icxxs)
    if isexpr(e,:macrocall) && e.args[1] == symbol("@icxx_str")
        x = symbol(string("arg",length(icxxs)+1))
        exprs, str = collect_exprs(e.args[2])
        push!(icxxs, (x,str,exprs))
        return Expr(:call, Cxx.lambdacall, compiler, x, [e[1] for e in exprs]...)
    else
        for i in 1:length(e.args)
            e.args[i] = collect_icxx(compiler,e.args[i], icxxs)
        end
    end
    e
end

function process_body(compiler, str, global_scope = true, cxxt = false, filename=symbol(""),line=1,col=1)
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
    if !global_scope && !cxxt
        write(sourcebuf,"{\n")
    end
    if !cxxt && filename != symbol("")
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
        this_icxxs = Any[]
        if isexpr
            collect_icxx(compiler, expr,this_icxxs)
        end
        push!(exprs, isexpr ?
            Expr(:->,Expr(:tuple,map(i->symbol(string("arg",i)),1:length(this_icxxs))...),
                expr.args[1]) : expr)
        push!(isexprs,isexpr)

        push!(icxxs, this_icxxs)
        cxxargs = join([begin
            string("[&](",
                join(["auto __lambdaarg$i" for i = 0:(length(exprs)-1)],','),
                "){ $(str) }")
        end for (x,str,exprs) in this_icxxs]
        ,',')
        if global_scope
            write(sourcebuf, string("__julia::var",varnum))
            varnum += 1
        elseif cxxt
            write(sourcebuf, string("__julia::var",localvarnum))
            localvarnum += 1
        else
            write(sourcebuf, string("__juliavar",localvarnum))
            localvarnum += 1
        end
        if isexpr
            @assert !cxxt
            write(sourcebuf, '(', cxxargs, ')')
        end
    end
    if !cxxt && !global_scope
        write(sourcebuf,"\n}")
    end
    startvarnum, sourcebuf, exprs, isexprs, icxxs
end

@generated function lambdacall(CT, l, args...)
    C = instance(CT)
    if l <: CppPtr
        l = l.parameters[1].parameters[1]
        T = typeForLambda(l)
        ce, rt, pvds = CreateLambdaCallExpr(C, T, args)
        body = EmitExpr(C,ce,C_NULL,C_NULL,[Ptr{Void},args...],pvds;
            symargs = (:(convert(Ptr{Void},l)),[:(args[$i]) for i = 1:length(args)]...))
    else
        T = typeForLambda(l)
        ce, rt, pvds = CreateLambdaCallExpr(C, T, args)
        body = EmitExpr(C,ce,C_NULL,C_NULL,[Ptr{Void},args...],pvds;
            symargs = (:(l.captureData),[:(args[$i]) for i = 1:length(args)]...))
    end
    body
end

immutable CodeLoc{filename,line,col}
end

immutable CxxTypeName{name}
end

@generated function CxxType(CT, t::CxxTypeName, loc, args...)
    C = instance(CT)
    typename = string(t.parameters[1])
    varnum = 0
    mapping = Dict{Int,Any}()
    jns = cglobal((:julia_namespace,libcxxffi),Ptr{Void})
    ns = Cxx.createNamespace(C,"julia")
    ctx = Cxx.toctx(pcpp"clang::Decl"(convert(Ptr{Void},ns)))
    unsafe_store!(jns,convert(Ptr{Void},ns))
    Cxx.EnterParserScope(C)
    for (i,arg) in enumerate(args)
        if arg == TypeVar || arg <: Integer
            name = string("var",varnum)
            typename = replace(typename, string("__julia::var",i), name)
            ActOnTypeParameterParserScope(C,name,varnum)
            mapping[varnum] = :(args[$i])
            varnum += 1
        elseif arg <: Type
            QT = cpptype(C,arg.parameters[1])
            name = string("var",i)
            sv = CreateTypeDefDecl(C,ctx,name,QT)
            AddDeclToDeclCtx(ctx,pcpp"clang::Decl"(convert(Ptr{Void},sv)))
        end
    end
    x = Cxx.ParseVirtual(C, typename,
        VirtualFileName(string(loc.parameters[1])), loc.parameters[1],
        loc.parameters[2], loc.parameters[3], true)
    Cxx.ExitParserScope(C)
    unsafe_store!(jns,C_NULL)
    ret = juliatype(x,true,mapping)
    ret
end

function build_icxx_expr(id, exprs, isexprs, icxxs, compiler, impl_func = cxxstr_impl)
    setup = Expr(:block)
    cxxstr = Expr(:call,impl_func,compiler,:(Cxx.SourceBuf{$id}()))
    for (i,e) in enumerate(exprs)
        #=if isexprs[i]
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
                largs.args = [ s for (s,_,ixexprs) in icxxs[i]]
            end
            push!(setup.args,Expr(:(=),s,Expr(:->,largs,e)))
            push!(cxxstr.args,s)
        else=#
            push!(cxxstr.args,:(Cxx.cppconvert($e)))
        #end
    end
    push!(setup.args,cxxstr)
    return setup
end

function process_cxx_string(str,global_scope = true,type_name = false,filename=symbol(""),line=1,col=1;
    compiler = :__current_compiler__, tojuliatype = true)
    startvarnum, sourcebuf, exprs, isexprs, icxxs =
        process_body(compiler, str, global_scope, !global_scope && type_name, filename, line, col)
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
            s = gensym()
            sv = gensym()
            x = :(Cxx.ssv($instance,e,$ctx,$startvarnum,$sourcebuf))
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
            push!(postparse.args,:(Cxx.RealizeTemplates($instance,$ctx,$s)))
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
                $x = Cxx.juliatype($x, false, $typeargs)
            end)
        end
        return quote
            let
                jns = cglobal((:julia_namespace,$libcxxffi),Ptr{Void})
                ns = Cxx.createNamespace($instance,"julia")
                $ctx = Cxx.toctx(pcpp"clang::Decl"(convert(Ptr{Void},ns)))
                unsafe_store!(jns,convert(Ptr{Void},ns))
                $argsetup
                $argcleanup
                $x = $parsecode
                $postparse
                unsafe_store!(jns,C_NULL)
                $x
            end
        end
    else
        if type_name
            Expr(:call,Cxx.CxxType,:__current_compiler__,
                CxxTypeName{symbol(takebuf_string(sourcebuf))}(),CodeLoc{filename,line,col}(),exprs...)
        else
            push!(sourcebuffers,(takebuf_string(sourcebuf),filename,line,col))
            id = length(sourcebuffers)
            build_icxx_expr(id, exprs, isexprs, icxxs, compiler, cxxstr_impl)
        end
    end
end

macro cxx_str(str,args...)
    esc(process_cxx_string(str,true,false,args...))
end

# Not exported
macro cxxt_str(str,args...)
    esc(process_cxx_string(str,false,true,args...))
end

macro icxx_str(str,args...)
    esc(process_cxx_string(str,false,false,args...))
end

# Not exported
macro gcxxt_str(str,args...)
    esc(process_cxx_string(str,true,true,args...))
end


macro ccxxt_str(str,args...)
    esc(process_cxx_string(str,true,true,args...; tojuliatype = false))
end

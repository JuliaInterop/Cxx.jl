function cpp_ref(expr,nns,isaddrof)
    @assert isa(expr, Symbol)
    nns = Expr(:curly,Tuple,nns.args[2:end]...,quot(expr))
    x = :(Cxx.CppNNS{$nns}())
    ret = esc(Expr(:call, :(Cxx.cxxref), :__current_compiler__, isaddrof ? :(Cxx.CppAddr($x)) : x))
end

function refderefarg(arg)
    if isexpr(arg,:call)
        # is unary *
        if length(arg.args) == 2 && arg.args[1] == :*
            return :( Cxx.CppDeref($(refderefarg(arg.args[2]))) )
        end
    elseif isexpr(arg,:&)
        return :( Cxx.CppAddr($(refderefarg(arg.args[1]))) )
    end
    arg
end

# Builds a call to the cppcall staged functions that represents a
# call to a C++ function.
# Arguments:
#   - cexpr:    The (julia-side) call expression
#   - this:     For a member call the expression corresponding to
#               object of which the function is being called
#   - prefix:   For a call namespaced call, all namespace qualifiers
#
# E.g.:
#   - @cxx foo::bar::baz(a,b,c)
#       - cexpr == :( baz(a,bc) )
#       - this === nothing
#       - prefix == "foo::bar"
#   - @cxx m->DoSomething(a,b,c)
#       - cexpr == :( DoSomething(a,b,c) )
#       - this == :( m )
#       - prefix = ""
#
function build_cpp_call(cexpr, this, nns, isnew = false)
    if !isexpr(cexpr,:call)
        error("Expected a :call not $cexpr")
    end
    targs = Tuple{}

    # Turn prefix and call expression, back into a fully qualified name
    # (and optionally type arguments)
    if isexpr(cexpr.args[1],:curly)
        nns = Expr(:curly,Tuple,nns.args[2:end]...,quot(cexpr.args[1].args[1]))
        targs = map(macroexpand, copy(cexpr.args[1].args[2:end]))
    else
        nns = Expr(:curly,Tuple,nns.args[2:end]...,quot(cexpr.args[1]))
        targs = Tuple{}
    end

    arguments = cexpr.args[2:end]

    # Unary * is treated as a deref
    for (i, arg) in enumerate(arguments)
        arguments[i] = refderefarg(arg)
    end

    # Add `this` as the first argument
    this !== nothing && unshift!(arguments, this)

    e = curly = :( Cxx.CppNNS{$nns} )

    @assert isa(targs,Type)
    # Add templating
    if targs != Tuple{}
        e = :( Cxx.CppTemplate{$curly,$targs} )
    end

    # The actual call to the staged function
    ret = Expr(:call, isnew ?
        :(Cxx.cxxnewcall) : this === nothing ? :(Cxx.cppcall) : :(Cxx.cppcall_member),
        :__current_compiler__
    )
    push!(ret.args,:($e()))
    append!(ret.args,arguments)
    esc(ret)
end

function build_cpp_ref(member, this, isaddrof)
    @assert isa(member,Symbol)
    x = :(Cxx.CppExpr{$(quot(Symbol(member))),()}())
    ret = esc(Expr(:call, :(Cxx.cxxmemref), :__current_compiler__, isaddrof ? :(Cxx.CppAddr($x)) : x, this))
end

function to_prefix(expr, isaddrof=false)
    if isa(expr,Symbol)
        return (Expr(:curly,Tuple,quot(expr)), isaddrof)
    elseif isa(expr, Bool)
        return (Expr(:curly,Tuple,expr),isaddrof)
    elseif isexpr(expr,:(::))
        nns1, isaddrof = to_prefix(expr.args[1],isaddrof)
        nns2, _ = to_prefix(expr.args[2],isaddrof)
        return (Expr(:curly,Tuple,nns1.args[2:end]...,nns2.args[2:end]...), isaddrof)
    elseif isexpr(expr,:&)
        return to_prefix(expr.args[1],true)
    elseif isexpr(expr,:$)
        return (Expr(:curly,Tuple,expr.args[1],),isaddrof)
    elseif isexpr(expr,:curly)
        nns, isaddrof = to_prefix(expr.args[1],isaddrof)
        tup = Expr(:curly,Tuple)
        for i = 2:length(expr.args)
            nns2, isaddrof2 = to_prefix(expr.args[i],false)
            @assert !isaddrof2
            isnns = length(nns2.args) > 2 || isa(nns2.args[2],Expr)
            push!(tup.args, isnns ? :(Cxx.CppNNS{$nns2}) : nns2.args[2])
        end
        # Expr(:curly,Tuple, ... )
        @assert length(nns.args) == 2
        @assert isexpr(nns.args[2],:quote)

        return (Expr(:curly,Tuple,:(Cxx.CppTemplate{$(nns.args[2]),$tup}),),isaddrof)
    end
    error("Invalid NNS $expr")
end

function cpps_impl(expr,nns=Expr(:curly,Tuple),isaddrof=false,isderef=false,isnew=false)
    if isa(expr,Symbol)
        @assert !isnew
        return cpp_ref(expr,nns,isaddrof)
    elseif expr.head == :(->)
        @assert !isnew
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
            return build_cpp_call(b,a,nns)
        else
            if isexpr(a,:&)
                a = a.args[1]
                isaddrof = true
            end
            return build_cpp_ref(b,a,isaddrof)
        end
    elseif isexpr(expr,:(=))
        @assert !isnew
        error("Unimplemented")
    elseif isexpr(expr,:(::))
        nns2, isaddrof = to_prefix(expr.args[1])
        return cpps_impl(expr.args[2],Expr(:curly,Tuple,nns.args[2:end]...,nns2.args[2:end]...),
            isaddrof,isderef,isnew)
    elseif isexpr(expr,:&)
        return cpps_impl(expr.args[1],nns,true,isderef,isnew)
    elseif isexpr(expr,:call)
        if expr.args[1] == :* && length(expr.args) == 2
            return cpps_impl(expr.args[2],nns,isaddrof,true,isnew)
        end
        return build_cpp_call(expr,nothing,nns,isnew)
    end
    error("Unrecognized CPP Expression ",expr," (",expr.head,")")
end

macro cxx(expr)
    cpps_impl(expr)
end

macro cxxnew(expr)
    cpps_impl(expr, Expr(:curly,Tuple), false, false, true)
end

function extract_params(C,FD)
    @assert FD != C_NULL
    params = Pair{Symbol,DataType}[]
    CxxMD = dcastCXXMethodDecl(pcpp"clang::Decl"(convert(Ptr{Void},FD)))
    if CxxMD != C_NULL
        RD = getParent(CxxMD)
        T = juliatype(pointerTo(C, QualType(typeForDecl(RD))))
        push!(params,:this => T)
    end
    for i = 1:Cxx.getNumParams(FD)
        PV = Cxx.getParmVarDecl(FD,i-1)
        QT = Cxx.getOriginalType(PV)
        T = juliatype(QT)
        if T <: CppValue
            # Want the sized version for specialization
            T = T{cxxsizeof(C,QT) % Int64}
        end
        name = getName(PV)
        push!(params,Symbol(name) => T)
    end
    params
end

function DeclToJuliaPrototype(C,FD,f)
    Expr(:call,f,map(x->Expr(:(::),x[1],x[2]),extract_params(C,FD))...)
end

function get_llvmf_for_FD(C,jf,FD)
    TT = Tuple{typeof(jf), map(x->x[2],extract_params(C,FD))...}
    needsboxed = Bool[!isbits(x) for x in TT.parameters]
    specsig = length(needsboxed) == 0 || !reduce(&,needsboxed)
    f = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Bool,Bool), TT, false,true))
    @assert f != C_NULL
    needsboxed, specsig, Tuple{TT.parameters[2:end]...}, f
end

macro cxxm(str,expr)
    f = gensym()
    FD = gensym()
    RT = gensym()
    esc(quote
        Cxx.EnterBuffer(Cxx.instance(__current_compiler__),$str)
        $FD = pcpp"clang::FunctionDecl"(convert(Ptr{Void},Cxx.ParseDeclaration(Cxx.instance(__current_compiler__))))
        if $FD == C_NULL
            error("Failed to obtain declarator (see Clang Errors)")
        end
        $RT = Cxx.juliatype(Cxx.getReturnType($FD))
        e = Expr(:function,Cxx.DeclToJuliaPrototype(Cxx.instance(__current_compiler__),$FD,$(quot(f))),
            Expr(:(::),Expr(:call,:convert,$RT,$(quot(expr))),$RT))
        eval(e)
        NeedsBoxed, specsig, TT, llvmf = Cxx.get_llvmf_for_FD(Cxx.instance(__current_compiler__),$f,$FD)
        Cxx.ReplaceFunctionForDecl(Cxx.instance(__current_compiler__),
            $FD,llvmf,
            DoInline = false, specsig = specsig, NeedsBoxed = NeedsBoxed, jts = Any[TT.parameters...])
    end)
end

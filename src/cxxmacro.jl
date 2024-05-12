function cpp_ref(expr,nns,isaddrof)
    @assert isa(expr, Symbol)
    nns = Expr(:curly,Tuple,nns.args[2:end]...,quot(expr))
    x = :($(CppNNS){$nns}())
    ret = esc(Expr(:call, cxxref, :__current_compiler__, isaddrof ? :($(CppAddr)($x)) : x))
end

function refderefarg(arg)
    if isexpr(arg,:call)
        # is unary *
        if length(arg.args) == 2 && arg.args[1] == :*
            return :( $(CppDeref)($(refderefarg(arg.args[2]))) )
        end
    elseif isexpr(arg,:&)
        return :( $(CppAddr)($(refderefarg(arg.args[1]))) )
    end
    arg
end

function add_to_nns_list!(nns, expr)
    if isexpr(expr, Symbol("::"))
        add_to_nns_list!(nns, expr.args[1])
        push!(nns, expr.args[2])
    else
        push!(nns, expr)
    end
end

function expr_to_nns(x)
  args = Any[]
  add_to_nns_list!(args, x)
  :( $(CppNNS){$(Expr(:curly, Tuple, map(quot, args)...))} )
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
function build_cpp_call(mod, cexpr, this, nns, isnew = false)
    if !isexpr(cexpr,:call)
        error("Expected a :call not $cexpr")
    end
    targs = Tuple{}

    # Turn prefix and call expression, back into a fully qualified name
    # (and optionally type arguments)
    if isexpr(cexpr.args[1],:curly)
        nns = Expr(:curly,Tuple,nns.args[2:end]...,quot(cexpr.args[1].args[1]))
        targs = Expr(:curly, Tuple, map(expr_to_nns, map(
            x->macroexpand(mod, x),
            copy(cexpr.args[1].args[2:end])))...)
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
    this !== nothing && pushfirst!(arguments, this)

    e = curly = :( $(CppNNS){$nns} )

    # Add templating
    if targs != Tuple{}
        e = :( $(CppTemplate){$curly,$targs} )
    end

    # The actual call to the staged function
    ret = Expr(:call, isnew ?
        cxxnewcall : this === nothing ? cppcall : cppcall_member,
        :__current_compiler__
    )
    push!(ret.args,:($e()))
    append!(ret.args,arguments)
    esc(ret)
end

function build_cpp_ref(member, this, isaddrof)
    @assert isa(member,Symbol)
    x = :($(CppExpr){$(quot(Symbol(member))),()}())
    ret = esc(Expr(:call, cxxmemref, :__current_compiler__, isaddrof ? :($(CppAddr)($x)) : x, this))
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
            push!(tup.args, isnns ? :($(CppNNS){$nns2}) : nns2.args[2])
        end
        # Expr(:curly,Tuple, ... )
        @assert length(nns.args) == 2
        @assert isexpr(nns.args[2],:quote)

        return (Expr(:curly,Tuple,:($(CppTemplate){$(nns.args[2]),$tup}),),isaddrof)
    end
    error("Invalid NNS $expr")
end

function cpps_impl(mod, expr,nns=Expr(:curly,Tuple),isaddrof=false,isderef=false,isnew=false)
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
            if !(isexpr(b,:call) || isexpr(b,:line) || isa(b,Symbol) || isa(b, LineNumberNode))
                error("Malformed C++ call. Expected member not $b")
            end
            i += 1
        end
        if isexpr(b,:call)
            return build_cpp_call(mod, b,a,nns)
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
        return cpps_impl(mod, expr.args[2],Expr(:curly,Tuple,nns.args[2:end]...,nns2.args[2:end]...),
            isaddrof,isderef,isnew)
    elseif isexpr(expr,:&)
        return cpps_impl(mod, expr.args[1],nns,true,isderef,isnew)
    elseif isexpr(expr,:call)
        if expr.args[1] == :* && length(expr.args) == 2
            return cpps_impl(mod, expr.args[2],nns,isaddrof,true,isnew)
        end
        return build_cpp_call(mod, expr,nothing,nns,isnew)
    end
    error("Unrecognized CPP Expression ",expr," (",expr.head,")")
end

"""
    @cxx expr

Evaluate the given expression as C++ code, punning on Julia syntax to
avoid needing to wrap the C++ code in a string, as in `cxx""`. The
three basic features provided by `@cxx` are:

* Static function calls: `@cxx mynamespace::func(args...)`
* Member calls: `@cxx m->foo(args...)`, where `m` is a `CppPtr`, `CppRef`,
  or `CppValue`
* Value references: `@cxx foo`

Unary `*` inside a call, e.g. `@cxx foo(*(a))`, is treated as a dereference
of `a` on the C++ side. Further, prefixing any value by `&` takes the
address of the given value.

!!! note
    In `@cxx foo(*(a))`, the parentheses around `a` are necessary since
    Julia syntax does not allow `*` in the unary operator position
    otherwise.
"""
macro cxx(expr)
    cpps_impl(__module__, expr)
end

"""
    @cxxnew expr

Create a new instance of a C++ class.
"""
macro cxxnew(expr)
    cpps_impl(__module__, expr,
        Expr(:curly,Tuple), false, false, true)
end

function extract_params(C,FD)
    @assert FD != C_NULL
    params = Pair{Symbol,DataType}[]
    CxxMD = dcastCXXMethodDecl(pcpp"clang::Decl"(convert(Ptr{Cvoid},FD)))
    if CxxMD != C_NULL
        RD = getParent(CxxMD)
        T = juliatype(pointerTo(C, QualType(typeForDecl(RD))))
        push!(params,:this => T)
    end
    for i = 1:getNumParams(FD)
        PV = getParmVarDecl(FD,i-1)
        QT = getOriginalType(PV)
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
    needsboxed = Bool[!isbitstype(x) || ismutable(x) for x in TT.parameters]
    specsig = length(needsboxed) == 0 || !reduce(&,needsboxed)
    f = get_llvmf_decl(TT)
    @assert f != C_NULL
    needsboxed[2:end], specsig, Tuple{TT.parameters[2:end]...}, f
end

macro cxxm(str,expr)
    f = gensym()
    FD = gensym()
    RT = gensym()
    esc(quote
        $(EnterBuffer)(Cxx.instance(__current_compiler__),$str)
        $FD = Cxx.@pcpp_str("clang::FunctionDecl")(convert(Ptr{Cvoid},$(ParseDeclaration)(Cxx.instance(__current_compiler__))))
        if $FD == C_NULL
            error("Failed to obtain declarator (see Clang Errors)")
        end
        $RT = $(juliatype)($(getReturnType)($FD))
        e = Expr(:function,$(DeclToJuliaPrototype)(Cxx.instance(__current_compiler__),$FD,$(quot(f))),
            Expr(:(::),Expr(:call,:convert,$RT,$(quot(expr))),$RT))
        eval(e)
        NeedsBoxed, specsig, TT, llvmf = $(get_llvmf_for_FD)(Cxx.instance(__current_compiler__),$f,$FD)
        $(ReplaceFunctionForDecl)(Cxx.instance(__current_compiler__),
            $FD,llvmf,
            DoInline = false, specsig = specsig, NeedsBoxed = NeedsBoxed,
            retty = $RT, jts = Any[TT.parameters...])
    end)
end

using Base.Meta

for binop in keys(cxx_binops)
    @eval (Base.$binop)(x::Union{CppValue,CppRef},y::Union{CppValue,CppRef}) = @cxx ($binop)(x,y)
end

macro list(t)
    q = quote
        Base.start(it::$t) = 0
        Base.next(it::$t,i) = (it[i], i+1)
        Base.done(it::$t,i) = i >= length(it)
    end
    if isexpr(t,:macrocall)
        if t.args[1] == Symbol("@pcpp_str")
            append!(q.args,(quote
                Base.getindex(it::$t,i) = icxx"(*$(it))[$i];"
                Base.length(it::$t) = icxx"$(it)->size();"
            end).args)
        elseif t.args[1] == Symbol("@vcpp_str")
            append!(q.args,(quote
                Base.getindex(it::$t,i) = icxx"$(it)[$i];"
                Base.length(it::$t) = icxx"$(it).size();"
            end).args)
        end
    end
    esc(q)
end

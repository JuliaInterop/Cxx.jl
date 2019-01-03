Base.unsafe_string(str::vcpp"llvm::StringRef") = unsafe_string(icxx"$str.data();",icxx"$str.size();")
typename(QT) = CxxCore.getTypeNameAsString(QT)
function typename(::Type{T}) where T<:CxxQualType
    C = Cxx.instance(Cxx.__default_compiler__)
    QT = cpptype(C,T)
    typename(QT)
end
@generated function Base.show(io::IO,x::Union{CppValue,CppRef})
    C = Cxx.instance(Cxx.__default_compiler__)
    QT = try
        cpptype(C,x)
    catch err
        (isa(err, ErrorException) && occursin("Could not find", err.msg)) || rethrow(err)
        return :( Base.show_datatype(io, typeof(x)); println(io,"(<not found in compilation unit>)") )
    end
    name = typename(QT)
    ret = Expr(:block)
    push!(ret.args,:(print(io,"(",$name,") ")))
    RD = CxxCore.getAsCXXRecordDecl(x <: CppValue ? QT : CxxCore.getPointeeType(QT))
    if RD == C_NULL && x <: CppRef
        push!(ret.args,:(print(io,unsafe_load(x))))
    else
	    push!(ret.args,:(println(io,"{")))
        @assert RD != C_NULL
        icxx"""
        for (auto field : $RD->fields()) {
            if (field->getAccess() != clang::AS_public)
                continue;
            $:(begin
                fieldname = unsafe_string(icxx"return field->getName();")
                showexpr = Expr(:macrocall,Symbol("@icxx_str"),nothing,"
                    auto &r = \$x.$fieldname;
                    return r;
                ")
                push!(ret.args, :(print(io," .",$fieldname," = "); show(io,$showexpr); println(io)) )
                nothing
            end);
        }
        """
        push!(ret.args,:(println(io,"}")))
    end
    ret
end
@generated function Base.show(io::IO, x::CppPtr)
    C = Cxx.instance(Cxx.__default_compiler__)
    QT = try
        cpptype(C,x)
    catch err
        (isa(err, ErrorException) && occursin("Could not find", err.msg)) || rethrow(err)
        return :( Base.show_datatype(io, typeof(x)); println(io," @0x", string(convert(UInt,convert(Ptr{Nothing},x)), base=16, pad=Sys.WORD_SIZE>>2)) )
    end
    name = typename(QT)
    :( println(io,"(",$name,") @0x", string(convert(UInt,convert(Ptr{Nothing},x)), base=16, pad=Sys.WORD_SIZE>>2) ))
end

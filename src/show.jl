Base.bytestring(str::vcpp"llvm::StringRef") = Cxx.unsafe_string(icxx"$str.data();",icxx"$str.size();")
typename(QT) = Cxx.getTypeNameAsString(QT)
function typename{T<:Cxx.CxxQualType}(::Type{T})
    C = Cxx.instance(Cxx.__default_compiler__)
    QT = Cxx.cpptype(C,T)
    typename(QT)
end
@generated function Base.show(io::IO,x::Union{Cxx.CppValue,Cxx.CppRef})
    C = Cxx.instance(Cxx.__default_compiler__)
    QT = try
        Cxx.cpptype(C,x)
    catch err
        (isa(err, ErrorException) && contains(err.msg, "Could not find")) || rethrow(err)
        return :( Base.show_datatype(io, typeof(x)); println(io,"(<not found in compilation unit>)") )
    end
    name = typename(QT)
    ret = Expr(:block)
    push!(ret.args,:(print(io,"(",$name,") ")))
    RD = Cxx.getAsCXXRecordDecl(x <: CppValue ? QT : Cxx.getPointeeType(QT))
    if RD == C_NULL && x <: Cxx.CppRef
        push!(ret.args,:(print(io,unsafe_load(x))))
    else
	    push!(ret.args,:(println(io,"{")))
        @assert RD != C_NULL
        icxx"""
        for (auto field : $RD->fields()) {
            if (field->getAccess() != clang::AS_public)
                continue;
            $:(begin
                fieldname = bytestring(icxx"return field->getName();")
                showexpr = Expr(:macrocall,Symbol("@icxx_str"),"
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
@generated function Base.show(io::IO, x::Cxx.CppPtr)
    C = Cxx.instance(Cxx.__default_compiler__)
    QT = try
        Cxx.cpptype(C,x)
    catch err
        (isa(err, ErrorException) && contains(err.msg, "Could not find")) || rethrow(err)
        return :( Base.show_datatype(io, typeof(x)); println(io," @0x", hex(convert(UInt,convert(Ptr{Void},x)),Sys.WORD_SIZE>>2)) )
    end
    name = typename(QT)
    :( println(io,"(",$name,") @0x", hex(convert(UInt,convert(Ptr{Void},x)),Sys.WORD_SIZE>>2) ))
end

Base.bytestring(str::vcpp"llvm::StringRef") = bytestring(icxx"$str.data();",icxx"$str.size();")
function typename(QT)
    bytestring(icxx"""
      const clang::LangOptions LO;
      const clang::PrintingPolicy PP(LO);
      $QT.getAsString(PP);
    """)
end
function typename{T<:Cxx.CxxQualType}(::Type{T})
    C = Cxx.instance(Cxx.__default_compiler__)
    QT = Cxx.cpptype(C,T)
    typename(QT)
end
@generated function Base.show(io::IO,x::Union{Cxx.CppValue,Cxx.CppRef})
    C = Cxx.instance(Cxx.__default_compiler__)
    QT = Cxx.cpptype(C,x)
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
                showexpr = Expr(:macrocall,symbol("@icxx_str"),"
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
    QT = Cxx.cpptype(C,x)
    name = typename(QT)
    :( println(io,"(",$name,") @0x", hex(convert(UInt,convert(Ptr{Void},x)),Base.WORD_SIZE>>2) ))
end

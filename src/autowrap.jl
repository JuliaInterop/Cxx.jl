using Base.Meta

for binop in keys(cxx_binops)
    @eval Base.($(quot(binop)))(x::Union(CppValue,CppRef),y::Union(CppValue,CppRef)) = @cxx ($binop)(x,y)
end

import Base: bytestring

cxxparse("#include <string>")

const StdString = cxxt"std::string"

bytestring(str::StdString) = bytestring((@cxx str->data()),@cxx str->size())


import Base: showerror
for T in Cxx.CxxBuiltinTypes.types
    @eval @exception function showerror(io::IO, e::$(T.parameters[1]))
        print(io, e)
    end
end

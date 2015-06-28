import Base: bytestring

cxxparse("#include <string>")

const StdString = cxxt"std::string"

bytestring(str::StdString) = bytestring((@cxx str->data()),@cxx str->size())

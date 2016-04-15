using Cxx
using Graphs
using GraphViz

import Base: start, next, done
import Graphs: is_directed, num_vertices, vertices,
    implements_vertex_list, implements_vertex_map,
    implements_adjacency_list, out_neighbors,
    vertex_index

include(Pkg.dir("Cxx","test","llvmincludes.jl"))

immutable LLVMGraph{GraphType,NodeType} <: AbstractGraph{NodeType,Edge{NodeType}}
    g::GraphType
end

function LLVMGraph{GraphType}(g::GraphType)
    LLVMGraph{GraphType,Cxx.pcpp(@cxx llvm::GraphTraits{$(GraphType)}::NodeType)}(g)
end

is_directed(g::LLVMGraph) = true
println(:(@cxx GraphTraits{$(Expr(:$,:GraphType))}::size(g.g)))
println(macroexpand(:(@cxx GraphTraits{$(Expr(:$,:GraphType))}::size(g.g))))
num_vertices{GraphType}(g::LLVMGraph{GraphType}) = @cxx llvm::GraphTraits{$GraphType}::size(g.g)
implements_vertex_list(::LLVMGraph) = true
implements_vertex_map(::LLVMGraph) = true
implements_adjacency_list(::LLVMGraph) = true

immutable NodeIterator{GT}
    G::GT
end

iterator_type{GraphType}(::Type{NodeIterator{GraphType}}) = @cxx llvm::GraphTraits{$(GraphType)}::nodes_iterator

start{GraphType}(I::NodeIterator{GraphType}) =
    @cxx llvm::GraphTraits{$GraphType}::nodes_begin(I.G)

function next{GraphType}(I::NodeIterator{GraphType},s)
    @assert isa(s, iterator_type(typeof(I)))
    v = icxx"&*$s;"
    icxx"(void)++$s;"
    (v,s)
end

done{GraphType}(I::NodeIterator{GraphType},s) =
    icxx"$s == llvm::GraphTraits<$GraphType>::nodes_end($(I.G));"

vertices{GraphType,NodeType}(g::LLVMGraph{GraphType,NodeType}) =
    NodeIterator{GraphType}(g.g)

immutable EdgeIterator{GT,NT}
    N::NT
end

iterator_type{GT,NT}(::Type{EdgeIterator{GT,NT}}) = @cxx llvm::GraphTraits{$(GT)}::ChildIteratorType

start{GT,NT}(I::EdgeIterator{GT,NT}) =
    @cxx llvm::GraphTraits{$GT}::child_begin(I.N)

function next{GT,NT}(I::EdgeIterator{GT,NT},s)
    @assert isa(s, iterator_type(typeof(I)))
    v = icxx"*$s;"
    icxx"(void)++$s;"
    (v,s)
end

done{GT,NT}(I::EdgeIterator{GT,NT},s) =
    icxx"$s == llvm::GraphTraits<$GT>::child_end($(I.N));"

out_neighbors{GT,NT}(v::NT,g::LLVMGraph{GT,NT}) =
    EdgeIterator{GT,NT}(v)

vertex_index(v,g) = reinterpret(UInt64, v.ptr)

buf = IOBuffer()

code_llvmf(f,t::Tuple{Vararg{Type}}) = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Void}, (Any,Bool,Bool), Tuple{t...}, false, false))
function code_graph(f,args)
    v = @cxx std::string()
    os = @cxx llvm::raw_string_ostream(v)
    graphf = code_llvmf(f,args)
    @cxx llvm::WriteGraph(os,graphf)
    @cxx os->flush()
    bytestring((@cxx v->data()), (@cxx v->length()))
end

gt = code_graph(factorize,(typeof(rand(4,4)),))
lf = code_llvmf(factorize,(typeof(rand(4,4)),))
g = LLVMGraph(lf)
to_dot(g,buf)
display(GraphViz.Graph(takebuf_string(buf)))

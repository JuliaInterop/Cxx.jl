using Cxx
using Graphs
using GraphViz

import Base: start, next, done
import Graphs: is_directed, num_vertices, vertices,
    implements_vertex_list, implements_vertex_map,
    implements_adjacency_list, out_neighbors,
    vertex_index

include(Pkg.dir("Cxx","test","llvmincludes.jl"))

struct LLVMGraph{GraphType,NodeType} <: AbstractGraph{NodeType,Edge{NodeType}}
    g::GraphType
end

function LLVMGraph(g::GraphType) where GraphType
    LLVMGraph{GraphType,Cxx.pcpp(@cxx llvm::GraphTraits{$(GraphType)}::NodeType)}(g)
end

is_directed(g::LLVMGraph) = true
println(:(@cxx GraphTraits{$(Expr(:$,:GraphType))}::size(g.g)))
println(macroexpand(:(@cxx GraphTraits{$(Expr(:$,:GraphType))}::size(g.g))))
num_vertices(g::LLVMGraph{GraphType}) where {GraphType} = @cxx llvm::GraphTraits{$GraphType}::size(g.g)
implements_vertex_list(::LLVMGraph) = true
implements_vertex_map(::LLVMGraph) = true
implements_adjacency_list(::LLVMGraph) = true

struct NodeIterator{GT}
    G::GT
end

iterator_type(::Type{NodeIterator{GraphType}}) where {GraphType} = @cxx llvm::GraphTraits{$(GraphType)}::nodes_iterator

start(I::NodeIterator{GraphType}) where {GraphType} =
    @cxx llvm::GraphTraits{$GraphType}::nodes_begin(I.G)

function next(I::NodeIterator{GraphType},s) where GraphType
    @assert isa(s, iterator_type(typeof(I)))
    v = icxx"&*$s;"
    icxx"(void)++$s;"
    (v,s)
end

done(I::NodeIterator{GraphType},s) where {GraphType} =
    icxx"$s == llvm::GraphTraits<$GraphType>::nodes_end($(I.G));"

vertices(g::LLVMGraph{GraphType,NodeType}) where {GraphType,NodeType} =
    NodeIterator{GraphType}(g.g)

struct EdgeIterator{GT,NT}
    N::NT
end

iterator_type(::Type{EdgeIterator{GT,NT}}) where {GT,NT} = @cxx llvm::GraphTraits{$(GT)}::ChildIteratorType

start(I::EdgeIterator{GT,NT}) where {GT,NT} =
    @cxx llvm::GraphTraits{$GT}::child_begin(I.N)

function next(I::EdgeIterator{GT,NT},s) where {GT,NT}
    @assert isa(s, iterator_type(typeof(I)))
    v = icxx"*$s;"
    icxx"(void)++$s;"
    (v,s)
end

done(I::EdgeIterator{GT,NT},s) where {GT,NT} =
    icxx"$s == llvm::GraphTraits<$GT>::child_end($(I.N));"

out_neighbors(v::NT,g::LLVMGraph{GT,NT}) where {GT,NT} =
    EdgeIterator{GT,NT}(v)

vertex_index(v,g) = reinterpret(UInt64, v.ptr)

buf = IOBuffer()

code_llvmf(f,t::Tuple{Vararg{Type}}) = pcpp"llvm::Function"(ccall(:jl_get_llvmf, Ptr{Cvoid}, (Any,Bool,Bool), Tuple{t...}, false, false))
function code_graph(f,args)
    v = @cxx std::string()
    os = @cxx llvm::raw_string_ostream(v)
    graphf = code_llvmf(f,args)
    @cxx llvm::WriteGraph(os,graphf)
    @cxx os->flush()
    String((@cxx v->data()), (@cxx v->length()))
end

gt = code_graph(factorize,(typeof(rand(4,4)),))
lf = code_llvmf(factorize,(typeof(rand(4,4)),))
g = LLVMGraph(lf)
to_dot(g,buf)
display(GraphViz.Graph(takebuf_string(buf)))

struct CxxCompiler
    irgen::IncrementalIRGenerator
    lookup::DeclFinder
end
CxxCompiler(irgen::IncrementalIRGenerator) = CxxCompiler(irgen, DeclFinder(get_instance(irgen)))

function CxxCompiler(src::String)
    irgen = IncrementalIRGenerator(src, get_compiler_args(; version=v"7.1.0"))
    return CxxCompiler(irgen)
end

const ACTIVE_INSTANCES = CxxCompiler[]

struct CxxInstance{N} end

"""
    __CURRENT_COMPILER__
An instance of the Clang compiler current in use.
"""
const __CURRENT_COMPILER__ = CxxInstance{1}()
const __DEFAULT_COMPILER__ = __CURRENT_COMPILER__

instance(::CxxInstance{N}) where {N} = ACTIVE_INSTANCES[N]
instance(::Type{CxxInstance{N}}) where {N} = ACTIVE_INSTANCES[N]

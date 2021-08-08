struct CxxCompiler
    irgen::IncrementalIRGenerator
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
instance(x::ClangCompiler) = x

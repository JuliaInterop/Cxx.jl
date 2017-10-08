export __current_compiler__

struct ClangCompiler
    shadow::pcpp"llvm::Module"
    CI::pcpp"clang::CompilerInstance"
    CGM::pcpp"clang::CodeGen::CodeGenModule"
    CGF::pcpp"clang::CodeGen::CodeGenFunction"
    Parser::pcpp"clang::Parser"
    JCodeGen::pcpp"JuliaCodeGenerator"
    PCHGenerator::pcpp"clang::PCHGenerator"
end
@assert Base.isbits(ClangCompiler)

active_instances = ClangCompiler[]
destructs = Dict{ClangCompiler,Function}()

function get_destruct_for_instance(C)
    if !haskey(destructs, C)
        idx = findfirst(active_instances, C)
        destructs[C] = function destruct_C(x)
            destruct(CxxInstance{idx}(), x)
        end
    end
    destructs[C]
end


struct CxxInstance{n}; end

const __current_compiler__ = CxxInstance{1}()
const __default_compiler__ = __current_compiler__

instance(::CxxInstance{n}) where {n} = active_instances[n]
instance(::Type{CxxInstance{n}}) where {n} = active_instances[n]
instance(C::ClangCompiler) = C

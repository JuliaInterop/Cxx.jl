export __current_compiler__

immutable ClangCompiler
    shadow::pcpp"llvm::Module"
    CI::pcpp"clang::CompilerInstance"
    CGM::pcpp"clang::CodeGen::CodeGenModule"
    CGF::pcpp"clang::CodeGen::CodeGenFunction"
    Parser::pcpp"clang::Parser"
    JCodeGen::pcpp"JuliaCodeGenerator"
    PCHGenerator::pcpp"clang::PCHGenerator"
end

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


immutable CxxInstance{n}; end

const __current_compiler__ = CxxInstance{1}()
const __default_compiler__ = __current_compiler__

instance{n}(::CxxInstance{n}) = active_instances[n]
instance{n}(::Type{CxxInstance{n}}) = active_instances[n]
instance(C::ClangCompiler) = C

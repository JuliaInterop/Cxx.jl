export __current_compiler__

immutable ClangCompiler
    shadow::pcpp"llvm::Module"
    CI::pcpp"clang::CompilerInstance"
    CGM::pcpp"clang::CodeGenModule"
    CGF::pcpp"clang::CodeGenFunction"
    Parser::pcpp"clang::Parser"
    JCodeGen::pcpp"JuliaCodeGenerator"
end

active_instances = ClangCompiler[]


immutable CxxInstance{n}; end

const __current_compiler__ = CxxInstance{1}()
const __default_compiler__ = __current_compiler__

instance{n}(::CxxInstance{n}) = active_instances[n]
instance{n}(::Type{CxxInstance{n}}) = active_instances[n]

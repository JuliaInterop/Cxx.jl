import Base: LineEdit, REPL
using Cxx

# Some of this code is derived from cling.
# Copyright (c) 2007-2014 by the Authors.
# All rights reserved.
#
# LLVM/Clang/Cling LICENSE text.
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal with
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do
# so, subject to the following conditions:
#
#     * Redistributions of source code must retain the above copyright notice,
#       this list of conditions and the following disclaimers.
#
#     * Redistributions in binary form must reproduce the above copyright notice,
#       this list of conditions and the following disclaimers in the
#       documentation and/or other materials provided with the distribution.
#
#     * Neither the names of the LLVM Team, University of Illinois at
#       Urbana-Champaign, nor the names of its contributors may be used to
#       endorse or promote products derived from this Software without specific
#       prior written permission.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
# FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
# CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS WITH THE
# SOFTWARE.
#
# Cxx.jl itself is provided under the MIT licenses (see the LIECENSE file for details)
#

#
# The Cxx REPL implmenetation can theoretically make use of two separate compiler instances.
# The first (which uses the Cxx default instance) is used to interface with Clang itself. The
# second (potentially different) instance is the one actually parsing and compiling the C++
# code.
#

let __current_compiler__ = Cxx.__default_compiler__

# Load Clang Headers

    addHeaderDir(joinpath(JULIA_HOME,"../include"))

    cxx"""
    #define __STDC_LIMIT_MACROS
    #define __STDC_CONSTANT_MACROS
    // Need to use TentativeParsingAction which is private
    #define private public
    #include "clang/Parse/Parser.h"
    #undef private
    #include "clang/Frontend/CompilerInstance.h"
    """

    cxx"""
    // From bootstrap.cpp
    extern "C" {
        struct CxxInstance;
        extern void EnterSourceFile(CxxInstance *Cxx, char *data, size_t length);
    }
    """

    parser(C) = pcpp"clang::Parser"(ccall((:clang_parser,Cxx.libcxxffi),Ptr{Void},(Ptr{Cxx.ClangCompiler},),&C))
    compiler(C) = pcpp"clang::CompilerInstance"(
        ccall((:clang_compiler,Cxx.libcxxffi),Ptr{Void},(Ptr{Cxx.ClangCompiler},),&C))
    parser(C::Cxx.CxxInstance) = parser(Cxx.instance(C))
    compiler(C::Cxx.CxxInstance) = compiler(Cxx.instance(C))


    function isPPDirective(C,data)
        icxx"""
            const char *BufferStart = $(pointer(data));
            const char *BufferEnd = BufferStart+$(endof(data));
            clang::Lexer L(clang::SourceLocation(),$(compiler(C))->getLangOpts(),
                BufferStart, BufferStart, BufferEnd);
            clang::Token Tok;
            L.LexFromRawLexer(Tok);
            return Tok.is(clang::tok::hash);
        """
    end

    function isTopLevelExpression(C,data)
        x = [Cxx.instance(C)]
        return isPPDirective(C,data) || icxx"""
            clang::Parser *P = $(parser(C));
            clang::Preprocessor *PP = &P->getPreprocessor();
            clang::Parser::TentativeParsingAction TA(*P);
            EnterSourceFile((CxxInstance*)$(convert(Ptr{Void},pointer(x))),
                $(pointer(data)),$(sizeof(data)));
            clang::PreprocessorLexer *L = PP->getCurrentLexer();
            P->ConsumeToken();
            bool result = P->isCXXDeclarationStatement();
            TA.Revert();
            // Consume all cached tokens, so we don't accidentally
            // Lex them later after we abort this buffer
            while (PP->InCachingLexMode())
            {
                clang::Token Tok;
                PP->Lex(Tok);
            }
            // Exit the lexer for this buffer
            if (L == PP->getCurrentLexer())
                PP->RemoveTopOfLexerStack();
            return result;
        """
    end

    # Inspired by cling's InputValidator.cpp
    function isExpressionComplete(C,data)
        icxx"""
            const char *BufferStart = $(pointer(data));
            const char *BufferEnd = BufferStart+$(endof(data));
            clang::Lexer L(clang::SourceLocation(),$(compiler(C))->getLangOpts(),
                BufferStart, BufferStart, BufferEnd);
            clang::Token Tok;
            std::deque<int> parenStack;
            do {
                L.LexFromRawLexer(Tok);
                int kind = Tok.getKind();
                if (clang::tok::l_square <= kind && kind <= clang::tok::r_brace)
                {
                    // The closing parens are the opening one +1
                    if ((kind - clang::tok::l_square) % 2) {
                        if (parenStack.empty())
                            return false;
                        int prev = parenStack.back();
                        if (prev != kind - 1)
                            return false;
                        parenStack.pop_back();
                    } else {
                        parenStack.push_back(kind);
                    }
                }
            } while (Tok.isNot(clang::tok::eof));
            if (!parenStack.empty())
                return false;
            return true;
        """
    end

    global RunCxxREPL
    function RunCxxREPL(C)

        # Setup cxx panel
        panel = LineEdit.Prompt("C++ > ";
            # Copy colors from the prompt object
            prompt_prefix="\e[38;5;166m",
            prompt_suffix=Base.text_colors[:white],
            on_enter = s->isExpressionComplete(C,bytestring(LineEdit.buffer(s))))

        repl = Base.active_repl

        panel.on_done = REPL.respond(repl,panel) do line
            Cxx.process_cxx_string(string(line,"\n;"), isTopLevelExpression(C,line), :REPL, 1, 1;
                compiler = C)
        end

        main_mode = repl.interface.modes[1]

        unshift!(repl.interface.modes,panel)

        hp = main_mode.hist
        hp.mode_mapping[:cxx] = panel
        panel.hist = hp

        const cxx_keymap = Dict{Any,Any}(
            '<' => function (s,args...)
                if isempty(s)
                    if !haskey(s.mode_state,panel)
                        s.mode_state[panel] = LineEdit.init_state(repl.t,panel)
                    end
                    LineEdit.transition(s,panel)
                else
                    LineEdit.edit_insert(s,'<')
                end
            end
        )

        search_prompt, skeymap = LineEdit.setup_search_keymap(hp)
        mk = REPL.mode_keymap(main_mode)

        b = Dict{Any,Any}[skeymap, mk, LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults]
        panel.keymap_dict = LineEdit.keymap(b)

        main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict, cxx_keymap);
        nothing
    end

end
RunCxxREPL(__current_compiler__)
